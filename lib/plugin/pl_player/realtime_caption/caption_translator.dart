import 'dart:convert';

import 'package:dio/dio.dart';

import 'caption_pronunciation.dart';
import 'offline_translation_manager.dart';

class CaptionTranslator {
  CaptionTranslator({Dio? client})
      : _client = client ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              followRedirects: true,
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0',
                'Accept': '*/*',
              },
            ));

  final Dio _client;

  static const Map<String, String> translationEngines = {
    'microsoft': '微软翻译 (国内直连 · 免翻墙)',
    'google': '谷歌翻译 (需代理/外网)',
    'local': '本地离线翻译 (Google ML Kit · 15ms)',
  };

  static const Map<String, String> supportedLanguages = {
    'zh-CN': '简体中文',
    'zh-TW': '繁体中文',
    'en': '英语 (English)',
    'ja': '日语 (日本語)',
    'ko': '韩语 (한국어)',
    'fr': '法语 (Français)',
    'de': '德语 (Deutsch)',
    'es': '西班牙语 (Español)',
    'ru': '俄语 (Русский)',
    'vi': '越南语 (Tiếng Việt)',
    'th': '泰语 (ไทย)',
  };

  static String _toMicrosoftLang(String lang) {
    switch (lang) {
      case 'zh-CN':
        return 'zh-Hans';
      case 'zh-TW':
        return 'zh-Hant';
      default:
        return lang;
    }
  }

  Future<String> translate(
    String text,
    CancelToken token, {
    String sourceLang = 'auto',
    String targetLang = 'zh-CN',
    String engine = 'microsoft',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return text;

    String effectiveSource = sourceLang;
    if (effectiveSource == 'auto' || effectiveSource.isEmpty) {
      if (CaptionPronunciation.isCantoneseText(trimmed)) {
        effectiveSource = 'yue';
      }
    }

    if (engine == 'local' || engine == 'mlkit') {
      try {
        final localResult = await OfflineTranslationManager.shared.translate(
          trimmed,
          sourceLang: effectiveSource,
          targetLang: targetLang,
          token: token,
        );
        if (localResult != null && localResult.isNotEmpty) {
          return localResult;
        }
      } catch (_) {}
      // 本地离线未就绪或未下载对应模型时，若有网络自动降级为微软云端翻译；若网络不通则优雅兜底保持原文，绝不乱吐不相关的词
      try {
        return await _translateWithMicrosoft(
          trimmed,
          token,
          targetLang: targetLang,
          sourceLang: effectiveSource,
        );
      } catch (_) {
        try {
          return await _translateWithGoogle(
            trimmed,
            token,
            targetLang: targetLang,
            sourceLang: effectiveSource,
          );
        } catch (_) {
          return trimmed;
        }
      }
    } else if (engine == 'google') {
      try {
        return await _translateWithGoogle(
          trimmed,
          token,
          targetLang: targetLang,
          sourceLang: effectiveSource,
        );
      } catch (e) {
        // 谷歌失败（如 429 验证码/网络不通），自动无缝降级到微软翻译
        return await _translateWithMicrosoft(
          trimmed,
          token,
          targetLang: targetLang,
          sourceLang: effectiveSource,
        );
      }
    } else {
      try {
        return await _translateWithMicrosoft(
          trimmed,
          token,
          targetLang: targetLang,
          sourceLang: effectiveSource,
        );
      } catch (e) {
        // 微软失败，尝试降级到谷歌翻译
        return await _translateWithGoogle(
          trimmed,
          token,
          targetLang: targetLang,
          sourceLang: effectiveSource,
        );
      }
    }
  }

  Future<String> _translateWithMicrosoft(
    String trimmed,
    CancelToken token, {
    required String targetLang,
    String? sourceLang,
  }) async {
    final msTargetLang = _toMicrosoftLang(targetLang);
    final queryParams = <String, dynamic>{'to': msTargetLang};
    final bool isYue = sourceLang == 'yue' || CaptionPronunciation.isCantoneseText(trimmed);
    if (isYue) {
      queryParams['from'] = 'yue';
    } else if (sourceLang != null && sourceLang.isNotEmpty && sourceLang != 'auto') {
      queryParams['from'] = sourceLang;
    }

    final response = await _client.post<dynamic>(
      'https://edge.microsoft.com/translate/translatetext',
      queryParameters: queryParams,
      data: jsonEncode([trimmed]),
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0',
        },
      ),
      cancelToken: token,
    );
    final dynamic data = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    if (data is List && data.isNotEmpty) {
      final first = data[0];
      if (first is Map && first['translations'] is List) {
        final translations = first['translations'] as List;
        if (translations.isNotEmpty && translations[0] is Map) {
          final translated = translations[0]['text']?.toString().trim() ?? '';
          if (translated.isNotEmpty) return translated;
        }
      }
    }
    return trimmed;
  }

  static const _googleEndpoints = [
    'https://translate.googleapis.com/translate_a/single',
    'https://translate.google.com/translate_a/single',
    'https://google.qianche.dpdns.org/translate_a/single',
  ];

  Future<String> _translateWithGoogle(
    String trimmed,
    CancelToken token, {
    required String targetLang,
    String? sourceLang,
  }) async {
    final bool isYue = sourceLang == 'yue' || CaptionPronunciation.isCantoneseText(trimmed);
    final sl = isYue
        ? 'yue'
        : ((sourceLang != null && sourceLang.isNotEmpty && sourceLang != 'auto')
            ? sourceLang
            : 'auto');

    for (final endpoint in _googleEndpoints) {
      try {
        final response = await _client.get<String>(
          endpoint,
          queryParameters: {
            'client': 'dict-chrome-ex',
            'sl': sl,
            'tl': targetLang,
            'dt': 't',
            'q': trimmed,
          },
          options: Options(
            responseType: ResponseType.plain,
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
          cancelToken: token,
        );
        final data = jsonDecode(response.data ?? '');
        final parts = data is List && data.isNotEmpty ? data.first : null;
        if (parts is! List) return trimmed;
        final result = StringBuffer();
        for (final part in parts) {
          if (part is List && part.isNotEmpty && part.first is String) {
            result.write(part.first);
          }
        }
        final translated = result.toString().trim();
        if (translated.isNotEmpty) return translated;
      } catch (_) {
        // Continue to fallback endpoint
      }
    }
    return trimmed;
  }

  Future<String> toChinese(String text, CancelToken token) =>
      translate(text, token, targetLang: 'zh-CN');

  /// 句子边界智能分块算法 (借鉴自 D:\app\realtime-asr OnlineTranslation.chunks)
  /// 在遇到超长字幕文本或批量翻译时，优先在自然标点符号 (。！？.!?\n ) 处断句分块，
  /// 坚决避免在单词或中文字符中间生硬切断导致机器翻译上下文丧失与乱码
  static List<String> splitChunks(String text, {int limit = 600}) {
    if (text.length <= limit) return [text];
    final out = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = start + limit < text.length ? start + limit : text.length;
      if (end < text.length) {
        var boundary = -1;
        for (var i = end - 1; i > start + (limit ~/ 2); i--) {
          final ch = text[i];
          if ('。！？.!?\n '.contains(ch)) {
            boundary = i + 1;
            break;
          }
        }
        if (boundary > start) {
          end = boundary;
        }
      }
      out.add(text.substring(start, end));
      start = end;
    }
    return out;
  }

  void close() => _client.close(force: true);
}
