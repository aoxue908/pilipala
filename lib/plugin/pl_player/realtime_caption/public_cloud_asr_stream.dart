import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'asr_stream.dart';

/// 微软 Azure 流式语音识别 (免 Key 即开即用)
class AzureAsrStream implements CaptionAsrStream {
  AzureAsrStream({
    this.language = 'zh-CN',
    this.host = 'usgovarizona.api.speech.azure.us',
  });

  static const List<String> defaultHosts = [
    'usgovarizona.api.speech.azure.us',
    'chinaeast2.api.speech.azure.cn',
    'api.speech.microsoft.com',
  ];

  final String language;
  final String host;

  WebSocket? _socket;
  bool _ready = false;
  bool _done = false;
  int _sentMs = 0;
  int? _processedMs;
  int _utteranceIndex = 0;
  String _lastHypothesis = '';
  final String _connectionId = const Uuid().v4().replaceAll('-', '');

  @override
  int get maxAudioBytes => 16000 * 2 * 60 * 60; // 1 小时上限，杜绝频繁断开

  @override
  int get sentMilliseconds => _sentMs;

  @override
  int? get processedMilliseconds => _processedMs;

  @override
  bool get done => _done;

  @override
  int get decodeChunkMs => 100;

  static String originForHost(String h) {
    if (h.endsWith('.azure.cn')) return 'https://speech.azure.cn';
    if (h.endsWith('.azure.us')) return 'https://speech.azure.us';
    return 'https://speech.microsoft.com';
  }

  /// Azure Words 的 Offset/Duration 单位为 100ns tick。
  static List<Map<String, dynamic>> normalizedWordTimings(dynamic raw) {
    if (raw is! List) return const [];
    final words = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) return const [];
      final offset = item['Offset'];
      final duration = item['Duration'];
      if (offset is! num || duration is! num) return const [];
      words.add({
        'word': item['Word'],
        'start_ms': offset / 10000,
        'end_ms': (offset + duration) / 10000,
      });
    }
    return readAsrWords(words).map((word) => word.toJson()).toList();
  }

  static String normalizeAzureLang(String? lang) {
    if (lang == null || lang.trim().isEmpty || lang == 'auto' || lang == 'multi') return 'zh-CN';
    final l = lang.trim().toLowerCase();
    if (l == 'zh' || l == 'zh-cn' || l == 'zh-hans') return 'zh-CN';
    if (l == 'zh-tw' || l == 'zh-hant') return 'zh-TW';
    if (l == 'yue' || l == 'zh-hk') return 'zh-HK';
    if (l == 'en' || l.startsWith('en')) return 'en-US';
    if (l == 'ja' || l.startsWith('ja')) return 'ja-JP';
    if (l == 'ko' || l.startsWith('ko')) return 'ko-KR';
    if (l == 'fr' || l.startsWith('fr')) return 'fr-FR';
    if (l == 'de' || l.startsWith('de')) return 'de-DE';
    if (l == 'es' || l.startsWith('es')) return 'es-ES';
    if (l == 'ru' || l.startsWith('ru')) return 'ru-RU';
    return lang;
  }

  String _header(String path) {
    return 'Path: $path\r\nX-RequestId: $_connectionId\r\nX-Timestamp: ${DateTime.now().toUtc().toIso8601String()}\r\n';
  }

  Uint8List _audioFrame(Uint8List audio, {bool wavHeader = false}) {
    final headerStr = '${_header("audio")}${wavHeader ? "Content-Type: audio/x-wav\r\n" : ""}';
    final headerBytes = utf8.encode(headerStr);
    final totalLength = 2 + headerBytes.length + audio.length;
    final buffer = ByteData(totalLength);
    buffer.setUint16(0, headerBytes.length, Endian.big);
    final uint8List = buffer.buffer.asUint8List();
    uint8List.setRange(2, 2 + headerBytes.length, headerBytes);
    uint8List.setRange(2 + headerBytes.length, totalLength, audio);
    return uint8List;
  }

  static Uint8List _wavHeader() {
    final header = ByteData(44);
    header.setUint32(0, 0x52494646, Endian.big); // "RIFF"
    header.setUint32(4, 44, Endian.little);
    header.setUint32(8, 0x57415645, Endian.big); // "WAVE"
    header.setUint32(12, 0x666d7420, Endian.big); // "fmt "
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM format
    header.setUint16(22, 1, Endian.little); // 1 channel
    header.setUint32(24, 16000, Endian.little); // 16kHz
    header.setUint32(28, 32000, Endian.little); // byte rate
    header.setUint16(32, 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // 16 bits
    header.setUint32(36, 0x64617461, Endian.big); // "data"
    header.setUint32(40, 0, Endian.little);
    return header.buffer.asUint8List();
  }

  @override
  Future<void> connect(
    Uri endpoint, {
    IeeioTokenLoader? ieeioLoginToken,
    String? language,
    required void Function(Map<String, dynamic>) onResult,
    required void Function(AsrStreamException) onError,
  }) async {
    final effLang = normalizeAzureLang(language ?? this.language);
    final hostsToTry = [
      if (host.isNotEmpty) host,
      for (final h in defaultHosts) if (h != host) h,
    ];

    WebSocket? connectedSocket;
    Object? lastErr;

    for (final targetHost in hostsToTry) {
      final origin = originForHost(targetHost);
      final uri = Uri.parse('wss://$targetHost/speech/recognition/conversation/cognitiveservices/v1').replace(
        queryParameters: {
          'language': effLang,
          'X-ConnectionId': _connectionId,
          'format': 'detailed',
          'lidEnabled': 'false',
          'profanity': 'raw',
          'wordLevelTimestamps': 'true',
          'postprocessing': 'truetext',
        },
      );

      try {
        connectedSocket = await WebSocket.connect(
          uri.toString(),
          headers: {
            'Origin': origin,
            'User-Agent': 'ClearCaption/Android',
          },
        ).timeout(const Duration(seconds: 4));
        break;
      } catch (e) {
        lastErr = e;
      }
    }

    if (connectedSocket == null) {
      final errStr = lastErr?.toString() ?? '所有节点不可用';
      final isRateLimit = errStr.contains('429');
      onError(AsrStreamException(
        isRateLimit ? '微软在线服务当前限流，请稍后重试' : '无法连接微软流式识别服务: $errStr',
        retryable: true,
      ));
      return;
    }

    _socket = connectedSocket;

    try {
      // 握手包发送
      final configJson = jsonEncode({
        'context': {
          'system': {'name': 'ClearCaption', 'version': '1', 'lang': 'Dart'},
          'audio': {
            'source': {
              'bitspersample': 16,
              'channelcount': 1,
              'samplerate': 16000,
              'type': 'Microphones'
            }
          }
        },
        'recognition': 'conversation'
      });

      final contextJson = jsonEncode({
        'phraseOutput': {
          'format': 'Detailed',
          'interimResults': {'resultType': 'Auto'},
          'phraseResults': {'resultType': 'Always'}
        },
        'phraseDetection': {
          'mode': 'Conversation',
          'trailingSilenceTimeout': 60000,
          'conversation': {
            'segmentation': {'mode': 'Custom', 'segmentationSilenceTimeoutMs': 1000}
          }
        }
      });

      _socket!.add('${_header("speech.config")}Content-Type: application/json\r\n\r\n$configJson\r\n');
      _socket!.add('${_header("speech.context")}Content-Type: application/json\r\n\r\n$contextJson\r\n');
      _socket!.add(_audioFrame(_wavHeader(), wavHeader: true));
      // 发送握手包及 WAV 头后立即标记准备就绪，允许音频帧持续流入微软服务器
      _ready = true;

      _socket!.listen(
        (message) {
          if (message is String) {
            final split = message.indexOf('\r\n\r\n');
            final headers = split < 0 ? message : message.substring(0, split);
            String path = '';
            for (final line in headers.split('\r\n')) {
              final colon = line.indexOf(':');
              if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == 'path') {
                path = line.substring(colon + 1).trim().toLowerCase();
                break;
              }
            }

            if (path == 'turn.start') {
              _ready = true;
              return;
            }

            if (path == 'turn.end') {
              // 说话人停顿/Utterance 结束，但 WebSocket 连接持续保持接收后续音轨，切勿设置 _done = true 导致会话中断重连
              onResult({
                'turn_end': true,
                'speech_final': true,
                'isFinal': true,
                'audio_ms': _processedMs,
              });
              return;
            }

            final isFinal = path == 'speech.phrase';
            if ((!isFinal && path != 'speech.hypothesis') || split < 0) return;

            final body = message.substring(split + 4).trim();
            if (body.isEmpty) return;

            try {
              final json = jsonDecode(body) as Map<String, dynamic>;
              final offsetTicks = json['Offset'] is num ? (json['Offset'] as num).toInt() : 0;
              final durationTicks = json['Duration'] is num ? (json['Duration'] as num).toInt() : 0;
              final startMs = offsetTicks ~/ 10000;
              final durationMs = durationTicks ~/ 10000;
              final audioMs = startMs + durationMs;
              // NoMatch/静音结果也可能携带音频处理进度，先更新再过滤文字。
              if (audioMs > (_processedMs ?? 0)) _processedMs = audioMs;
              if (isFinal && json['RecognitionStatus'] != 'Success') return;
              final alternatives = json['NBest'];
              final best = alternatives is List && alternatives.isNotEmpty &&
                      alternatives.first is Map
                  ? alternatives.first as Map
                  : null;
              final display = best == null ? null : best['Display'] ?? best['Lexical'];
              final rawText = isFinal ? (json['DisplayText'] ?? display) : json['Text'];
              final text = rawText?.toString().trim() ?? '';
              if (text.isEmpty) return;
              final wordTimings = normalizedWordTimings(
                  json['Words'] ?? (best == null ? null : best['Words']));
              _processedMs ??= _sentMs;

              if (isFinal) {
                _utteranceIndex++;
                _lastHypothesis = '';
                onResult({
                  'text': text,
                  'isFinal': true,
                  'utterance': _utteranceIndex,
                  'delta': text,
                  'start_ms': startMs,
                  'audio_ms': _processedMs,
                  'utterance_end': true,
                  'words': wordTimings,
                });
              } else {
                if (text == _lastHypothesis) return;
                _lastHypothesis = text;
                onResult({
                  'text': text,
                  'isFinal': false,
                  'utterance': _utteranceIndex,
                  'delta': '', // 假说文本非单字增量，设为空避免下游累加堆叠导致字符串重复
                  'start_ms': startMs,
                  'audio_ms': _processedMs,
                  'utterance_end': false,
                  'words': wordTimings,
                });
              }
            } catch (_) {}
          }
        },
        onError: (err) {
          onError(AsrStreamException('微软流式识别连接异常: $err', retryable: true));
        },
        onDone: () {
          _done = true;
        },
      );
    } catch (e) {
      onError(AsrStreamException('无法连接微软流式识别服务: $e', retryable: true));
    }
  }

  @override
  Future<void> send(Uint8List pcm) async {
    if (_socket != null && _ready && !_done) {
      _sentMs += pcm.length ~/ 32;
      _socket!.add(_audioFrame(pcm));
    }
  }

  @override
  Future<void> finish() async {
    if (_socket != null && _ready && !_done) {
      _socket!.add(_audioFrame(Uint8List(0)));
    }
  }

  @override
  void close() {
    _done = true;
    _ready = false;
    _socket?.close();
    _socket = null;
  }
}

/// Deepgram Nova-3 在线流式识别
class DeepgramAsrStream implements CaptionAsrStream {
  DeepgramAsrStream({
    required this.apiKey,
    this.language = 'zh-CN',
  });

  final String apiKey;
  final String language;

  WebSocket? _socket;
  bool _ready = false;
  bool _done = false;
  int _sentMs = 0;
  int? _processedMs;
  int _utteranceIndex = 0;
  String _lastHypothesis = '';

  @override
  int get maxAudioBytes => 16000 * 2 * 60 * 60; // 1 小时上限，杜绝频繁断开

  @override
  int get sentMilliseconds => _sentMs;

  @override
  int? get processedMilliseconds => _processedMs;

  @override
  bool get done => _done;

  @override
  int get decodeChunkMs => 100;

  static String normalizeLang(String? lang) {
    if (lang == null || lang.trim().isEmpty || lang == 'auto' || lang == 'multi') return 'multi';
    final v = lang.replaceAll('_', '-').toLowerCase();
    if (v.startsWith('cmn-hant') || v == 'zh-tw' || v == 'zh-hant') return 'zh-TW';
    if (v.startsWith('yue') || v == 'zh-hk') return 'zh-HK';
    if (v.startsWith('cmn') || v == 'zh-cn' || v == 'zh-hans') return 'zh-CN';
    if (v == 'zh') return 'zh';
    if (v.startsWith('en')) return 'en';
    if (v.startsWith('ja')) return 'ja';
    if (v.startsWith('ko')) return 'ko';
    return v.split('-').first;
  }

  /// 相邻词间隔 >= 该阈值（毫秒）视为一次气息停顿，插入一个空格分隔文本。
  /// 与连接参数 endpointing=300 对齐，略小一点以捕获自然停顿。
  static const int breathPauseMs = 250;

  static List<Map<String, dynamic>> normalizedWordTimings(List<dynamic>? raw) {
    if (raw == null) return const [];
    final words = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) return const [];
      final start = item['start'];
      final end = item['end'];
      if (start is! num || end is! num) return const [];
      words.add({
        'word': item['punctuated_word'] ?? item['word'],
        'start_ms': start * 1000,
        'end_ms': end * 1000,
      });
    }
    return readAsrWords(words).map((word) => word.toJson()).toList();
  }

  /// Deepgram 中文模型的 transcript 经常一个标点都没有、词全挤在一起，
  /// 阅读性差。它返回的 words 数组带有每个词的 start/end（秒），
  /// 用真实的时间间隔在停顿处插空格，比按字数瞎猜可靠得多。
  ///
  /// 设计要点：
  /// - 优先取 punctuated_word，避免丢掉 Deepgram 偶尔给出的标点；
  /// - word 自带前导空格时（英文常见）不重复插入；
  /// - words 缺失或时间戳无效时原样回退 transcript，绝不丢字。
  static String transcriptWithBreathPauses(
    String transcript,
    List<dynamic>? words,
  ) {
    if (words == null || words.isEmpty) return transcript;
    final buffer = StringBuffer();
    double? prevEndSec;
    var usedWord = false;
    for (final raw in words) {
      if (raw is! Map<String, dynamic>) continue;
      final word = (raw['punctuated_word'] ?? raw['word'] ?? '').toString();
      if (word.trim().isEmpty) continue;
      usedWord = true;
      final startSec = (raw['start'] as num?)?.toDouble();
      final endSec = (raw['end'] as num?)?.toDouble();
      if (prevEndSec != null &&
          startSec != null &&
          (startSec - prevEndSec) * 1000 >= breathPauseMs) {
        final current = buffer.toString();
        // word 自带前导空格（英文流式包常见）时不再插入，避免双空格
        if (current.isNotEmpty &&
            !current.endsWith(' ') &&
            !word.startsWith(RegExp(r'\s'))) {
          buffer.write(' ');
        }
      }
      buffer.write(word);
      if (endSec != null) {
        prevEndSec = endSec;
      } else if (startSec != null) {
        // 个别流式包没有 end，用 start 降级，后续间隔判断仍可用
        prevEndSec = startSec;
      }
    }
    if (!usedWord) return transcript;
    final rebuilt = buffer.toString().trim();
    return rebuilt.isEmpty ? transcript : rebuilt;
  }

  @override
  Future<void> connect(
    Uri endpoint, {
    IeeioTokenLoader? ieeioLoginToken,
    String? language,
    required void Function(Map<String, dynamic>) onResult,
    required void Function(AsrStreamException) onError,
  }) async {
    if (apiKey.trim().isEmpty) {
      onError(const AsrStreamException('请在字幕设置中填写 Deepgram API Key', retryable: false));
      return;
    }

    final effLang = normalizeLang(language ?? this.language);
    final uri = Uri.parse('wss://api.deepgram.com/v1/listen').replace(
      queryParameters: {
        'model': 'nova-3',
        'language': effLang,
        'encoding': 'linear16',
        'sample_rate': '16000',
        'channels': '1',
        'interim_results': 'true',
        'punctuate': 'true',
        'smart_format': 'true',
        'endpointing': '300',
      },
    );

    try {
      _socket = await WebSocket.connect(
        uri.toString(),
        headers: {
          'Authorization': 'Token ${apiKey.trim()}',
        },
      ).timeout(const Duration(seconds: 15));

      _ready = true;
      _socket!.listen(
        (message) {
          if (message is String) {
            try {
              final json = jsonDecode(message) as Map<String, dynamic>;
              final type = json['type'];
              if (type == 'Error') {
                final errDesc = json['description'] ?? json['message'] ?? '未知错误';
                onError(AsrStreamException('Deepgram 错误: $errDesc', retryable: false));
                return;
              }
              if (type == 'Results') {
                final isFinal = json['is_final'] == true;
                final speechFinal = json['speech_final'] == true;
                final channel = json['channel'] as Map<String, dynamic>?;
                final alts = channel?['alternatives'] as List<dynamic>?;
                String transcript = '';
                List<Map<String, dynamic>> wordTimings = const [];
                if (alts != null && alts.isNotEmpty) {
                  final first = alts.first as Map<String, dynamic>;
                  final rawTranscript = (first['transcript'] ?? '').toString().trim();
                  final words = first['words'] as List<dynamic>?;
                  wordTimings = normalizedWordTimings(words);
                  // 用词的真实时间戳在气息停顿处插空格，解决中文无标点挤成一团
                  transcript = transcriptWithBreathPauses(rawTranscript, words);
                }
                final start = (json['start'] as num?)?.toDouble() ?? 0.0;
                final duration = (json['duration'] as num?)?.toDouble() ?? 0.0;
                final startMs = (start * 1000).toInt();
                final durationMs = (duration * 1000).toInt();
                final audioMs = startMs + durationMs;
                _processedMs = audioMs > 0 ? audioMs : (startMs > 0 ? startMs : _sentMs);

                if (transcript.isNotEmpty) {
                  if (isFinal) {
                    _utteranceIndex++;
                    _lastHypothesis = '';
                    onResult({
                      'text': transcript,
                      'isFinal': true,
                      'speech_final': speechFinal,
                      'utterance': _utteranceIndex,
                      'delta': transcript,
                      'start_ms': startMs,
                      'audio_ms': _processedMs,
                      'utterance_end': true,
                      'words': wordTimings,
                    });
                  } else {
                    if (transcript == _lastHypothesis && wordTimings.isEmpty) return;
                    _lastHypothesis = transcript;
                    onResult({
                      'text': transcript,
                      'isFinal': false,
                      'speech_final': speechFinal,
                      'utterance': _utteranceIndex,
                      'delta': '', // 假说文本非增量，设为空防止堆叠重复
                      'start_ms': startMs,
                      'audio_ms': _processedMs,
                      'utterance_end': false,
                      'words': wordTimings,
                    });
                  }
                } else if (speechFinal) {
                  onResult({
                    'speech_final': true,
                    'isFinal': true,
                    'audio_ms': _processedMs,
                  });
                }
              }
            } catch (_) {}
          }
        },
        onError: (err) {
          onError(AsrStreamException('Deepgram 连接异常: $err', retryable: true));
        },
        onDone: () {
          _done = true;
        },
      );
    } catch (e) {
      final errStr = e.toString();
      final isAuth = errStr.contains('401') || errStr.contains('403') || errStr.contains('Unauthorized');
      onError(AsrStreamException(
        isAuth ? 'Deepgram API Key 无效或未授权，请检查密钥' : '无法连接 Deepgram: $e',
        retryable: !isAuth,
      ));
    }
  }

  @override
  Future<void> send(Uint8List pcm) async {
    if (_socket != null && _ready && !_done) {
      _sentMs += pcm.length ~/ 32;
      _socket!.add(pcm);
    }
  }

  @override
  Future<void> finish() async {
    if (_socket != null && _ready && !_done) {
      _socket!.add(jsonEncode({'type': 'CloseStream'}));
    }
  }

  @override
  void close() {
    _done = true;
    _ready = false;
    _socket?.close();
    _socket = null;
  }
}

/// 豆包流式语音识别 2.0 (Volcengine Seed-ASR)
class DoubaoAsrStream implements CaptionAsrStream {
  /// 豆包 utterances.words 已使用相对会话起点的毫秒。
  static List<Map<String, dynamic>> normalizedWordTimings(dynamic raw) {
    if (raw is! List) return const [];
    return readAsrWords([
      for (final item in raw)
        if (item is Map)
          {'word': item['text'], 'start_ms': item['start_time'],
            'end_ms': item['end_time']}
        else
          null,
    ]).map((word) => word.toJson()).toList();
  }

  DoubaoAsrStream({
    required this.authMode,
    this.apiKey = '',
    this.appId = '',
    this.accessToken = '',
    this.language = 'zh-CN',
  });

  final String authMode; // 'api_key' 或 'token'
  final String apiKey;
  final String appId;
  final String accessToken;
  final String language;

  WebSocket? _socket;
  bool _ready = false;
  bool _done = false;
  bool _reportedError = false;
  int _sentMs = 0;
  int? _processedMs;
  int _sequence = 1;
  int _utteranceIndex = 0;
  int _lastDefiniteEndMs = 0;
  String _lastDefiniteText = '';
  String _lastHypothesis = '';
  DateTime? _lastAudioSentAt;
  Timer? _healthCheckTimer;

  @override
  int get maxAudioBytes => 16000 * 2 * 60 * 60; // 1 小时上限，杜绝频繁断开

  @override
  int get sentMilliseconds => _sentMs;

  @override
  int? get processedMilliseconds => _processedMs;

  @override
  bool get done => _done;

  @override
  int get decodeChunkMs => 100;

  Uint8List _packet(int type, bool isLast, int seq, int serialization, Uint8List payload) {
    final header = ByteData(4);
    // Protocol version 1 (bits 7-4), Header size 1 (4 bytes, bits 3-0)
    header.setUint8(0, (1 << 4) | 1);
    // Message type (bits 7-4), Message flags (bits 3-0)
    // bit 0 = header 后 4 字节是否为 sequence number（本协议固定带 seq，恒为 1）
    // bit 1 = 是否为最后一包（负包）
    // 音频帧(seq>0) -> 0b0001，最后帧(seq<0) -> 0b0011
    header.setUint8(1, (type << 4) | (isLast ? 2 : 0) | 1);
    // Serialization method (bits 7-4: 1 = JSON), Compression (bits 3-0: 0 = None)
    header.setUint8(2, (serialization << 4) | 0);
    header.setUint8(3, 0); // Reserved

    final total = 4 + 4 + 4 + payload.length; // header(4) + seq(4) + size(4) + payload
    final buffer = ByteData(total);
    buffer.setUint8(0, header.getUint8(0));
    buffer.setUint8(1, header.getUint8(1));
    buffer.setUint8(2, header.getUint8(2));
    buffer.setUint8(3, header.getUint8(3));
    buffer.setInt32(4, seq, Endian.big);
    buffer.setInt32(8, payload.length, Endian.big);
    final uint8 = buffer.buffer.asUint8List();
    uint8.setRange(12, total, payload);
    return uint8;
  }

  void _reportError(
    AsrStreamException error,
    void Function(AsrStreamException) onError,
  ) {
    if (_reportedError || _done) return;
    _reportedError = true;
    _done = true;
    onError(error);
  }

  @override
  Future<void> connect(
    Uri endpoint, {
    IeeioTokenLoader? ieeioLoginToken,
    String? language,
    required void Function(Map<String, dynamic>) onResult,
    required void Function(AsrStreamException) onError,
  }) async {
    final isTokenMode = authMode == 'token';
    if (isTokenMode && (appId.trim().isEmpty || accessToken.trim().isEmpty)) {
      onError(const AsrStreamException('请在字幕设置中填写豆包 APP ID 和 Access Token', retryable: false));
      return;
    }
    if (!isTokenMode && apiKey.trim().isEmpty) {
      onError(const AsrStreamException('请在字幕设置中填写豆包语音 API Key', retryable: false));
      return;
    }

    final id = const Uuid().v4();
    final headers = <String, String>{
      'X-Api-Resource-Id': 'volc.seedasr.sauc.duration',
      'X-Api-Request-Id': id,
      'X-Api-Connect-Id': id,
      'X-Api-Sequence': '-1',
    };
    if (isTokenMode) {
      headers['X-Api-App-Key'] = appId.trim();
      headers['X-Api-Access-Key'] = accessToken.trim();
    } else {
      headers['X-Api-Key'] = apiKey.trim();
    }

    try {
      _socket = await WebSocket.connect(
        'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async',
        headers: headers,
      ).timeout(const Duration(seconds: 15));
      // WebSocket 层心跳保活，避免网关因长时间无控制帧而单方面断开
      _socket!.pingInterval = const Duration(seconds: 20);

      // 握手 JSON
      final langStr = (language ?? this.language).toLowerCase();
      final zhVariant = langStr.startsWith('yue') || langStr.contains('hk')
          ? 'hk'
          : (langStr.contains('tw') || langStr.contains('hant') ? 'tw' : null);

      final reqMap = {
        'user': {'uid': 'pilipala_caption'},
        'audio': {'format': 'pcm', 'codec': 'raw', 'rate': 16000, 'bits': 16, 'channel': 1},
        'request': {
          'model_name': 'bigmodel',
          'enable_itn': true,
          'enable_punc': true,
          'show_utterances': true,
          'result_type': 'single',
          'enable_nonstream': true,
          'end_window_size': 800,
          if (zhVariant != null) 'output_zh_variant': zhVariant,
        }
      };

      final payload = Uint8List.fromList(utf8.encode(jsonEncode(reqMap)));
      _socket!.add(_packet(1, false, _sequence++, 1, payload));
      // 关键修复：发送完配置握手包后立即可发送音频音轨，解除死锁
      _ready = true;
      _lastAudioSentAt = DateTime.now();
      // 半开连接健康检查。
      // 注意：豆包 bigmodel_async 是"结果变化时才回包"的双向流式接口，视频静音段 /
      // 纯音乐段服务端本就不会返回任何消息，因此绝不能用"是否收到回包"判断死链，
      // 否则每隔十几秒就会误判一次、主动断开，表现为字幕识别反复中断重连。
      // 这里以"音频是否仍在持续发出"为准：只要上层还在推音轨，就说明链路是活的；
      // 只有当音轨推送也停滞（上层暂停/卡死）时才认为是半开连接，触发重连。
      _healthCheckTimer?.cancel();
      _healthCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_done || _reportedError) return;
        final lastSent = _lastAudioSentAt;
        if (lastSent == null) return;
        final delta = DateTime.now().difference(lastSent);
        if (delta > const Duration(seconds: 45)) {
          _reportError(
            AsrStreamException(
              '视频音轨推送停滞 ${delta.inSeconds}s，正在重连',
              retryable: true,
            ),
            onError,
          );
          _socket?.close();
        }
      });

      _socket!.listen(
        (message) {
          if (message is List<int>) {
            try {
              final data = Uint8List.fromList(message);
              if (data.length < 12) return;
              final headerBytes = (data[0] & 15) * 4;
              final msgType = (data[1] & 255) >> 4;
              if (headerBytes < 4 || headerBytes > data.length) return;

              final wire = ByteData.sublistView(data, headerBytes);
              var offset = 0;
              final flags = data[1] & 15;
              if ((flags & 1) != 0) offset += 4;
              if ((flags & 4) != 0) offset += 4;
              if (msgType == 15) {
                // 错误回包：服务端大部分错误是临时的（比如会话冲突、参数校验失败），
                // 标记为 retryable 让上层自动重连，而不是直接放弃。
                final errCode = wire.getInt32(offset, Endian.big);
                _reportError(
                  AsrStreamException('豆包服务错误码: $errCode', retryable: true),
                  onError,
                );
                return;
              }
              final payloadSize = wire.getInt32(offset, Endian.big);
              offset += 4;
              if (payloadSize <= 0 || headerBytes + offset + payloadSize > data.length) return;

              final payloadBytes = data.sublist(headerBytes + offset, headerBytes + offset + payloadSize);
              final json = jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;

              final result = json['result'];
              if (result is Map) {
                final utterances = result['utterances'] as List<dynamic>?;
                if (utterances != null && utterances.isNotEmpty) {
                  for (int i = 0; i < utterances.length; i++) {
                    final u = utterances[i];
                    if (u is! Map) continue;
                    final text = (u['text'] ?? '').toString().trim();
                    final isFinal = u['definite'] == true;
                    final startMs = (u['start_time'] as num?)?.toInt() ?? 0;
                    final endMs = (u['end_time'] as num?)?.toInt() ?? 0;
                    final wordTimings = normalizedWordTimings(u['words']);
                    _processedMs = endMs > 0 ? endMs : _sentMs;

                    if (text.isEmpty) continue;

                    if (isFinal) {
                      // 定稿去重必须按"音频结束时间",不能用数组下标 i。
                      // result_type='single' 是增量模式,每次只回当前分句,i 恒为 0,
                      // 用 i 去重会导致第一句之后所有定稿被吞掉,字幕就此停住且无任何重连提示。
                      if (endMs > 0) {
                        // 同一批 utterances 里可能有多句 definite 且 end_time 相同/逆序，
                        // 只按 endMs 会把后句整句吞掉。文本不同就一律放行；仅当
                        // endMs 相同"且"文本与上一句完全相同才是真正的重复回包。
                        if (endMs < _lastDefiniteEndMs ||
                            (endMs == _lastDefiniteEndMs &&
                                text == _lastDefiniteText)) {
                          continue;
                        }
                        _lastDefiniteEndMs = endMs;
                        _lastDefiniteText = text;
                      }
                      _lastHypothesis = '';
                      _utteranceIndex++;
                      onResult({
                        'text': text,
                        'isFinal': true,
                        'speech_final': true,
                        'utterance': _utteranceIndex,
                        'delta': text,
                        'start_ms': startMs,
                        'audio_ms': _processedMs,
                        'utterance_end': true,
                        'words': wordTimings,
                      });
                    } else {
                      // 中间假说只处理当前最后一个正在识别的 utterance，防止假说重复拼接
                      if (i == utterances.length - 1 &&
                          (text != _lastHypothesis || wordTimings.isNotEmpty)) {
                        _lastHypothesis = text;
                        onResult({
                          'text': text,
                          'isFinal': false,
                          'speech_final': false,
                          'utterance': _utteranceIndex,
                          'delta': '',
                          'start_ms': startMs,
                          'audio_ms': _processedMs,
                          'utterance_end': false,
                          'words': wordTimings,
                        });
                      }
                    }
                  }
                } else {
                  final text = (result['text'] ?? '').toString().trim();
                  if (text.isNotEmpty && text != _lastHypothesis) {
                    _lastHypothesis = text;
                    onResult({
                      'text': text,
                      'isFinal': false,
                      'utterance': _utteranceIndex,
                      'delta': '',
                      'start_ms': 0,
                      'audio_ms': _sentMs,
                      'utterance_end': false,
                      'words': <Map<String, dynamic>>[],
                    });
                  }
                }
              }
            } catch (_) {}
          }
        },
        onError: (err) {
          _reportError(
            AsrStreamException('豆包识别连接异常: $err', retryable: true),
            onError,
          );
        },
        onDone: () {
          // 关键修复：服务端断开时主动上报可重试错误，触发上层自动重连，
          // 而不是只置 _done=true 让 _run 循环干等（半开连接时连 onDone 都没有，直接卡死）。
          _reportError(
            const AsrStreamException('豆包识别连接已断开', retryable: true),
            onError,
          );
        },
      );
    } catch (e) {
      final errStr = e.toString();
      final isAuth = errStr.contains('401') || errStr.contains('403') || errStr.contains('Unauthorized');
      onError(AsrStreamException(
        isAuth ? '豆包凭据无效或鉴权失败，请检查密钥与APP ID' : '无法连接豆包流式服务: $e',
        retryable: !isAuth,
      ));
    }
  }

  @override
  Future<void> send(Uint8List pcm) async {
    final socket = _socket;
    if (socket == null || !_ready || _done || _reportedError) return;
    // 半开连接检测：socket 非 open 时抛错，让上层 _run 捕获后自动重连，避免静默空转卡死。
    if (socket.readyState != WebSocket.open) {
      throw const AsrStreamException('豆包识别连接中断', retryable: true);
    }
    _sentMs += pcm.length ~/ 32;
    _lastAudioSentAt = DateTime.now();
    socket.add(_packet(2, false, _sequence++, 0, pcm));
  }

  @override
  Future<void> finish() async {
    if (_socket != null && _ready && !_done && !_reportedError) {
      _socket!.add(_packet(2, true, -_sequence++, 0, Uint8List(0)));
    }
  }

  @override
  void close() {
    _done = true;
    _ready = false;
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
    _socket?.close();
    _socket = null;
  }
}

/// 在线 ASR 流工厂类
class OnlineAsrStreamFactory {
  static CaptionAsrStream createStream({
    required String engine,
    String? doubaoAuthMode,
    String? doubaoApiKey,
    String? doubaoAppId,
    String? doubaoAccessToken,
    String? deepgramApiKey,
    String? language,
  }) {
    switch (engine) {
      case 'azure':
        return AzureAsrStream(language: language ?? 'zh-CN');
      case 'deepgram':
        return DeepgramAsrStream(
          apiKey: deepgramApiKey ?? '',
          language: language ?? 'zh-CN',
        );
      case 'doubao':
        return DoubaoAsrStream(
          authMode: doubaoAuthMode ?? 'api_key',
          apiKey: doubaoApiKey ?? '',
          appId: doubaoAppId ?? '',
          accessToken: doubaoAccessToken ?? '',
          language: language ?? 'zh-CN',
        );
      case 'qwen':
      default:
        return AsrStream();
    }
  }
}
