import 'dart:convert';
import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  final text = '今日天氣好好，我哋一齊去飲茶啦。';
  final urlGtx = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=yue&tl=en&dt=t&dt=rm&q=${Uri.encodeComponent(text)}';
  try {
    final res = await dio.get<String>(urlGtx);
    print('sl=yue Response: ${res.data}');
  } catch (e) {
    print('yue Error: $e');
  }
}
