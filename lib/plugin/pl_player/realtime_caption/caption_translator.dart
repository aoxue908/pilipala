import 'dart:convert';

import 'package:dio/dio.dart';

class CaptionTranslator {
  CaptionTranslator({Dio? client})
      : _client = client ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 6),
              followRedirects: true,
            ));

  final Dio _client;

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

  Future<String> translate(
    String text,
    CancelToken token, {
    String targetLang = 'zh-CN',
  }) async {
    final response = await _client.get<String>(
      'https://translate.googleapis.com/translate_a/single',
      queryParameters: {
        'client': 'gtx',
        'sl': 'auto',
        'tl': targetLang,
        'dt': 't',
        'q': text,
      },
      options: Options(responseType: ResponseType.plain),
      cancelToken: token,
    );
    final data = jsonDecode(response.data ?? '');
    final parts = data is List && data.isNotEmpty ? data.first : null;
    if (parts is! List) throw const FormatException('Invalid translation');
    final result = StringBuffer();
    for (final part in parts) {
      if (part is List && part.isNotEmpty && part.first is String) {
        result.write(part.first);
      }
    }
    final translated = result.toString().trim();
    if (translated.isEmpty) throw const FormatException('Empty translation');
    return translated;
  }

  Future<String> toChinese(String text, CancelToken token) =>
      translate(text, token, targetLang: 'zh-CN');

  void close() => _client.close(force: true);
}
