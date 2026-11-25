import 'dart:convert';
import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  final text = '啊，本当かい，待たせてすまないね。';
  final urlZh = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&dt=rm&q=${Uri.encodeComponent(text)}';
  try {
    final res = await dio.get<String>(urlZh);
    print('sl=zh-CN Response: ${res.data}');
  } catch (e) {
    print('zh Error: $e');
  }
}
