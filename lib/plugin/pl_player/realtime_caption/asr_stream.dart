import 'asr_repetition.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'asr_word_timing.dart';
export 'asr_word_timing.dart';

const defaultAsrServer = 'https://asr.ieeio.com';
const _ieeioHost = 'asr.ieeio.com';
const _ieeioConfig = '/api/v1/meeting/transcription/realtime/config';
const _ieeioStream = '/api/v1/meeting/transcription/realtime/stream';
final ieeioAsrEndpoint =
    Uri(scheme: 'wss', host: _ieeioHost, path: _ieeioStream);

bool isIeeioEndpoint(Uri uri) =>
    uri.host == _ieeioHost && (!uri.hasPort || uri.port == 443);

Uri ieeioTicketUri(Map<String, dynamic> config) {
  final url = config['websocketUrl'];
  final ticket = config['token'];
  final uri = url is String ? Uri.tryParse(url) : null;
  final endpoint =
      uri == null ? null : Uri.parse(defaultAsrServer).resolveUri(uri);
  if (config['protocol'] != 'r2t2' ||
      config['protocolVersion'] != 1 ||
      endpoint == null ||
      !isIeeioEndpoint(endpoint) ||
      !const ['https', 'wss'].contains(endpoint.scheme) ||
      endpoint.path != _ieeioStream ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasFragment ||
      ticket is! String ||
      ticket.isEmpty ||
      ticket.length > 16384) {
    throw const AsrStreamException('QwenASR 返回的实时连接配置无效');
  }
  return ieeioAsrEndpoint.replace(queryParameters: {'ticket': ticket});
}

class AsrStreamException implements Exception {
  const AsrStreamException(
    this.message, {
    this.retryable = false,
  });

  final String message;
  final bool retryable;
}

typedef IeeioTokenLoader = Future<String> Function({String? rejectedToken});

bool isIeeioLoginToken(String? token) =>
    token != null &&
    token.isNotEmpty &&
    token.length <= 16384 &&
    token.codeUnits.every((byte) => byte > 32 && byte < 127);

Future<HttpClientResponse> _ieeioGet(
    HttpClient client, String path, String token) async {
  final request = await client.getUrl(Uri.https(_ieeioHost, path));
  request.followRedirects = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  request.headers.set('Origin', defaultAsrServer);
  return request.close();
}

abstract class CaptionAsrStream {
  int get maxAudioBytes;
  int get sentMilliseconds;
  int? get processedMilliseconds;
  bool get done;
  int get decodeChunkMs;

  Future<void> connect(
    Uri endpoint, {
    IeeioTokenLoader? ieeioLoginToken,
    String? language,
    required void Function(Map<String, dynamic>) onResult,
    required void Function(AsrStreamException) onError,
  });

  Future<void> send(Uint8List pcm);
  Future<void> finish();
  void close();
}

class AsrStream implements CaptionAsrStream {
  AsrStream({
    this.connectSocket = WebSocket.connect,
    this.receiveTimeout = const Duration(seconds: 90),
  });

  final Future<WebSocket> Function(
    String url, {
    Map<String, dynamic>? headers,
    HttpClient? customClient,
  }) connectSocket;
  final Duration receiveTimeout;

  static const _sampleRate = 16000;
  static const _bytesPerMillisecond = _sampleRate * 2 ~/ 1000;
  static const _sendTimeout = Duration(seconds: 8);
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _done = Completer<void>();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  void Function(AsrStreamException)? _onError;
  Timer? _receiveTimer;
  bool _closed = false;
  bool _ending = false;
  bool _reportedError = false;
  int _maxAudioBytes = _sampleRate * 2 * 60 * 60;
  int _frameBytes = _bytesPerMillisecond * 640;
  int _bytesSent = 0;
  int? _processedMilliseconds;
  final _audio = BytesBuilder(copy: false);

  int get maxAudioBytes => _maxAudioBytes;
  int get sentMilliseconds =>
      (_bytesSent - _audio.length) ~/ _bytesPerMillisecond;
  int? get processedMilliseconds => _processedMilliseconds;
  bool get done => _done.isCompleted;
  int get decodeChunkMs => math.max(1, _frameBytes ~/ _bytesPerMillisecond);

  Future<void> connect(
    Uri endpoint, {
    IeeioTokenLoader? ieeioLoginToken,
    String? language,
    required void Function(Map<String, dynamic>) onResult,
    required void Function(AsrStreamException) onError,
  }) async {
    _onError = onError;
    try {
      final hosted = isIeeioEndpoint(endpoint);
      final target = hosted ? await _getIeeioTicket(ieeioLoginToken) : endpoint;
      if (_closed) return;
      final socket = await connectSocket(
        target.toString(),
        customClient: _client,
        headers: hosted ? {'Origin': defaultAsrServer} : null,
      ).timeout(const Duration(seconds: 8));
      if (_closed) {
        await socket.close().timeout(const Duration(seconds: 1));
        return;
      }
      _socket = socket..pingInterval = const Duration(seconds: 15);
      _writePacket(socket, '{}');

      _subscription = socket.listen(
        (event) {
          if (_closed ||
              _reportedError ||
              _done.isCompleted ||
              event is! String) {
            return;
          }
          final Object? decoded;
          try {
            decoded = jsonDecode(event);
          } on FormatException {
            _reportError(const AsrStreamException('ASR 服务返回了无效数据'));
            return;
          }
          if (decoded is! Map<String, dynamic>) {
            _reportError(const AsrStreamException('ASR 服务返回了无效数据'));
            return;
          }
          if (decoded['error'] != null) {
            _reportError(switch (decoded['code']) {
              'capacity_exceeded' =>
                const AsrStreamException('ASR 服务繁忙', retryable: true),
              'session_limit' ||
              'session_timeout' =>
                const AsrStreamException('ASR 会话已经到期', retryable: true),
              'invalid_config' ||
              'invalid_audio' ||
              'invalid_message' =>
                const AsrStreamException('ASR 服务拒绝了实时音频参数'),
              _ => const AsrStreamException('ASR 服务暂时无法转写', retryable: true),
            });
            return;
          }
          if (decoded['ready'] == true && !_ready.isCompleted) {
            final rate = decoded['sample_rate'];
            final format = decoded['format'];
            final channels = decoded['channels'];
            final version = decoded['protocol_version'];
            if ((rate != null && rate != _sampleRate) ||
                (format != null && format != 'int16_le') ||
                (channels != null && channels != 1) ||
                (version != null && version != 1)) {
              _reportError(const AsrStreamException('ASR 服务不支持所需的音频格式'));
              return;
            }
            final chunk = decoded['chunk_seconds'];
            if (chunk != null) {
              if (chunk is! num || !chunk.isFinite || chunk <= 0 || chunk > 2) {
                _reportError(const AsrStreamException('ASR 返回了无效的音频分包长度'));
                return;
              }
              _frameBytes = math.max(1, (chunk * _sampleRate).round()) * 2;
            }
            final limit = decoded['max_session_seconds'];
            if (limit is num && limit > 0 && limit <= 3600) {
              _maxAudioBytes =
                  (limit * _sampleRate).floor().clamp(1, 57600000).toInt() * 2;
            }
            _ready.complete();
          } else if (_ready.isCompleted) {
            final audioMs = asrAudioMilliseconds(decoded);
            if (audioMs != null) {
              _processedMilliseconds = math.max(
                _processedMilliseconds ?? 0,
                math.min(audioMs, sentMilliseconds),
              );
            }
            _watchForReply(received: true);
            onResult(decoded);
          }
          if (decoded['done'] == true && !_done.isCompleted) {
            _receiveTimer?.cancel();
            _done.complete();
          }
        },
        onError: (Object _) {
          _reportError(
              const AsrStreamException('实时 ASR 连接中断', retryable: true));
        },
        onDone: () {
          final code = socket.closeCode;
          // 4000-4999 是应用自定义错误，通常不可重试
          final retryable = code == null || code < 4000 || code >= 5000;
          _reportError(AsrStreamException(
            code == null ? '实时 ASR 连接已关闭' : '实时 ASR 连接已关闭（$code）',
            retryable: retryable,
          ));
          if (!_done.isCompleted) _done.complete();
        },
      );
      await _ready.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw const AsrStreamException('连接 ASR 超时', retryable: true);
    } on WebSocketException {
      throw const AsrStreamException('无法连接 ASR', retryable: true);
    } on IOException {
      throw const AsrStreamException('无法访问 ASR 服务', retryable: true);
    }
  }

  void _reportError(AsrStreamException error) {
    if (_closed || _done.isCompleted || _reportedError) return;
    _receiveTimer?.cancel();
    _reportedError = true;
    if (_ready.isCompleted) {
      _onError?.call(error);
    } else {
      _ready.completeError(error);
    }
  }

  void _watchForReply({required bool received}) {
    if (received) {
      _receiveTimer?.cancel();
      _receiveTimer = null;
    }
    final awaitingMs = sentMilliseconds - (_processedMilliseconds ?? 0);
    // Only time out when a full audio packet is awaiting a reply.
    if (_closed ||
        _ending ||
        _reportedError ||
        _done.isCompleted ||
        awaitingMs < decodeChunkMs ||
        _receiveTimer != null) {
      return;
    }
    _receiveTimer = Timer(
      (_processedMilliseconds ?? 0) > 0
          ? receiveTimeout
          : receiveTimeout + const Duration(seconds: 45),
      () {
        _reportError(const AsrStreamException('ASR 服务长时间未响应', retryable: true));
      },
    );
  }

  Future<Uri> _getIeeioTicket(IeeioTokenLoader? loadToken) async {
    if (loadToken == null) {
      throw const AsrStreamException('QwenASR 会话不可用');
    }

    Future<HttpClientResponse> requestConfig(String token) {
      if (!isIeeioLoginToken(token)) {
        throw const AsrStreamException('QwenASR 返回了无效的登录会话');
      }
      return _ieeioGet(_client, _ieeioConfig, token)
          .timeout(const Duration(seconds: 8));
    }

    final token = await loadToken();
    var response = await requestConfig(token);
    if (response.statusCode == 401) {
      await response.drain<void>().timeout(const Duration(seconds: 8));
      response = await requestConfig(await loadToken(rejectedToken: token));
    }

    switch (response.statusCode) {
      case 200:
        final raw = await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 8));
        final Object? config;
        try {
          config = jsonDecode(raw);
        } on FormatException {
          throw const AsrStreamException('QwenASR 返回的实时连接配置无效');
        }
        if (config is Map<String, dynamic>) return ieeioTicketUri(config);
        throw const AsrStreamException('QwenASR 返回的实时连接配置无效');
      case 401:
        throw const AsrStreamException('QwenASR 自动登录未生效，请稍后重试');
      case 403:
        throw const AsrStreamException('当前 QwenASR 会话没有实时识别权限');
      case 429:
        throw const AsrStreamException('QwenASR 服务繁忙', retryable: true);
      default:
        throw AsrStreamException('QwenASR 暂时无法建立实时会话',
            retryable: response.statusCode >= 500);
    }
  }

  Future<void> send(Uint8List pcm) async {
    final socket = _socket;
    if (socket == null ||
        !_ready.isCompleted ||
        _closed ||
        _ending ||
        _reportedError ||
        _done.isCompleted) {
      return;
    }
    final remaining = maxAudioBytes - _bytesSent;
    final size = pcm.length < remaining ? pcm.length : remaining;
    for (var offset = 0; offset < size;) {
      final available = size - offset;
      final needed = _frameBytes - _audio.length;
      final end = offset + (available < needed ? available : needed);
      _audio.add(Uint8List.sublistView(pcm, offset, end));
      _bytesSent += end - offset;
      if (_audio.length == _frameBytes) {
        await _sendAudioPacket(socket, _audio.takeBytes());
        if (_closed || _reportedError || _done.isCompleted) return;
      }
      offset = end;
    }
  }

  Future<void> finish() async {
    final socket = _socket;
    if (socket == null || _closed || _ending || _done.isCompleted) return;
    _ending = true;
    _receiveTimer?.cancel();
    if (_audio.isNotEmpty) await _sendAudioPacket(socket, _audio.takeBytes());
    if (_closed || _reportedError || _done.isCompleted) return;
    _writePacket(socket, 'end');
    await _done.future.timeout(const Duration(seconds: 5), onTimeout: () {
      throw const AsrStreamException('ASR 未确认收到音频结尾', retryable: true);
    });
  }

  Future<void> _sendAudioPacket(WebSocket socket, Uint8List packet) async {
    const disconnected = AsrStreamException('实时 ASR 连接中断', retryable: true);
    if (socket.readyState != WebSocket.open) throw disconnected;
    try {
      // Bound each upload by the WebSocket sink, independently of ASR output.
      await socket
          .addStream(Stream<Uint8List>.value(packet))
          .timeout(_sendTimeout);
      _watchForReply(received: false);
    } on TimeoutException {
      throw const AsrStreamException('发送视频音轨超时', retryable: true);
    } on IOException {
      throw disconnected;
    } on StateError {
      throw disconnected;
    }
  }

  void _writePacket(WebSocket socket, Object packet) {
    try {
      socket.add(packet);
    } on StateError {
      throw const AsrStreamException('实时 ASR 连接中断', retryable: true);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _receiveTimer?.cancel();
    _onError = null;
    _audio.clear();
    if (!_ready.isCompleted) _ready.complete();
    if (!_done.isCompleted) _done.complete();
    final subscription = _subscription;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    final socket = _socket;
    if (socket != null) {
      unawaited(socket.close().then<void>((_) {}, onError: (Object _) {}));
    }
    _client.close(force: true);
  }
}

class AsrCaption {
  const AsrCaption(
    this.utterance,
    this.text,
    this.isFinal, {
    this.audioMs,
    this.startAudioMs,
    this.words = const [],
  });

  final int utterance;
  final String text;
  final bool isFinal;
  final int? audioMs;
  final int? startAudioMs;
  final List<AsrWordTiming> words;
}

// The protocol reports how much audio it has processed, including silence.
int? asrAudioMilliseconds(Map<String, dynamic> message) {
  final audioMs = message['audio_ms'];
  return audioMs is num &&
          audioMs.isFinite &&
          audioMs >= 0 &&
          audioMs <= 3600000
      ? audioMs.round()
      : null;
}

class AsrTranscript {
  AsrTranscript({
    this.sentenceOnly = false,
    this.emitPreview = true,
  });

  final bool sentenceOnly;
  final bool emitPreview;
  AsrCaption? _caption;
  String _pendingText = '';
  int? _pendingUtterance;
  int? _pendingStartAudioMs;
  int? _lastAudioMs;
  int _emittedUtterances = 0;
  String _lastEmittedPreview = '';
  final _timedWords = <AsrWord>[];
  final _repetitionGuard = AsrRepetitionGuard();

  AsrCaption? _guardCaption(AsrCaption caption) {
    final safe = _repetitionGuard.accept(suppressAsrShortLoops(caption.text),
        isFinal: caption.isFinal, audioMs: caption.audioMs);
    if (safe == caption.text) return _withWordTiming(caption);
    _timedWords.clear();
    if (safe.trim().isEmpty) return null;
    return AsrCaption(caption.utterance, safe, caption.isFinal,
        audioMs: caption.audioMs, startAudioMs: caption.startAudioMs);
  }

  AsrCaption _withWordTiming(AsrCaption caption) {
    if (caption.words.isNotEmpty) return caption;
    final words = alignAsrWords(caption.text, _timedWords);
    if (words.isEmpty) {
      if (caption.isFinal && caption.audioMs != null) {
        _timedWords.removeWhere((word) => word.endMs <= caption.audioMs!);
      }
      return caption;
    }
    if (caption.isFinal) {
      _timedWords.removeWhere((word) => word.endMs <= words.last.endMs);
    }
    return AsrCaption(caption.utterance, caption.text, caption.isFinal,
        startAudioMs: words.first.startMs,
        audioMs: words.last.endMs,
        words: words);
  }

  AsrCaption? finish() {
    final caption = _finishUntimed();
    return caption == null ? null : _guardCaption(caption);
  }

  AsrCaption? _finishUntimed() {
    _lastEmittedPreview = '';
    if (!sentenceOnly) {
      final caption = _caption;
      if (caption == null || caption.isFinal || caption.text.trim().isEmpty) {
        return null;
      }
      return _caption = AsrCaption(
        caption.utterance,
        caption.text,
        true,
        audioMs: caption.audioMs,
        startAudioMs: caption.startAudioMs,
      );
    }

    if (_pendingText.trim().isEmpty) return null;
    final text = _pendingText.trim();
    _pendingText = '';
    return AsrCaption(
      _pendingUtterance ?? ++_emittedUtterances,
      text,
      true,
      audioMs: _lastAudioMs,
      startAudioMs: _pendingStartAudioMs,
    );
  }

  static String _removeRepeatingPhrases(String text) {
    final guarded = suppressAsrShortLoops(text);
    if (guarded != text) return guarded;
    if (text.isEmpty) return text;

    // 1. 词级 N-gram 连续重复抑制 (西文带空格)
    // 门槛 k>=3：避免把 "no no" 这类正常口误删掉一个词（漏词）
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length >= 6) {
      final maxK = (words.length / 2).floor().clamp(3, 15);
      for (int k = maxK; k >= 3; k--) {
        for (int i = 0; i + 2 * k <= words.length; i++) {
          final phrase1 = words.sublist(i, i + k).join(' ').toLowerCase();
          final phrase2 = words.sublist(i + k, i + 2 * k).join(' ').toLowerCase();
          if (phrase1 == phrase2) {
            final cleanWords = [
              ...words.sublist(0, i + k),
              ...words.sublist(i + 2 * k),
            ];
            return _removeRepeatingPhrases(cleanWords.join(' '));
          }
        }
      }
    }

    // 2. 中文/无空格字符级连续重复抑制（忽略标点比对）
    // 门槛 3→10：旧值会误删“我不知道我不知道”“谢谢你谢谢你”等正常口语强调（漏词）。
    // 只清理 10 字以上的整段幻觉循环，宁可留重复也不删字。
    for (int len = (text.length / 2).floor().clamp(1, 24); len >= 10; len--) {
      for (int i = 0; i + 2 * len <= text.length; i++) {
        final p1 = text.substring(i, i + len).trim();
        final p2 = text.substring(i + len, i + 2 * len).trim();
        if (p1.isNotEmpty && p2.isNotEmpty) {
          final c1 = p1.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
          final c2 = p2.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
          if (c1.isNotEmpty && c1 == c2) {
            final collapsed = text.substring(0, i + len) + text.substring(i + 2 * len);
            return _removeRepeatingPhrases(collapsed);
          }
        }
      }
    }

    return text;
  }

  static String _joinText(String prefix, String suffix) {
    final p = suppressAsrShortLoops(prefix.trim());
    final s = suppressAsrShortLoops(suffix.trim());
    if (p.isEmpty) return s;
    if (s.isEmpty) return p;
    if (p == s) return p;

    // 1. 完全相等与"尾部重合"判断
    // 漏词教训：旧代码有 p.contains(s) —— 只要新文本 s 出现在旧文本 p 的任意位置，
    // 就把 s 整段丢弃。当用户真的说了重复内容（如 s 是刚说过的词）时会被误删。
    // 只有 s 是 p 的"尾部"（增量回退修正）才是安全的去重，任意位置包含不能丢。
    if (p.endsWith(s) || p.endsWith(' $s')) return p;
    if (s.startsWith(p)) return s;
    if (p.startsWith(s)) return p;

    // 2. 标点容错前缀重合判断（例如 p="你哋两个一齐去台湾见姑，", s="你哋两个一齐去台湾见姑正阳喺即系大家都"）
    final cleanP = p.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
    final cleanS = s.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
    if (cleanS.startsWith(cleanP) && cleanP.length >= 6) {
      return s;
    }
    if (cleanP.startsWith(cleanS) && cleanS.length >= 6) {
      return p;
    }

    // 3. 最大前后缀字符重叠匹配 (Suffix-to-Prefix Overlap)
    // 门槛 2→5：中文相邻片段首尾 2~3 字相同极常见（“这个”“我来说”），
    // 旧门槛会把 s 开头的真实内容当成重叠切掉造成漏词。只认 5 字以上的长重合。
    final maxCheck = math.min(p.length, s.length);
    for (int len = maxCheck; len >= 5; len--) {
      final pSuffix = p.substring(p.length - len);
      final sPrefix = s.substring(0, len);
      final cSuffix = pSuffix.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
      final cPrefix = sPrefix.replaceAll(RegExp(r'[，。！？,.!?、；;\s]'), '');
      if (cSuffix.isNotEmpty && cSuffix.toLowerCase() == cPrefix.toLowerCase()) {
        final remainder = s.substring(len).trim();
        if (remainder.isEmpty) return p;
        final bool needSpace = RegExp(r'[a-zA-Z0-9]$').hasMatch(p) &&
            RegExp(r'^[a-zA-Z0-9]').hasMatch(remainder);
        return _removeRepeatingPhrases(needSpace ? '$p $remainder' : '$p$remainder');
      }
    }

    // 4. 单词级重叠匹配（西文带空格）
    final pWords = p.split(RegExp(r'\s+'));
    final sWords = s.split(RegExp(r'\s+'));
    if (pWords.isNotEmpty && sWords.isNotEmpty) {
      final maxWordCheck = math.min(pWords.length, sWords.length);
      for (int wLen = maxWordCheck; wLen >= 1; wLen--) {
        final pTail = pWords.sublist(pWords.length - wLen).join(' ').toLowerCase();
        final sHead = sWords.sublist(0, wLen).join(' ').toLowerCase();
        if (pTail == sHead) {
          final remainderWords = sWords.sublist(wLen);
          if (remainderWords.isEmpty) return p;
          return _removeRepeatingPhrases('$p ${remainderWords.join(' ')}');
        }
      }
    }

    // 5. 普通拼接（带中西文空格逻辑）
    final lastCode = p.codeUnitAt(p.length - 1);
    final firstCode = s.codeUnitAt(0);

    final isLastAscii = (lastCode >= 48 && lastCode <= 57) ||
        (lastCode >= 65 && lastCode <= 90) ||
        (lastCode >= 97 && lastCode <= 122) ||
        lastCode == 44 ||
        lastCode == 46 ||
        lastCode == 33 ||
        lastCode == 63;
    final isFirstAscii = (firstCode >= 48 && firstCode <= 57) ||
        (firstCode >= 65 && firstCode <= 90) ||
        (firstCode >= 97 && firstCode <= 122);

    final merged = (isLastAscii && isFirstAscii) ? '$p $s' : '$p$s';
    return _removeRepeatingPhrases(merged);
  }

  Iterable<AsrCaption> accept(Map<String, dynamic> message) sync* {
    // All providers (direct hypotheses and deltas) pass through this boundary.
    // Clear stale token timings when text changes; guessing their new offsets
    // would associate the retained suffix with removed repeated tokens.
    var changed = false;
    final safeMessage = Map<String, dynamic>.from(message);
    for (final key in ['text', 'delta']) {
      final value = message[key];
      if (value is! String) continue;
      final safe = suppressAsrShortLoops(value);
      if (safe == value) continue;
      safeMessage[key] = safe;
      changed = true;
    }
    if (changed) {
      safeMessage.remove('words');
      _timedWords.clear();
    }
    message = safeMessage;
    final words = readAsrWords(message['words']);
    if (words.isNotEmpty) {
      // 重发的假说覆盖同一音频区间；已确认但未成句的词继续保留。
      _timedWords.removeWhere((word) => word.endMs > words.first.startMs);
      _timedWords.addAll(words);
      if (_timedWords.length > 2048) {
        _timedWords.removeRange(0, _timedWords.length - 2048);
      }
    }
    for (final caption in _acceptUntimed(message, hasWordTimings: words.isNotEmpty)) {
      final guarded = _guardCaption(caption);
      if (guarded != null) yield guarded;
    }
  }

  Iterable<AsrCaption> _acceptUntimed(Map<String, dynamic> message,
      {bool hasWordTimings = false}) sync* {
    // 兼容通用/公有云识别服务直接提供的完整 text 结构（包括微软 Azure、Deepgram、豆包等）
    final directText = message['text'];
    final speechFinal = message['speech_final'] == true || message['turn_end'] == true;
    final audioMs = asrAudioMilliseconds(message);
    if (audioMs != null) _lastAudioMs = audioMs;

    // 当收到单纯的 turn_end / speech_final（且没有附带新的 text），说明说话人出现停顿，闭合未完结的累积尾句
    if ((directText == null || (directText is String && directText.trim().isEmpty)) && speechFinal) {
      if (_pendingText.trim().isNotEmpty) {
        _emittedUtterances++;
        _lastEmittedPreview = '';
        final caption = AsrCaption(
          _emittedUtterances,
          _pendingText.trim(),
          true,
          startAudioMs: _pendingStartAudioMs,
          audioMs: _lastAudioMs,
        );
        _pendingText = '';
        _pendingUtterance = null;
        _pendingStartAudioMs = null;
        yield caption;
      }
      return;
    }

    if (directText is String && directText.trim().isNotEmpty) {
      final isFinal = message['isFinal'] == true || message['utterance_end'] == true || message['done'] == true;
      final startMs = message['start_ms'] is num ? (message['start_ms'] as num).round() : null;
      _pendingStartAudioMs ??= startMs;
      final trimmed = directText.trim();

      if (!sentenceOnly) {
        _emittedUtterances++;
        final caption = AsrCaption(
          _emittedUtterances,
          trimmed,
          isFinal,
          audioMs: audioMs ?? _lastAudioMs,
          startAudioMs: startMs ?? _pendingStartAudioMs,
        );
        _caption = caption;
        yield caption;
        return;
      }

      // sentenceOnly == true
      if (!isFinal) {
        // 中间预览：之前累积未闭合的 _pendingText + 当前正在说话的临时预测 trimmed
        final preview = _joinText(_pendingText, trimmed);
        if (emitPreview &&
            (preview != _lastEmittedPreview || hasWordTimings) &&
            preview.length >= 2) {
          _lastEmittedPreview = preview;
          yield AsrCaption(
            _emittedUtterances + 1,
            preview,
            false,
            startAudioMs: _pendingStartAudioMs,
            audioMs: _lastAudioMs,
          );
        }
        return;
      }

      // isFinal == true:
      // 将当前已确定的短语平滑拼接进 _pendingText
      _pendingText = _joinText(_pendingText, trimmed);

      // 1. 强句尾标点断句：中日文句号、感叹号、问号、省略号、换行，或英文句号+空格/结尾
      final strongEndPattern = RegExp(r'[。！？!?\n]|(?<=[a-zA-Z0-9])\.(?:\s+|$)|(?:…{1,2})|(?:\.{3,})');
      while (true) {
        final match = strongEndPattern.firstMatch(_pendingText);
        if (match != null) {
          final sentence = _pendingText.substring(0, match.end).trim();
          final remaining = _pendingText.substring(match.end).trimLeft();
          final fullLen = _pendingText.length;
          _pendingText = remaining;
          if (sentence.isNotEmpty) {
            _emittedUtterances++;
            _lastEmittedPreview = '';
            final lastAudio = _lastAudioMs;
            final startAudio = _pendingStartAudioMs;
            final segEndMs = (startAudio != null && lastAudio != null && lastAudio > startAudio && fullLen > 0)
                ? startAudio + (((lastAudio - startAudio) * sentence.length) ~/ fullLen)
                : lastAudio;
            yield AsrCaption(
              _emittedUtterances,
              sentence,
              true,
              startAudioMs: _pendingStartAudioMs,
              audioMs: segEndMs,
            );
            _pendingStartAudioMs = _pendingText.trim().isEmpty ? null : segEndMs;
          }
        } else {
          break;
        }
      }

      // 2. 次级标点自适应平滑断句（逗号、分号、中日顿号、波浪号）：
      // 只有累积达到自然子句阈值时才断句，杜绝破碎孤立字幕；未达阈值时保留在 _pendingText 继续与后续内容衔接
      final isJapanese = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(_pendingText);
      final hasSpace = _pendingText.contains(' ');
      final clauseThreshold = isJapanese ? 10 : (!hasSpace ? 14 : 35);
      final minClauseEnd = isJapanese ? 8 : (!hasSpace ? 10 : 25);

      if (_pendingText.length >= clauseThreshold) {
        final secDelimiters = RegExp(r'[，、；,;・〜～]');
        final matches = secDelimiters.allMatches(_pendingText).toList();
        if (matches.isNotEmpty) {
          RegExpMatch? targetMatch;
          for (final m in matches) {
            if (m.end >= minClauseEnd) {
              targetMatch = m;
            }
          }
          if (targetMatch != null) {
            final clause = _pendingText.substring(0, targetMatch.end).trim();
            final remaining = _pendingText.substring(targetMatch.end).trimLeft();
            final fullLen = _pendingText.length;
            _pendingText = remaining;
            if (clause.isNotEmpty) {
              _emittedUtterances++;
              _lastEmittedPreview = '';
              final lastAudio = _lastAudioMs;
              final startAudio = _pendingStartAudioMs;
              final segEndMs = (startAudio != null && lastAudio != null && lastAudio > startAudio && fullLen > 0)
                  ? startAudio + (((lastAudio - startAudio) * clause.length) ~/ fullLen)
                  : lastAudio;
              yield AsrCaption(
                _emittedUtterances,
                clause,
                true,
                startAudioMs: _pendingStartAudioMs,
                audioMs: segEndMs,
              );
              _pendingStartAudioMs = _pendingText.trim().isEmpty ? null : segEndMs;
            }
          }
        }
      } else if (_pendingText.length >= (hasSpace ? 50 : (isJapanese ? 20 : 25))) {
        // 3. 无标点超长句保护性断句：严禁切断英文单词！
        int splitPos = -1;
        if (hasSpace) {
          final searchLimit = math.min(45, _pendingText.length);
          final spaceIndex = _pendingText.substring(0, searchLimit).lastIndexOf(' ');
          if (spaceIndex >= 25) {
            splitPos = spaceIndex;
          }
        } else if (isJapanese) {
          final searchLimit = math.min(20, _pendingText.length);
          final partMatch = RegExp(r'[はがをにへとでねよかも]')
              .allMatches(_pendingText.substring(0, searchLimit))
              .lastOrNull;
          if (partMatch != null && partMatch.end >= 12) {
            splitPos = partMatch.end;
          } else {
            splitPos = math.min(18, _pendingText.length);
          }
        } else {
          splitPos = math.min(20, _pendingText.length);
        }

        if (splitPos > 0 && splitPos < _pendingText.length) {
          final clause = _pendingText.substring(0, splitPos).trim();
          final remaining = _pendingText.substring(splitPos).trimLeft();
          final fullLen = _pendingText.length;
          _pendingText = remaining;
          if (clause.isNotEmpty) {
            _emittedUtterances++;
            _lastEmittedPreview = '';
            final lastAudio = _lastAudioMs;
            final startAudio = _pendingStartAudioMs;
            final segEndMs = (startAudio != null && lastAudio != null && lastAudio > startAudio && fullLen > 0)
                ? startAudio + (((lastAudio - startAudio) * splitPos) ~/ fullLen)
                : lastAudio;
            yield AsrCaption(
              _emittedUtterances,
              clause,
              true,
              startAudioMs: _pendingStartAudioMs,
              audioMs: segEndMs,
            );
            _pendingStartAudioMs = _pendingText.trim().isEmpty ? null : segEndMs;
          }
        }
      }

      // 4. 若该消息明确标记了 speech_final（例如用户一段话讲完停顿），且 _pendingText 还有尾巴，闭合它
      if (speechFinal && _pendingText.trim().isNotEmpty) {
        _emittedUtterances++;
        _lastEmittedPreview = '';
        yield AsrCaption(
          _emittedUtterances,
          _pendingText.trim(),
          true,
          startAudioMs: _pendingStartAudioMs,
          audioMs: _lastAudioMs,
        );
        _pendingText = '';
        _pendingUtterance = null;
        _pendingStartAudioMs = null;
      }
      return;
    }

    if (!sentenceOnly) {
      final utterance = message['utterance'];
      final isFinal = message['utterance_end'] == true || message['done'] == true;
      final delta = message['delta'] ?? (isFinal ? '' : null);
      if (isFinal && utterance == null) {
        final caption = _finishUntimed();
        if (caption != null) yield caption;
        return;
      }
      if (utterance is! int || utterance < 0 || delta is! String) return;
      final previous = _caption;
      if (previous != null &&
          (utterance < previous.utterance ||
              (utterance == previous.utterance && previous.isFinal))) {
        return;
      }
      if (previous != null &&
          utterance > previous.utterance &&
          !previous.isFinal &&
          previous.text.trim().isNotEmpty) {
        yield AsrCaption(previous.utterance, previous.text, true,
            audioMs: previous.audioMs,
            startAudioMs: previous.startAudioMs);
      }
      final prefix = previous?.utterance == utterance ? previous!.text : '';
      final text = prefix + delta;
      final startAudio = message['start_ms'] is num
          ? (message['start_ms'] as num).round()
          : null;
      final caption = AsrCaption(
        utterance,
        text,
        isFinal,
        audioMs: asrAudioMilliseconds(message) ??
            (previous?.utterance == utterance ? previous?.audioMs : null),
        startAudioMs: startAudio ??
            (previous?.utterance == utterance ? previous?.startAudioMs : null),
      );
      _caption = caption;
      if (text.trim().isNotEmpty && (delta.isNotEmpty || isFinal)) yield caption;
      return;
    }

    // sentenceOnly == true (以完整句子为单位刷新，避免逐字跳动和过多网络请求):
    final utterance = message['utterance'];
    final isFinal = message['utterance_end'] == true || message['done'] == true;
    final delta = message['delta'] ?? (isFinal ? '' : null);
    final startMs = message['start_ms'] is num
        ? (message['start_ms'] as num).round()
        : null;

    if (isFinal && utterance == null) {
      final caption = _finishUntimed();
      if (caption != null) yield caption;
      return;
    }
    if (utterance is! int || utterance < 0 || delta is! String) return;

    if (_pendingUtterance != null && utterance < _pendingUtterance!) {
      return;
    }

    if (_pendingUtterance != null && utterance > _pendingUtterance!) {
      if (_pendingText.trim().isNotEmpty) {
        _emittedUtterances++;
        _lastEmittedPreview = '';
        yield AsrCaption(
          _emittedUtterances,
          _pendingText.trim(),
          true,
          startAudioMs: _pendingStartAudioMs,
          audioMs: _lastAudioMs,
        );
      }
      _pendingText = '';
      _pendingUtterance = utterance;
      _pendingStartAudioMs = startMs;
      _lastEmittedPreview = '';
    }

    _pendingUtterance ??= utterance;
    _pendingStartAudioMs ??= startMs;
    if (audioMs != null) _lastAudioMs = audioMs;

    if (delta.length > 4) {
      _pendingText = _joinText(_pendingText, delta);
    } else {
      _pendingText = suppressAsrShortLoops(_pendingText + delta);
    }

    // 1. 强句尾标点断句：中日文句号、感叹号、问号、省略号、换行，或英文句号+空格/结尾
    final strongEndPattern = RegExp(r'[。！？!?\n]|(?<=[a-zA-Z0-9])\.(?:\s+|$)|(?:…{1,2})|(?:\.{3,})');
    while (true) {
      final match = strongEndPattern.firstMatch(_pendingText);
      if (match != null) {
        final sentence = _pendingText.substring(0, match.end).trim();
        final remaining = _pendingText.substring(match.end);
        final fullLen = _pendingText.length;
        _pendingText = remaining;
        if (sentence.isNotEmpty) {
          _emittedUtterances++;
          _lastEmittedPreview = '';
          final lastAudio = _lastAudioMs;
          final startAudio = _pendingStartAudioMs;
          final segEndMs = (startAudio != null && lastAudio != null && lastAudio > startAudio && fullLen > 0)
              ? startAudio + (((lastAudio - startAudio) * sentence.length) ~/ fullLen)
              : lastAudio;
          yield AsrCaption(
            _emittedUtterances,
            sentence,
            true,
            startAudioMs: _pendingStartAudioMs,
            audioMs: segEndMs,
          );
          _pendingStartAudioMs = _pendingText.trim().isEmpty ? null : segEndMs;
        }
      } else {
        break;
      }
    }

    // 2. 次级标点断句（逗号、分号、中日顿号、波浪号）：
    // 根据语种自适应阈值：
    // - 日文：8 字即可在 、 / ・ 处断句（日文词素较长，8 字已为完整子句，杜绝积压狂闪）
    // - 粤语/中文：10 字即可在 ， / 、 处断句（粤语短句极多，10 字即可成句，杜绝积压）
    // - 英文（含空格）：30 字符
    final isJapanese = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(_pendingText);
    final hasSpace = _pendingText.contains(' ');
    final clauseThreshold = isJapanese ? 8 : (!hasSpace ? 8 : 25);
    final minClauseEnd = isJapanese ? 6 : (!hasSpace ? 6 : 16);

    if (_pendingText.length >= clauseThreshold) {
      final secDelimiters = RegExp(r'[，、；,;・〜～]');
      final matches = secDelimiters.allMatches(_pendingText).toList();
      if (matches.isNotEmpty) {
        RegExpMatch? targetMatch;
        for (final m in matches) {
          if (m.end >= minClauseEnd) {
            targetMatch = m;
          }
        }
        if (targetMatch != null) {
          final clause = _pendingText.substring(0, targetMatch.end).trim();
          final remaining = _pendingText.substring(targetMatch.end);
          final fullLen = _pendingText.length;
          _pendingText = remaining;
          if (clause.isNotEmpty) {
            _emittedUtterances++;
            _lastEmittedPreview = '';
            final lastAudio = _lastAudioMs;
            final startAudio = _pendingStartAudioMs;
            final segEndMs = (startAudio != null && lastAudio != null && lastAudio > startAudio && fullLen > 0)
                ? startAudio + (((lastAudio - startAudio) * clause.length) ~/ fullLen)
                : lastAudio;
            yield AsrCaption(
              _emittedUtterances,
              clause,
              true,
              startAudioMs: _pendingStartAudioMs,
              audioMs: segEndMs,
            );
            _pendingStartAudioMs = _pendingText.trim().isEmpty ? null : segEndMs;
          }
        }
      } else if (_pendingText.length >= (hasSpace ? 50 : (isJapanese ? 18 : 22))) {
        // 3. 无标点超长句保护性断句：严禁切断英文单词！
        int splitPos = -1;
        if (hasSpace) {
          // 英文：在 25~45 之间寻找最后一个空格作为单词边界
          final searchLimit = math.min(45, _pendingText.length);
          final spaceIndex = _pendingText.substring(0, searchLimit).lastIndexOf(' ');
          if (spaceIndex >= 20) {
            splitPos = spaceIndex;
          }
        } else if (isJapanese) {
          // 日文在 12~18 字寻找助词边界（は、が、を、に、で、と、ね、よ、か、も），若无则在 16 字截断
          final searchLimit = math.min(18, _pendingText.length);
          final partMatch = RegExp(r'[はがをにへとでねよかも]')
              .allMatches(_pendingText.substring(0, searchLimit))
              .lastOrNull;
          if (partMatch != null && partMatch.end >= 10) {
            splitPos = partMatch.end;
          } else {
            splitPos = math.min(16, _pendingText.length);
          }
        } else {
          // 中文/粤语无空格：在 16~20 字处断开
          splitPos = math.min(18, _pendingText.length);
        }

        if (splitPos > 0 && splitPos < _pendingText.length) {
          final clause = _pendingText.substring(0, splitPos).trim();
          final remaining = _pendingText.substring(splitPos).trimLeft();
          final fullLen = _pendingText.length;
          _pendingText = remaining;
          if (clause.isNotEmpty) {
            _emittedUtterances++;
            _lastEmittedPreview = '';
            final lastAudio = _lastAudioMs;
            final startAudio = _pendingStartAudioMs;
            final segEndMs = (startAudio != null && lastAudio != null && lastAudio > startAudio && fullLen > 0)
                ? startAudio + (((lastAudio - startAudio) * splitPos) ~/ fullLen)
                : lastAudio;
            yield AsrCaption(
              _emittedUtterances,
              clause,
              true,
              startAudioMs: _pendingStartAudioMs,
              audioMs: segEndMs,
            );
            _pendingStartAudioMs = _pendingText.trim().isEmpty ? null : segEndMs;
          }
        }
      }
    }

    if (isFinal) {
      final remaining = _pendingText.trim();
      if (remaining.isNotEmpty) {
        _emittedUtterances++;
        yield AsrCaption(
          _emittedUtterances,
          remaining,
          true,
          startAudioMs: _pendingStartAudioMs,
          audioMs: _lastAudioMs,
        );
      }
      _pendingText = '';
      _pendingUtterance = null;
      _pendingStartAudioMs = null;
      _lastEmittedPreview = '';
    } else if (emitPreview) {
      // 正在讲话中的实时预览（isFinal = false），存入 session.partial 即时渲染在屏幕上
      // 增加防抖判定，内容未改变时绝不重复抛出，杜绝频繁触发重绘和闪烁
      final preview = _pendingText.trim();
      if (preview.isNotEmpty && preview.length >= 2 && preview != _lastEmittedPreview) {
        _lastEmittedPreview = preview;
        yield AsrCaption(
          _emittedUtterances + 1,
          preview,
          false,
          startAudioMs: _pendingStartAudioMs,
          audioMs: _lastAudioMs,
        );
      }
    }
  }
}
