import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pilipala/utils/storage.dart';
import 'edge_tts_drm.dart';

/// TTS 语音发音配置与服务
class CaptionTtsConfig {
  const CaptionTtsConfig({
    required this.engine,
    required this.edgeCantoneseVoice,
    required this.mimoVoice,
    required this.mimoApiKey,
    required this.mimoBaseUrl,
  });

  /// tts 引擎: 'edge' | 'mimo' | 'system'
  final String engine;
  final String edgeCantoneseVoice;
  final String mimoVoice;
  final String mimoApiKey;
  final String mimoBaseUrl;

  static const String keyEngine = 'caption_tts_engine';
  static const String keyEdgeVoice = 'caption_tts_edge_voice';
  static const String keyMiMoVoice = 'caption_tts_mimo_voice';
  static const String keyMiMoApiKey = 'caption_tts_mimo_api_key';
  static const String keyMiMoBaseUrl = 'caption_tts_mimo_base_url';

  static const String defaultEngine = 'edge';
  static const String defaultEdgeVoice = 'zh-HK-HiuMaanNeural';
  static const String defaultMiMoVoice = 'default';
  static const String defaultMiMoBaseUrl = 'https://api.xiaomimimo.com/v1';

  static CaptionTtsConfig load() {
    try {
      final box = GStrorage.setting;
      return CaptionTtsConfig(
        engine: box.get(keyEngine, defaultValue: defaultEngine) as String,
        edgeCantoneseVoice: box.get(keyEdgeVoice, defaultValue: defaultEdgeVoice) as String,
        mimoVoice: box.get(keyMiMoVoice, defaultValue: defaultMiMoVoice) as String,
        mimoApiKey: box.get(keyMiMoApiKey, defaultValue: '') as String,
        mimoBaseUrl: box.get(keyMiMoBaseUrl, defaultValue: defaultMiMoBaseUrl) as String,
      );
    } catch (_) {
      return const CaptionTtsConfig(
        engine: defaultEngine,
        edgeCantoneseVoice: defaultEdgeVoice,
        mimoVoice: defaultMiMoVoice,
        mimoApiKey: '',
        mimoBaseUrl: defaultMiMoBaseUrl,
      );
    }
  }

  Future<void> save() async {
    try {
      final box = GStrorage.setting;
      await box.put(keyEngine, engine);
      await box.put(keyEdgeVoice, edgeCantoneseVoice);
      await box.put(keyMiMoVoice, mimoVoice);
      await box.put(keyMiMoApiKey, mimoApiKey);
      await box.put(keyMiMoBaseUrl, mimoBaseUrl);
    } catch (_) {}
  }
}

/// 字典与注音发音服务（同时支持 Microsoft Edge-TTS 与 小米 MiMo-V2.5-TTS）
class CaptionTtsService {
  static final shared = CaptionTtsService._();
  CaptionTtsService._();

  CaptionTtsConfig _config = CaptionTtsConfig.load();
  CaptionTtsConfig get config => _config;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
  ));

  // Edge-TTS 粤语发音人列表
  static const Map<String, String> edgeCantoneseVoices = {
    'zh-HK-HiuMaanNeural': '晓曼 (女声 · 自然甜美 · 默认)',
    'zh-HK-WanLungNeural': '云龙 (男声 · 沉稳大气)',
    'zh-HK-HiuGaaiNeural': '晓佳 (女声 · 活泼灵动)',
  };

  // 小米 MiMo-V2.5-TTS 音色列表
  static const Map<String, String> mimoVoices = {
    'default': '官方默认音色',
    '冰糖': '冰糖 (清澈明亮女声)',
    '茉莉': '茉莉 (温柔舒缓女声)',
    '苏打': '苏打 (阳光青年男声)',
    '白桦': '白桦 (深沉稳重男声)',
  };

  Future<void> updateConfig({
    String? engine,
    String? edgeCantoneseVoice,
    String? mimoVoice,
    String? mimoApiKey,
    String? mimoBaseUrl,
  }) async {
    _config = CaptionTtsConfig(
      engine: engine ?? _config.engine,
      edgeCantoneseVoice: edgeCantoneseVoice ?? _config.edgeCantoneseVoice,
      mimoVoice: mimoVoice ?? _config.mimoVoice,
      mimoApiKey: mimoApiKey ?? _config.mimoApiKey,
      mimoBaseUrl: mimoBaseUrl ?? _config.mimoBaseUrl,
    );
    await _config.save();
    // 切换音色或配置后立即清理缓存，确保新发音人生效
    await clearCache();
  }

  /// 清理已缓存的 TTS 音频文件
  Future<void> clearCache() async {
    try {
      final tempDir = await _getTempDirectory();
      final entities = tempDir.listSync();
      for (final entity in entities) {
        if (entity is File && entity.path.contains('tts_cached_')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 预加载合成并缓存音频，使点击时 0ms 瞬间秒播
  void preload({required String text, required String lang}) {
    if (text.trim().isEmpty) return;
    synthesize(text: text, lang: lang);
  }

  /// 将 MiMo 音色智能映射到 Edge-TTS 对应男女声音色（免 Key 也能听到男女音色变化）
  String _mapMiMoVoiceToEdge(String mimoVoice, bool isCantonese) {
    if (isCantonese) {
      switch (mimoVoice) {
        case '白桦':
        case '苏打':
          return 'zh-HK-WanLungNeural'; // 男声
        case '茉莉':
          return 'zh-HK-HiuGaaiNeural'; // 灵动女声
        case '冰糖':
        case 'default':
        default:
          return 'zh-HK-HiuMaanNeural'; // 甜美女声
      }
    } else {
      switch (mimoVoice) {
        case '白桦':
          return 'zh-CN-YunjianNeural'; // 男声播音
        case '苏打':
          return 'zh-CN-YunxiNeural'; // 男声阳光
        case '茉莉':
          return 'zh-CN-XiaoyiNeural'; // 女声
        case '冰糖':
        case 'default':
        default:
          return 'zh-CN-XiaoxiaoNeural'; // 女声
      }
    }
  }

  /// 核心语音合成入口，返回本地可播放的 MP3/WAV 缓存文件
  Future<File?> synthesize({
    required String text,
    required String lang,
    String? specificVoice,
  }) async {
    final query = text.trim();
    if (query.isEmpty) return null;

    final isYue = lang == 'yue' || lang == 'zh-HK';
    final hasMiMoKey = _config.mimoApiKey.trim().isNotEmpty;

    // 区分具体音色作为缓存唯一键，彻底杜绝切换发音人后仍读取老缓存的问题
    final effectiveVoice = (_config.engine == 'mimo' && hasMiMoKey)
        ? 'mimo_${_config.mimoVoice}'
        : (specificVoice ??
            (_config.engine == 'mimo'
                ? 'edge_fallback_${_mapMiMoVoiceToEdge(_config.mimoVoice, isYue)}'
                : (isYue ? _config.edgeCantoneseVoice : _selectEdgeVoice(lang))));

    final cacheKey = '${_config.engine}_${effectiveVoice}_${lang}_$query';
    final cached = await _getCachedFile(cacheKey);
    if (cached != null) return cached;

    // 1. 小米 MiMo-V2.5-TTS (大模型情感/方言合成，需填写 API Key)
    if (_config.engine == 'mimo' && hasMiMoKey) {
      try {
        final mimoFile = await _synthesizeMiMo(query, isCantonese: isYue, cacheKey: cacheKey);
        if (mimoFile != null) return mimoFile;
      } catch (_) {}
    }

    // 2. Microsoft Edge-TTS (免 API Key，内置纯正香港粤语发音人，秒速高保真)
    try {
      final edgeVoice = (_config.engine == 'mimo')
          ? _mapMiMoVoiceToEdge(_config.mimoVoice, isYue)
          : (specificVoice ?? (isYue ? _config.edgeCantoneseVoice : _selectEdgeVoice(lang)));
      final edgeFile = await _synthesizeEdge(query, voice: edgeVoice, cacheKey: cacheKey);
      if (edgeFile != null) return edgeFile;
    } catch (_) {}

    return null;
  }

  String _selectEdgeVoice(String lang) {
    switch (lang.toLowerCase()) {
      case 'yue':
      case 'zh-hk':
        return _config.edgeCantoneseVoice;
      case 'zh':
      case 'zh-cn':
        return 'zh-CN-XiaoxiaoNeural';
      case 'en':
      case 'en-us':
        return 'en-US-JennyNeural';
      case 'en-gb':
        return 'en-GB-SoniaNeural';
      case 'ja':
        return 'ja-JP-NanamiNeural';
      case 'ko':
        return 'ko-KR-SunHiNeural';
      default:
        return 'zh-CN-XiaoxiaoNeural';
    }
  }

  /// 小米 MiMo-V2.5-TTS 合成实现
  /// 遵循小米官方接入规范: https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/audio/speech-synthesis-v2.5
  Future<File?> _synthesizeMiMo(
    String text, {
    required bool isCantonese,
    required String cacheKey,
  }) async {
    final apiKey = _config.mimoApiKey.trim();
    if (apiKey.isEmpty) return null;

    final baseUrl = _config.mimoBaseUrl.trim().isNotEmpty
        ? _config.mimoBaseUrl.trim()
        : CaptionTtsConfig.defaultMiMoBaseUrl;
    final url = '$baseUrl/chat/completions';

    // MiMo 官方粤语指令与方言标签
    final prompt = isCantonese
        ? '请用标准地道的香港粤语发音朗读该词语，发音纯正自然'
        : '请用清晰自然的普通话朗读该词语';
    final targetContent = isCantonese ? '(粤语)$text' : text;

    final voiceParam = _config.mimoVoice == 'default' ? null : _config.mimoVoice;
    final audioConfig = <String, dynamic>{'format': 'mp3'};
    if (voiceParam != null && voiceParam.isNotEmpty) {
      audioConfig['voice'] = voiceParam;
    }

    final payload = {
      'model': 'mimo-v2.5-tts',
      'messages': [
        {'role': 'user', 'content': prompt},
        {'role': 'assistant', 'content': targetContent},
      ],
      'audio': audioConfig,
    };

    final response = await _dio.post<Map<String, dynamic>>(
      url,
      data: payload,
      options: Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
      ),
    );

    final data = response.data;
    if (data == null || data['choices'] is! List || (data['choices'] as List).isEmpty) {
      return null;
    }

    final firstChoice = data['choices'][0];
    if (firstChoice is! Map || firstChoice['message'] is! Map) return null;
    final message = firstChoice['message'] as Map;
    if (message['audio'] is! Map || message['audio']['data'] == null) return null;

    final base64Audio = message['audio']['data'].toString();
    final bytes = base64.decode(base64Audio);
    if (bytes.isNotEmpty) {
      return _saveCacheFile(cacheKey, bytes);
    }
    return null;
  }

  /// Microsoft Edge-TTS 纯 Dart 原生 WebSocket 极速合成实现
  Future<File?> _synthesizeEdge(
    String text, {
    required String voice,
    required String cacheKey,
  }) async {
    final client = HttpClient();
    client.userAgent = null; // 移除默认 Dart User-Agent，避免 WAF 403

    final gec = EdgeTtsDrm.generateSecMsGec();
    final randomHex = List.generate(16, (_) => Random().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final connId = List.generate(16, (_) => Random().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final url =
        'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=${EdgeTtsDrm.trustedClientToken}&Sec-MS-GEC=$gec&Sec-MS-GEC-Version=2-143.0.3650.75&ConnectionId=$connId';

    final headers = {
      'Pragma': 'no-cache',
      'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
      'Accept-Encoding': 'gzip, deflate, br, zstd',
      'Accept-Language': 'en-US,en;q=0.9',
      'Cookie': 'muid=$randomHex;',
    };

    WebSocket? ws;
    try {
      ws = await WebSocket.connect(url, headers: headers, customClient: client)
          .timeout(const Duration(seconds: 6));

      final nowStr = HttpDate.format(DateTime.now());
      // 1. 发送 speech.config
      ws.add(
        'X-Timestamp:$nowStr\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
      );

      // 2. 发送 SSML
      final reqId = List.generate(16, (_) => Random().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final escapedText = text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      final ssml =
          "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='$voice'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>$escapedText</prosody></voice></speak>";

      ws.add(
        'X-RequestId:$reqId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${nowStr}Z\r\n'
        'Path:ssml\r\n\r\n'
        '$ssml',
      );

      final audioBytes = <int>[];
      final completer = Completer<void>();

      ws.listen(
        (dynamic msg) {
          if (msg is String) {
            if (msg.contains('Path:turn.end')) {
              if (!completer.isCompleted) completer.complete();
            }
          } else {
            final bytes = msg is Uint8List ? msg : Uint8List.fromList(List<int>.from(msg as List));
            if (bytes.length > 2) {
              final headerLen = (bytes[0] << 8) | bytes[1];
              if (bytes.length > 2 + headerLen) {
                final headerText = ascii.decode(bytes.sublist(2, 2 + headerLen));
                if (headerText.contains('Path:audio')) {
                  audioBytes.addAll(bytes.sublist(2 + headerLen));
                }
              }
            }
          }
        },
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future.timeout(const Duration(seconds: 8));
      if (audioBytes.isNotEmpty) {
        return _saveCacheFile(cacheKey, audioBytes);
      }
    } finally {
      try {
        await ws?.close();
      } catch (_) {}
    }

    return null;
  }

  Future<Directory> _getTempDirectory() async {
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<File?> _getCachedFile(String cacheKey) async {
    try {
      final hash = md5.convert(utf8.encode(cacheKey)).toString();
      final tempDir = await _getTempDirectory();
      final file = File('${tempDir.path}/tts_cached_$hash.mp3');
      if (await file.exists() && await file.length() > 500) {
        return file;
      }
    } catch (_) {}
    return null;
  }

  Future<File> _saveCacheFile(String cacheKey, List<int> bytes) async {
    final hash = md5.convert(utf8.encode(cacheKey)).toString();
    final tempDir = await _getTempDirectory();
    final file = File('${tempDir.path}/tts_cached_$hash.mp3');
    await file.writeAsBytes(bytes);
    return file;
  }
}
