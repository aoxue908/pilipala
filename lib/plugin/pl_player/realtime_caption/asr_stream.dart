import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
  });

  final int utterance;
  final String text;
  final bool isFinal;
  final int? audioMs;
  final int? startAudioMs;
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
  AsrTranscript({this.sentenceOnly = false});

  final bool sentenceOnly;
  AsrCaption? _caption;
  String _pendingText = '';
  int? _pendingUtterance;
  int? _pendingStartAudioMs;
  int? _lastAudioMs;
  int _emittedUtterances = 0;

  AsrCaption? finish() {
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

  Iterable<AsrCaption> accept(Map<String, dynamic> message) sync* {
    if (!sentenceOnly) {
      final utterance = message['utterance'];
      final isFinal = message['utterance_end'] == true || message['done'] == true;
      final delta = message['delta'] ?? (isFinal ? '' : null);
      if (isFinal && utterance == null) {
        final caption = finish();
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
    final audioMs = asrAudioMilliseconds(message);
    final startMs = message['start_ms'] is num
        ? (message['start_ms'] as num).round()
        : null;

    if (isFinal && utterance == null) {
      final caption = finish();
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
    }

    _pendingUtterance ??= utterance;
    _pendingStartAudioMs ??= startMs;
    if (audioMs != null) _lastAudioMs = audioMs;

    _pendingText += delta;

    // 1. 强句尾标点断句：中文句号感叹号问号换行，或英文句号+空格/结尾
    final strongEndPattern = RegExp(r'[。！？!?\n]|(?<=[a-zA-Z0-9])\.(?:\s+|$)');
    while (true) {
      final match = strongEndPattern.firstMatch(_pendingText);
      if (match != null) {
        final sentence = _pendingText.substring(0, match.end).trim();
        final remaining = _pendingText.substring(match.end);
        final fullLen = _pendingText.length;
        _pendingText = remaining;
        if (sentence.isNotEmpty) {
          _emittedUtterances++;
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

    // 2. 次级标点断句（逗号、分号）：仅在句子较长时断句，避免碎片化
    // 中文需 >= 24 字，英文需 >= 40 字符
    final hasSpace = _pendingText.contains(' ');
    final clauseThreshold = hasSpace ? 40 : 24;
    if (_pendingText.length >= clauseThreshold) {
      final secDelimiters = RegExp(r'[，、；,;]');
      final matches = secDelimiters.allMatches(_pendingText).toList();
      if (matches.isNotEmpty) {
        RegExpMatch? targetMatch;
        for (final m in matches) {
          if (m.end >= (hasSpace ? 30 : 16)) {
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
      } else if (_pendingText.length >= (hasSpace ? 60 : 36)) {
        // 3. 无标点超长句保护性断句：严禁切断英文单词！
        int splitPos = -1;
        if (hasSpace) {
          // 英文：在 35~55 之间寻找最后一个空格作为单词边界
          final searchLimit = math.min(55, _pendingText.length);
          final spaceIndex = _pendingText.substring(0, searchLimit).lastIndexOf(' ');
          if (spaceIndex >= 25) {
            splitPos = spaceIndex;
          }
        } else {
          // 中文无空格：在 28 字处断开
          splitPos = math.min(28, _pendingText.length);
        }

        if (splitPos > 0 && splitPos < _pendingText.length) {
          final clause = _pendingText.substring(0, splitPos).trim();
          final remaining = _pendingText.substring(splitPos).trimLeft();
          final fullLen = _pendingText.length;
          _pendingText = remaining;
          if (clause.isNotEmpty) {
            _emittedUtterances++;
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
    } else {
      // 正在讲话中的实时预览（isFinal = false），存入 session.partial 即时渲染在屏幕上
      // 彻底解决“句子等讲完/停顿后才延迟1-2秒刷出，随后迅速被下句刷新”的滞后感！
      final preview = _pendingText.trim();
      if (preview.isNotEmpty && preview.length >= 2) {
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
