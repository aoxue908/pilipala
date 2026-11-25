import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';

/// Google ML Kit 移动端离线神经机器翻译桥接器
/// 借鉴自 D:\app\realtime-asr 高性能实现：
/// - 纯设备端 TFLite 神经网络推理 (15~40ms 极低延迟，完全断网可用)
/// - 128 槽内存 LRU 高速缓存 (重复句库 0ms 秒命中)
/// - 动态语言代码智能归一化与字符级自动语种探测
class MlKitTranslationBridge {
  static final shared = MlKitTranslationBridge._();
  MlKitTranslationBridge._();

  static const _channel = MethodChannel('pilipala/mlkit_translate');

  // 128 槽快速 LRU 缓存，实现高频重复字幕 0ms 秒级上屏
  static const int _maxCacheSize = 128;
  final LinkedHashMap<String, String> _lruCache = LinkedHashMap<String, String>();

  /// 是否运行在支持 ML Kit 的平台 (Android 原生)
  bool get isPlatformSupported => Platform.isAndroid;

  /// 检查原生端 ML Kit 是否已就绪可用
  Future<bool> isSupported() async {
    if (!isPlatformSupported) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isSupported');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 获取当前设备上已下载就绪的离线语言包列表 (例如: ['zh', 'ja', 'en'])
  Future<List<String>> getDownloadedModels() async {
    if (!isPlatformSupported) return [];
    try {
      final res = await _channel.invokeListMethod<String>('getDownloadedModels');
      return res ?? [];
    } catch (_) {
      return [];
    }
  }

  /// 检查特定语言的离线模型是否已经下载
  Future<bool> isModelDownloaded(String lang) async {
    if (!isPlatformSupported) return false;
    final normalized = normalizeLanguageCode(lang);
    if (normalized == 'en') return true; // 英语中枢模型由系统底层就绪
    try {
      final res = await _channel.invokeMethod<bool>('isModelDownloaded', {'lang': normalized});
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 下载指定语言的离线模型包 (~30MB)
  Future<bool> downloadModel(String lang, {bool wifiOnly = false}) async {
    if (!isPlatformSupported) return false;
    final normalized = normalizeLanguageCode(lang);
    final res = await _channel.invokeMethod<bool>('downloadModel', {
      'lang': normalized,
      'wifiOnly': wifiOnly,
    });
    return res ?? false;
  }

  /// 删除指定语言的离线模型以释放存储空间
  Future<bool> deleteModel(String lang) async {
    if (!isPlatformSupported) return false;
    final normalized = normalizeLanguageCode(lang);
    _clearCacheForLang(normalized);
    final res = await _channel.invokeMethod<bool>('deleteModel', {'lang': normalized});
    return res ?? false;
  }

  /// 执行本地离线神经机器翻译 (纯设备端推理，无需网络)
  Future<String?> translate(
    String text, {
    String sourceLang = 'auto',
    String targetLang = 'zh-CN',
    bool downloadIfNeeded = false,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return text;
    if (!isPlatformSupported) return null;

    final src = resolveSourceLanguage(trimmed, sourceLang, targetLang);
    final tgt = normalizeLanguageCode(targetLang);

    if (src == tgt) return trimmed;

    final cacheKey = '$src->$tgt:$trimmed';
    final cached = _lruCache[cacheKey];
    if (cached != null) {
      // 命中 LRU 缓存，更新访问顺序并 0ms 直接返回
      _lruCache.remove(cacheKey);
      _lruCache[cacheKey] = cached;
      return cached;
    }

    final result = await _channel.invokeMethod<String>('translate', {
      'text': trimmed,
      'source': src,
      'target': tgt,
      'downloadIfNeeded': downloadIfNeeded,
    });

    if (result != null && result.isNotEmpty) {
      // 写入 LRU 缓存
      if (_lruCache.length >= _maxCacheSize) {
        _lruCache.remove(_lruCache.keys.first);
      }
      _lruCache[cacheKey] = result;
      return result;
    }

    return null;
  }

  void _clearCacheForLang(String lang) {
    _lruCache.removeWhere((key, _) =>
        key.startsWith('$lang->') || key.contains('->$lang:'));
  }

  void clearCache() {
    _lruCache.clear();
  }

  /// 归一化语言代码为 ML Kit 标准代码 (例如: zh-CN/zh-TW -> zh, ja-JP -> ja)
  static String normalizeLanguageCode(String raw) {
    final lower = raw.trim().toLowerCase().replaceAll('_', '-');
    if (lower.startsWith('zh') || lower.startsWith('cmn') || lower.startsWith('yue')) {
      return 'zh';
    }
    final base = lower.split('-').first;
    switch (base) {
      case 'fil':
        return 'tl';
      case 'iw':
        return 'he';
      case 'nb':
        return 'no';
      default:
        return base;
    }
  }

  /// 智能解析源语言代码，若为 'auto' 则进行字符集探测
  static String resolveSourceLanguage(
    String text,
    String? preferredSource,
    String targetLang,
  ) {
    if (preferredSource != null &&
        preferredSource.isNotEmpty &&
        preferredSource != 'auto') {
      return normalizeLanguageCode(preferredSource);
    }
    // 字符级语种精准探测
    if (RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(text)) return 'ja';
    if (RegExp(r'[\uAC00-\uD7AF]').hasMatch(text)) return 'ko';
    if (RegExp(r'[\u0400-\u04FF]').hasMatch(text)) return 'ru';
    if (RegExp(r'[\u0E00-\u0E7F]').hasMatch(text)) return 'th';
    if (RegExp(r'[\u0600-\u06FF]').hasMatch(text)) return 'ar';
    if (RegExp(r'[\u4E00-\u9FA5]').hasMatch(text)) {
      final tgt = normalizeLanguageCode(targetLang);
      if (tgt != 'zh') return 'zh';
    }
    return 'en';
  }
}
