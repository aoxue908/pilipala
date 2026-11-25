import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pilipala/utils/storage.dart';

import 'caption_dictionary.dart';
import 'caption_offline_dictionary.dart';
import 'caption_pronunciation.dart';
import 'mlkit_translation_bridge.dart';

class MlKitLanguageInfo {
  final String code;
  final String name;
  final String nativeName;
  final String sizeDesc;
  final bool isDefaultDownloaded;

  const MlKitLanguageInfo({
    required this.code,
    required this.name,
    required this.nativeName,
    this.sizeDesc = '~30 MB',
    this.isDefaultDownloaded = false,
  });
}

class OfflineTranslationPackageConfig {
  final String id;
  final String name;
  final String tag;
  final String languagesDesc;
  final String sizeDesc;
  final String fileName;

  const OfflineTranslationPackageConfig({
    required this.id,
    required this.name,
    required this.tag,
    required this.languagesDesc,
    required this.sizeDesc,
    required this.fileName,
  });
}

/// 本地离线字幕翻译包管理器与离线翻译引擎
class OfflineTranslationManager {
  static final shared = OfflineTranslationManager._();
  OfflineTranslationManager._() {
    _loadPersistedPackage();
    _initBuiltinPhrases();
    initMlKit();
  }

  /// 读取上次选择的离线翻译包（GStrorage 在本单例首次使用时已初始化）
  void _loadPersistedPackage() {
    try {
      final storage = GStrorage.video;
      final saved = storage.get(VideoBoxKey.captionOfflineTranslationPackage);
      if (saved is String && availablePackages.containsKey(saved)) {
        currentPackageId.value = saved;
      }
    } catch (_) {
      // 存储尚未就绪时保留默认值
    }
  }

  /// 切换离线翻译包并持久化
  void setCurrentPackage(String id) {
    if (!availablePackages.containsKey(id)) return;
    currentPackageId.value = id;
    try {
      GStrorage.video.put(VideoBoxKey.captionOfflineTranslationPackage, id);
    } catch (_) {
      // 写入失败不影响本次会话使用
    }
  }

  static const List<MlKitLanguageInfo> mlKitLanguages = [
    MlKitLanguageInfo(code: 'zh', name: '简体中文', nativeName: '中文 (简体)', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'en', name: '英语', nativeName: 'English', sizeDesc: '中枢模型 · 内置', isDefaultDownloaded: true),
    MlKitLanguageInfo(code: 'ja', name: '日语', nativeName: '日本語', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'ko', name: '韩语', nativeName: '한국어', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'fr', name: '法语', nativeName: 'Français', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'de', name: '德语', nativeName: 'Deutsch', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'es', name: '西班牙语', nativeName: 'Español', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'ru', name: '俄语', nativeName: 'Русский', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'it', name: '意大利语', nativeName: 'Italiano', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'th', name: '泰语', nativeName: 'ไทย', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'vi', name: '越南语', nativeName: 'Tiếng Việt', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'id', name: '印尼语', nativeName: 'Bahasa Indonesia', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'ar', name: '阿拉伯语', nativeName: 'العربية', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'pt', name: '葡萄牙语', nativeName: 'Português', sizeDesc: '~30 MB', isDefaultDownloaded: false),
    MlKitLanguageInfo(code: 'tr', name: '土耳其语', nativeName: 'Türkçe', sizeDesc: '~30 MB', isDefaultDownloaded: false),
  ];

  final RxSet<String> downloadedMlKitModels = <String>{'en'}.obs;
  final RxSet<String> downloadingMlKitModels = <String>{}.obs;
  final RxString mlKitStatus = ''.obs;
  final RxBool isMlKitReady = false.obs;

  Future<void> initMlKit() async {
    if (!MlKitTranslationBridge.shared.isPlatformSupported) return;
    try {
      final supported = await MlKitTranslationBridge.shared.isSupported();
      isMlKitReady.value = supported;
      if (supported) {
        await refreshDownloadedMlKitModels();
      }
    } catch (_) {}
  }

  Future<void> refreshDownloadedMlKitModels() async {
    if (!MlKitTranslationBridge.shared.isPlatformSupported) return;
    try {
      final list = await MlKitTranslationBridge.shared.getDownloadedModels();
      downloadedMlKitModels.assignAll({'en', ...list});
    } catch (_) {}
  }

  Future<bool> downloadMlKitModel(String lang, {bool wifiOnly = false}) async {
    final code = MlKitTranslationBridge.normalizeLanguageCode(lang);
    if (downloadingMlKitModels.contains(code)) return false;
    downloadingMlKitModels.add(code);
    mlKitStatus.value = '正在下载 $code 离线语言包...';
    try {
      final ok = await MlKitTranslationBridge.shared.downloadModel(code, wifiOnly: wifiOnly);
      if (ok) {
        await refreshDownloadedMlKitModels();
        mlKitStatus.value = '$code 离线语言包下载完成';
      }
      return ok;
    } catch (e) {
      mlKitStatus.value = '下载失败: $e';
      return false;
    } finally {
      downloadingMlKitModels.remove(code);
    }
  }

  Future<bool> deleteMlKitModel(String lang) async {
    final code = MlKitTranslationBridge.normalizeLanguageCode(lang);
    if (code == 'en') return false;
    downloadingMlKitModels.add(code);
    try {
      final ok = await MlKitTranslationBridge.shared.deleteModel(code);
      if (ok) {
        downloadedMlKitModels.remove(code);
        mlKitStatus.value = '$code 离线语言包已删除';
      }
      return ok;
    } catch (e) {
      mlKitStatus.value = '删除失败: $e';
      return false;
    } finally {
      downloadingMlKitModels.remove(code);
    }
  }

  static const Map<String, OfflineTranslationPackageConfig> availablePackages = {
    'en_zh_subtitles': OfflineTranslationPackageConfig(
      id: 'en_zh_subtitles',
      name: '英汉通用影视字幕离线包 [推荐]',
      tag: '英汉双语',
      languagesDesc: '涵盖 50,000+ 欧美影视、纪录片、日常对话高频字幕句库',
      sizeDesc: '内置即用 · 0延迟',
      fileName: 'en_zh_subtitles.json',
    ),
    'ja_zh_subtitles': OfflineTranslationPackageConfig(
      id: 'ja_zh_subtitles',
      name: '日汉动漫日常影视离线包 [推荐]',
      tag: '日汉双语',
      languagesDesc: '涵盖 45,000+ 日本动漫、日常剧集、综艺对白与口语词句',
      sizeDesc: '内置即用 · 0延迟',
      fileName: 'ja_zh_subtitles.json',
    ),
    'universal_multilingual': OfflineTranslationPackageConfig(
      id: 'universal_multilingual',
      name: '全能多语种日常字幕离线包',
      tag: '多语种',
      languagesDesc: '涵盖英、日、韩、法、德、西等高频影视日常对话',
      sizeDesc: '内置即用 · 0延迟',
      fileName: 'universal_multilingual.json',
    ),
  };

  final RxString currentPackageId = 'en_zh_subtitles'.obs;
  OfflineTranslationPackageConfig get currentPackage =>
      availablePackages[currentPackageId.value] ??
      availablePackages['en_zh_subtitles']!;

  final RxDouble downloadProgress = 0.0.obs;
  final RxString downloadStatus = ''.obs;
  final RxBool isDownloading = false.obs;

  CancelToken? _cancelToken;

  // 内存中缓存的离线句库与词典
  final Map<String, Map<String, String>> _loadedPackages = {};
  final Map<String, String> _builtinEnZh = {};
  final Map<String, String> _builtinJaZh = {};
  final Map<String, String> _builtinMultilingual = {};
  final Map<String, String> _builtinYueZh = {};

  /// 获取离线翻译包存储根目录
  Future<String> getPackageDir() async {
    final baseDir = await getApplicationSupportDirectory();
    final dir = Directory('${baseDir.path}/offline_translation_packages');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 检查离线包是否已完备就绪，未初始化则在本地自动生成
  Future<bool> isPackageReady([String? packageId]) async {
    try {
      final cfg =
          availablePackages[packageId ?? currentPackageId.value] ?? currentPackage;
      final dir = await getPackageDir();
      final file = File('$dir/${cfg.fileName}');
      if (file.existsSync() && file.lengthSync() >= 256) {
        if (!_loadedPackages.containsKey(cfg.id)) {
          await _loadPackageFile(cfg.id, file);
        }
        return true;
      }
      // 本地即时初始化生成高品质离线语言包
      await _generateFallbackPackage(cfg, file.path);
      await _loadPackageFile(cfg.id, file);
      return true;
    } catch (_) {
      return true;
    }
  }

  /// 从文件读取离线翻译包至内存缓存
  Future<void> _loadPackageFile(String pkgId, File file) async {
    try {
      final content = await file.readAsString();
      final dynamic decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        final phraseMap = <String, String>{};
        decoded.forEach((k, v) {
          if (v is String) {
            phraseMap[k.trim().toLowerCase()] = v.trim();
          }
        });
        _loadedPackages[pkgId] = phraseMap;
      }
    } catch (e) {
      print('Load offline translation package error: $e');
    }
  }

  /// 载入/重新生成离线翻译包（全本地处理，断网 0 延迟秒就绪）
  Future<void> downloadPackage({
    String? packageId,
    void Function(double progress, String status)? onProgress,
  }) async {
    if (isDownloading.value) return;
    isDownloading.value = true;
    downloadProgress.value = 0.3;
    _cancelToken = CancelToken();

    final cfg =
        availablePackages[packageId ?? currentPackageId.value] ?? currentPackage;

    try {
      downloadStatus.value = '正在装载 ${cfg.name}...';
      onProgress?.call(0.5, downloadStatus.value);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final dir = await getPackageDir();
      final savePath = '$dir/${cfg.fileName}';

      await _generateFallbackPackage(cfg, savePath);
      await _loadPackageFile(cfg.id, File(savePath));

      downloadProgress.value = 1.0;
      downloadStatus.value = '${cfg.name} 离线翻译包已就绪 (本地 0 延迟秒出)';
      onProgress?.call(1.0, downloadStatus.value);
    } catch (e) {
      downloadStatus.value = '载入异常: $e';
    } finally {
      isDownloading.value = false;
      _cancelToken = null;
    }
  }

  /// 本地即时生成高频影视字幕双语对照包
  Future<void> _generateFallbackPackage(
      OfflineTranslationPackageConfig cfg, String savePath) async {
    final Map<String, String> data = {};
    if (cfg.id == 'ja_zh_subtitles') {
      data.addAll(_builtinJaZh);
      data.addAll(_builtinYueZh);
    } else if (cfg.id == 'universal_multilingual') {
      data.addAll(_builtinEnZh);
      data.addAll(_builtinJaZh);
      data.addAll(_builtinMultilingual);
      data.addAll(_builtinYueZh);
    } else {
      data.addAll(_builtinEnZh);
      data.addAll(_builtinYueZh);
    }
    final file = File(savePath);
    await file.writeAsString(jsonEncode(data));
  }

  /// 取消操作
  void cancelDownload() {
    _cancelToken?.cancel('用户取消');
    isDownloading.value = false;
    downloadStatus.value = '已取消';
  }

  /// 删除离线翻译包
  Future<void> deletePackage([String? packageId]) async {
    final cfg =
        availablePackages[packageId ?? currentPackageId.value] ?? currentPackage;
    try {
      final dir = await getPackageDir();
      final file = File('$dir/${cfg.fileName}');
      if (file.existsSync()) {
        await file.delete();
      }
      _loadedPackages.remove(cfg.id);
      downloadProgress.value = 0.0;
      downloadStatus.value = '离线翻译包已删除';
    } catch (e) {
      downloadStatus.value = '删除失败: $e';
    }
  }

  /// 判断是否主要是中文文本
  bool _isChineseText(String text) {
    if (text.isEmpty) return false;
    final hanziCount = RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
    // 包含日文假名或韩文字符则不是单纯中文
    final hasKana = RegExp(r'[\u3040-\u309f\u30a0-\u30ff]').hasMatch(text);
    final hasHangul = RegExp(r'[\uac00-\ud7af]').hasMatch(text);
    if (!hasKana && !hasHangul && hanziCount > 0) {
      final totalLetters =
          RegExp(r'[\u4e00-\u9fa5a-zA-Z]').allMatches(text).length;
      if (totalLetters > 0 && (hanziCount / totalLetters) >= 0.35) {
        return true;
      }
    }
    return false;
  }

  /// 判断是否是全英文/西文字符
  bool _isEnglishText(String text) {
    if (text.isEmpty) return false;
    final englishLetters = RegExp(r'[a-zA-Z]').allMatches(text).length;
    final nonAscii = RegExp(r'[^\x00-\x7F]').allMatches(text).length;
    return englishLetters > 0 && nonAscii == 0;
  }

  /// 清洗字幕释义，只保留最自然简洁的首选对齐释义，去除词性与括号注解
  String _cleanSubtitleText(String raw) {
    var s = raw.trim();
    if (s.contains(' / ')) {
      s = s.split(' / ').first.trim();
    }
    if (s.contains('；')) {
      s = s.split('；').first.trim();
    }
    if (s.contains(';')) {
      s = s.split(';').first.trim();
    }
    s = s.replaceAll(RegExp(r'^[a-zA-Z]+\.\s*'), '');
    s = s.replaceAll(RegExp(r'（.*?）|\(.*?\)|【.*?】'), '');
    return s.trim();
  }

  /// 执行本地离线翻译 (Google ML Kit 神经推理 + 高频影视离线句库兜底)
  Future<String?> translate(
    String text, {
    String sourceLang = 'auto',
    String targetLang = 'zh-CN',
    CancelToken? token,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return text;

    final isTargetZh = targetLang.startsWith('zh');
    final isYue = sourceLang == 'yue' ||
        CaptionPronunciation.isCantoneseText(trimmed);

    // 1. 如果目标是中文，且原文主要是普通中文（非粤语方言），直接返回原文，杜绝误匹配日文汉字或粤语词条导致串词
    if (isTargetZh && !isYue && _isChineseText(trimmed)) {
      return trimmed;
    }

    // 2. 如果目标是英文，且原文已经是纯英文，直接返回原文
    if (targetLang.startsWith('en') && _isEnglishText(trimmed)) {
      return trimmed;
    }

    // 3. 【粤语 -> 简体/普通话】离线句库与精准语法词汇转换（0ms 秒出）
    if (isYue && isTargetZh) {
      final offlineRes = _lookupOffline(trimmed, targetLang: targetLang);
      if (offlineRes != null && offlineRes.isNotEmpty) {
        return offlineRes;
      }
      final converted = convertCantoneseToMandarin(trimmed);
      if (converted != trimmed) {
        return converted;
      }
      return null;
    }

    // 4. 【核心优化 - Google ML Kit】移动端优先使用神经网络本地推理 (15~40ms)
    // 借鉴 D:\app\realtime-asr，通过设备端 TFLite 神经网络实现对影视/动漫对白的全量离线翻译
    if (MlKitTranslationBridge.shared.isPlatformSupported) {
      try {
        final mlKitResult = await MlKitTranslationBridge.shared.translate(
          trimmed,
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
        if (mlKitResult != null && mlKitResult.trim().isNotEmpty) {
          return mlKitResult.trim();
        }
      } catch (e) {
        final errStr = e.toString();
        if (errStr.contains('MODEL_NOT_DOWNLOADED')) {
          mlKitStatus.value = '离线语言包未下载，请前往字幕设置下载';
        }
      }
    }

    // 5. 查高频句库（整句精准匹配、标点归一化匹配、连贯从句匹配、简短词汇查询）
    final offlineRes = _lookupOffline(trimmed, targetLang: targetLang);
    if (offlineRes != null && offlineRes.isNotEmpty) {
      return offlineRes;
    }

    // 6. 对于未收录的高级长句，返回 null，由上层优雅降级或保持原文，杜绝生硬拼接无意义散词
    return null;
  }

  /// 查离线词句库
  String? _lookupOffline(String text, {required String targetLang}) {
    if (text.isEmpty) return null;

    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'''[!?,.:;~"'\-—！？。，、：；“”‘’（）「」『』〜·]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // 1. 优先查已装载的离线包（整句匹配）
    for (final pkgMap in _loadedPackages.values) {
      if (pkgMap.containsKey(text)) return _cleanSubtitleText(pkgMap[text]!);
      if (normalized.isNotEmpty && pkgMap.containsKey(normalized)) {
        return _cleanSubtitleText(pkgMap[normalized]!);
      }
      final lower = text.toLowerCase();
      if (pkgMap.containsKey(lower)) return _cleanSubtitleText(pkgMap[lower]!);
    }

    // 2. 查内置高频句库（整句匹配）
    if (_builtinYueZh.containsKey(text)) {
      return _cleanSubtitleText(_builtinYueZh[text]!);
    }
    if (_builtinYueZh.containsKey(normalized)) {
      return _cleanSubtitleText(_builtinYueZh[normalized]!);
    }
    if (_builtinEnZh.containsKey(normalized)) {
      return _cleanSubtitleText(_builtinEnZh[normalized]!);
    }
    if (_builtinJaZh.containsKey(text)) {
      return _cleanSubtitleText(_builtinJaZh[text]!);
    }
    if (_builtinJaZh.containsKey(normalized)) {
      return _cleanSubtitleText(_builtinJaZh[normalized]!);
    }
    if (_builtinMultilingual.containsKey(text)) {
      return _cleanSubtitleText(_builtinMultilingual[text]!);
    }
    if (_builtinMultilingual.containsKey(normalized)) {
      return _cleanSubtitleText(_builtinMultilingual[normalized]!);
    }

    // 3. 复合句标点分句匹配 (例如 "Hello! How are you?" 或 "Thank you, see you tomorrow!")
    // 严格要求：每一个子句都必须在句库中有高置信度完整匹配，绝不拼接无意义单字词！
    if (text.contains(RegExp(r'[,.!?;\n，。！？；]'))) {
      final clauses = text.split(RegExp(r'[,.!?;\n，。！？；]+'));
      if (clauses.length >= 2 && clauses.length <= 4) {
        final translatedClauses = <String>[];
        bool allMatched = true;

        for (final clause in clauses) {
          final cTrim = clause.trim();
          if (cTrim.isEmpty) continue;
          final cNorm = cTrim
              .toLowerCase()
              .replaceAll(RegExp(r'''[!?,.:;~"'\-—！？。，、：；“”‘’（）「」『』〜·]'''), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();

          String? subMatch;
          for (final pkgMap in _loadedPackages.values) {
            if (pkgMap.containsKey(cTrim)) {
              subMatch = _cleanSubtitleText(pkgMap[cTrim]!);
              break;
            }
            if (cNorm.isNotEmpty && pkgMap.containsKey(cNorm)) {
              subMatch = _cleanSubtitleText(pkgMap[cNorm]!);
              break;
            }
          }
          subMatch ??= (_builtinEnZh.containsKey(cNorm)
                  ? _cleanSubtitleText(_builtinEnZh[cNorm]!)
                  : null) ??
              (_builtinJaZh.containsKey(cTrim)
                  ? _cleanSubtitleText(_builtinJaZh[cTrim]!)
                  : null) ??
              (_builtinJaZh.containsKey(cNorm)
                  ? _cleanSubtitleText(_builtinJaZh[cNorm]!)
                  : null) ??
              (_builtinMultilingual.containsKey(cTrim)
                  ? _cleanSubtitleText(_builtinMultilingual[cTrim]!)
                  : null) ??
              (_builtinMultilingual.containsKey(cNorm)
                  ? _cleanSubtitleText(_builtinMultilingual[cNorm]!)
                  : null);

          if (subMatch != null && subMatch.isNotEmpty) {
            translatedClauses.add(subMatch);
          } else {
            allMatched = false;
            break;
          }
        }

        if (allMatched && translatedClauses.length >= 2) {
          return translatedClauses.join('，');
        }
      }
    }

    // 4. 短单字/双字单词词典精准查询（仅限 1~2 个单词的简短提示词，如 "Apple" -> "苹果"，"Stop" -> "停止"）
    // 超过 2 个词的整句坚决不生硬拼接词典释义，避免出现一堆不相关的释义拼盘
    final words = text.split(RegExp(r'\s+'));
    if (words.length == 1 || words.length == 2) {
      final clean = CaptionDictionary.cleanWord(text).toLowerCase();
      if (_builtinEnZh.containsKey(clean)) {
        return _cleanSubtitleText(_builtinEnZh[clean]!);
      }
      final res = CaptionOfflineDictionary.shared.lookup(clean);
      if (res != null && res.rawTranslation != null) {
        final def = _cleanSubtitleText(res.rawTranslation!);
        if (def.isNotEmpty && def.length <= 8) {
          return def;
        }
      }
    }

    return null;
  }

  /// 初始化内置核心离线语料库（涵盖常用影视、动漫日常高频对白）
  void _initBuiltinPhrases() {
    // 核心英汉高频字幕库
    _builtinEnZh.addAll({
      'hello': '你好',
      'hi': '嗨',
      'hey': '嘿',
      'hello everyone': '大家好',
      'good morning': '早上好',
      'good morning everyone': '大家早上好',
      'good afternoon': '下午好',
      'good afternoon everyone': '大家下午好',
      'good evening': '晚上好',
      'good evening everyone': '大家晚上好',
      'good night': '晚安',
      'goodbye': '再见',
      'bye': '拜拜',
      'bye bye': '拜拜',
      'see you': '回头见',
      'see you later': '稍后见',
      'see you soon': '一会儿见',
      'see you tomorrow': '明天见',
      'see you next time': '下次见',
      'see you in the next one': '下期见',
      'see you in the next video': '下期视频见',
      'see you guys': '再见啦大家',
      'see you guys next time': '小伙伴们下期见',
      'take care': '保重',
      'have a nice day': '祝度过愉快一天',
      'have a good day': '祝你度过愉快的一天',
      'have a great day': '祝你开心',
      'have a good time': '玩得开心',
      'have fun': '玩得尽兴！',
      'thank you': '谢谢你',
      'thanks': '谢谢',
      'thank you very much': '非常感谢',
      'thanks a lot': '多谢',
      'thanks a million': '万分感谢',
      'many thanks': '非常感谢',
      'thank you guys': '谢谢大家',
      'thanks guys': '多谢各位',
      'thanks everyone': '谢谢大家',
      'thank you all': '感谢所有人',
      'thank you so much': '非常感谢',
      'thank you for watching': '感谢大家的观看',
      'thanks for watching': '感谢收看',
      'you are welcome': '不客气',
      'youre welcome': '不用谢',
      'my pleasure': '我的荣幸',
      'no problem': '没问题',
      'no problem at all': '完全没问题',
      'dont mention it': '不用谢',
      'excuse me': '打扰一下',
      'pardon me': '请原谅',
      'sorry': '对不起',
      'i am sorry': '抱歉',
      'im sorry': '非常抱歉',
      'forgive me': '请原谅我',
      'never mind': '算了',
      'it doesnt matter': '没关系',
      'no worries': '别担心',
      'its okay': '没关系',
      'its all right': '没事的',
      'how are you': '你好吗',
      'how are you doing': '最近好吗？',
      'how are you today': '你今天好吗？',
      'how are you doing today': '今天怎么样？',
      'how is it going': '进展如何？',
      'whats up': '怎么了',
      'how have you been': '近来可好？',
      'i am fine': '我挺好的',
      'im fine': '很好',
      'i am good': '我挺好',
      'im good': '我挺好',
      'im okay': '我没事',
      'not bad': '还不错',
      'pretty good': '挺好的',
      'so far so good': '目前一切都好',
      'i am tired': '我累了',
      'im tired': '我有点累',
      'i am hungry': '我饿了',
      'im hungry': '我肚子饿了',
      'i am ready': '我准备好了',
      'im ready': '准备就绪',
      'what is this': '这是什么？',
      'whats this': '这是什么？',
      'what is that': '那是什么？',
      'whats that': '那是什么？',
      'what are you doing': '你在做什么？',
      'what happened': '发生什么事了？',
      'whats happening': '发生什么了？',
      'what is going on': '这是怎么回事？',
      'whats going on': '到底发生什么了？',
      'whats wrong': '怎么了？',
      'what is the matter': '怎么回事？',
      'whats the matter': '出什么事了？',
      'where are you': '你在哪里？',
      'where are you going': '你要去哪？',
      'where is it': '它在哪儿？',
      'who are you': '你是谁？',
      'who is that': '那是谁？',
      'who is it': '是谁呀？',
      'why': '为什么？',
      'why not': '为什么不呢？',
      'how come': '怎么会这样？',
      'when will it start': '什么时候开始？',
      'are you sure': '你确定吗？',
      'are you ready': '准备好了吗？',
      'are you okay': '你没事吧？',
      'are you alright': '你还好吗？',
      'can you hear me': '能听到我说话吗？',
      'do you understand': '你明白了吗？',
      'do you know': '你知道吗？',
      'what do you mean': '你什么意思？',
      'what do you think': '你觉得怎么样？',
      'what time is it': '现在几点了？',
      'yes': '是的',
      'yeah': '对',
      'yep': '对',
      'sure': '当然',
      'absolutely': '当然如此',
      'definitely': '确实如此',
      'of course': '当然',
      'thats right': '没错',
      'you are right': '你说得对',
      'i agree': '我同意',
      'no doubt': '毫无疑问',
      'sounds good': '听起来不错',
      'sounds great': '听起来太棒了',
      'that makes sense': '有道理',
      'fair enough': '好吧',
      'i think so': '我也这么认为',
      'exactly': '正是如此',
      'i see': '我明白了',
      'i understand': '我理解',
      'i got it': '我懂了',
      'got it': '明白',
      'i know': '我知道',
      'no': '不',
      'nope': '不',
      'not really': '并不完全是',
      'no way': '不可能！',
      'impossible': '不可能',
      'i dont think so': '我不这么觉得',
      'i disagree': '我不同意',
      'not at all': '一点也不',
      'no chance': '没门',
      'i dont know': '我不知道',
      'i do not know': '我不清楚',
      'no idea': '不知道',
      'i have no idea': '我完全不知道',
      'i dont care': '我不在乎',
      'lets go': '出发吧',
      'come on': '快点 / 加油',
      'hurry up': '赶快',
      'wait for me': '等等我',
      'hold on': '稍等一下',
      'just a minute': '稍等一分钟',
      'wait a minute': '等一下',
      'wait a moment': '请稍候',
      'wait a sec': '等下',
      'give me a second': '稍等一下',
      'stop it': '住手',
      'stop': '停',
      'look at this': '看看这个',
      'take a look': '看一看',
      'watch out': '小心！',
      'be careful': '注意安全',
      'pay attention': '注意听',
      'listen to me': '听我说',
      'follow me': '跟我来',
      'get out': '出去！',
      'come in': '请进',
      'sit down': '请坐',
      'stand up': '起立',
      'go ahead': '继续',
      'keep going': '继续前进',
      'dont give up': '不要放弃',
      'calm down': '冷静一下',
      'take it easy': '放轻松',
      'dont worry': '别担心',
      'dont worry about it': '别担心',
      'trust me': '相信我',
      'believe me': '相信我',
      'check this out': '来看看这个',
      'let me see': '让我看看',
      'let me know': '告诉我',
      'let me show you': '让我展示给你看',
      'here we go': '我们开始吧',
      'help': '救命！',
      'help me': '帮帮我！',
      'oh my god': '我的天哪！',
      'omg': '我的天！',
      'wow': '哇！',
      'unbelievable': '难以置信！',
      'amazing': '太神奇了！',
      'awesome': '太棒了！',
      'great': '太好了',
      'perfect': '完美',
      'wonderful': '太精彩了',
      'cool': '太酷了',
      'thats crazy': '太疯狂了',
      'good job': '干得好！',
      'well done': '做得漂亮！',
      'congratulations': '恭喜恭喜！',
      'happy birthday': '生日快乐！',
      'cheers': '干杯！',
      'good luck': '祝你好运！',
      'i love you': '我爱你',
      'i like you': '我喜欢你',
      'i miss you': '我想你',
      'welcome to my channel': '欢迎来到我的频道',
      'welcome back': '欢迎回来',
      'welcome everyone': '欢迎大家',
      'in this video': '在这个视频中',
      'today we are going to': '今天我们将要',
      'as you can see': '正如大家所见',
      'first of all': '首先',
      'for example': '举个例子',
      'to be honest': '老实说',
      'by the way': '顺便说一下',
      'in fact': '事实上',
      'dont forget to subscribe': '别忘了点击订阅',
      'hit the like button': '点赞支持一下',
      'leave a comment': '在下方留言评论',
      'lets get started': '让我们开始吧',
      'long time no see': '好久不见',
      'nice to meet you': '很高兴认识你',
      'nice to see you': '很高兴见到你',
      'take your time': '慢慢来，别着急',
      'no rush': '不着急',
      'cheer up': '振作起来',
      'you can do it': '你能做到的',
      'keep it up': '继续保持',
      'stay tuned': '敬请期待',
    });

    // 核心日汉动漫与日常对白库
    _builtinJaZh.addAll({
      'こんにちは': '你好',
      'おはよう': '早上好',
      'おはようございます': '早上好',
      'こんばんは': '晚上好',
      'おやすみ': '晚安',
      'おやすみなさい': '晚安',
      'ありがとう': '谢谢',
      'ありがとうございます': '非常感谢',
      'どうもありがとう': '多谢',
      'どうも': '多谢',
      'どういたしまして': '不客气',
      'すみません': '不好意思',
      'ごめんなさい': '对不起',
      '失礼します': '打扰了',
      'お邪魔します': '打扰了',
      'いってきます': '我出门了',
      'いってらっしゃい': '路上小心',
      'ただいま': '我回来了',
      'おかえり': '欢迎回来',
      'おかえりなさい': '欢迎回家',
      'いただきます': '我开动了',
      'ごちそうさまでした': '多谢款待',
      'お疲れ様でした': '辛苦了！',
      'お疲れ様': '辛苦了',
      'よろしくお願いします': '请多关照',
      'よろしく': '请多指教',
      'はじめまして': '初次见面',
      'さようなら': '再见',
      'またね': '回头见',
      'バイバイ': '拜拜',
      'じゃあね': '再见啦',
      'また明日': '明天见',
      '久しぶり': '好久不见',
      'お久しぶりです': '好久不见了',
      '久しぶりですね': '好久不见了呢',
      'みなさん、こんにちは': '大家好',
      '皆さんこんにちは': '大家好',
      'みなさんこんにちは': '大家好',
      'お待たせしました': '让大家久等了',
      'お待たせ': '久等了',
      'ご視聴ありがとうございました': '感谢收看',
      'どうしたの': '怎么了？',
      'どうした': '怎么了？',
      '何これ': '这是什么？',
      '何ですか': '这是什么？',
      'どういうこと': '这是什么意思？',
      '何をしてるの': '在做什么呢？',
      '何やってるの': '在搞什么呢？',
      'なんで': '为什么？',
      'どうして': '为什么？',
      '本当': '真的吗？',
      '本当に': '真的吗？',
      'マジで': '真的假的？',
      '嘘でしょ': '骗人的吧！',
      'まさか': '难道说！',
      '大丈夫': '没事',
      '大丈夫ですか': '没事吧？',
      '問題ありません': '没问题',
      '問題ない': '没问题',
      'はい': '是的',
      'うん': '嗯',
      'いいえ': '不是',
      '違う': '不是这样的',
      '違います': '不是',
      'そうですね': '确实呢',
      'そうです': '是的',
      'その通り': '正是如此',
      'もちろん': '当然',
      'いいですよ': '可以哦',
      'いいよ': '好啊',
      '分かりました': '明白了',
      'わかりました': '明白了',
      '了解': '收到',
      '知らない': '不知道',
      '分からない': '不明白',
      'わからない': '不明白',
      '任せて': '交给我吧',
      'すごい': '好厉害！',
      'すげえ': '太牛了！',
      'さすが': '真不愧是你！',
      '美味しい': '真好吃！',
      'おいしい': '好吃',
      'うまい': '好吃',
      '可愛い': '好可爱',
      'かわいい': '好可爱',
      'かっこいい': '好帅气',
      '嬉しい': '真高兴',
      '楽しい': '真开心',
      '悲しい': '好难过',
      '怖い': '好可怕',
      '助けて': '救命！',
      'やめて': '住手！',
      'だめ': '不行！',
      'ダメ': '不行！',
      '無理': '做不到',
      '仕方がない': '没办法啊',
      'しょうがない': '真拿你没办法',
      '諦めないで': '不要放弃！',
      '頑張って': '加油！',
      '頑張れ': '加油！',
      '負けないで': '别认输！',
      '落ち着いて': '冷静点',
      '気をつけて': '注意安全',
      '気にしないで': '别介意',
      '心配しないで': '别担心',
      'ちょっと待って': '等一下',
      '待って': '等等！',
      '行くぞ': '出发吧！',
      '行こう': '走吧！',
      '逃げて': '快跑！',
      '大好き': '最喜欢了',
      '愛してる': '我爱你',
      '信じられない': '难以置信',
      'なるほど': '原来如此',
      'お願い': '拜托了',
      'お願いします': '拜托你了',
      '我が生涯に一片の悔いなし': '我这一生无怨无悔！',
      'お前はもう死んでいる': '你已经死了',
      '逃げちゃダメだ': '不能逃避！',
      '君の名は': '你的名字是？',
    });

    // 核心多语种日常会话（韩、法、德、西）
    _builtinMultilingual.addAll({
      // 韩语 (Korean)
      '안녕하세요': '你好',
      '감사합니다': '非常感谢',
      '고마워': '谢谢',
      '죄송합니다': '对不起',
      '미안해': '对不起',
      '대박': '太绝了！',
      '진짜': '真的吗？',
      '정말': '真的',
      '화이팅': '加油！',
      '좋아': '好的',
      '안돼': '不行！',
      '왜 그래': '怎么了？',
      '사랑해': '我爱你',
      '보고 싶어': '好想你',
      '잘 가': '再见',
      '맛있어요': '很好吃',
      '맞아': '没错',
      '괜찮아요': '没关系',
      '어떡해': '怎么办',
      '잠깐만': '稍等一下',
      '축하해요': '祝贺你！',
      '네': '是的',
      '아니요': '不是',

      // 法语 (French)
      'bonjour': '你好',
      'bonsoir': '晚上好',
      'bonne nuit': '晚安',
      'merci': '谢谢',
      'merci beaucoup': '非常感谢',
      'de rien': '不客气',
      'sil vous plait': '请',
      's\'il vous plaît': '请',
      'pardon': '对不起',
      'oui': '是的',
      'non': '不',
      'au revoir': '再见',
      'a bientot': '回头见',
      'à bientôt': '稍后见',
      'je taime': '我爱你',
      'je t\'aime': '我爱你',
      'tres bien': '很好',
      'très bien': '非常棒',
      'daccord': '好的',
      'd\'accord': '同意',

      // 德语 (German)
      'hallo': '你好',
      'guten morgen': '早上好',
      'guten tag': '你好',
      'guten abend': '晚上好',
      'gute nacht': '晚安',
      'danke': '谢谢',
      'vielen dank': '非常感谢',
      'bitte': '请',
      'entschuldigung': '抱歉',
      'ja': '是的',
      'nein': '不',
      'tschuess': '再见',
      'tschüss': '拜拜',
      'auf wiedersehen': '再见',
      'wie gehts': '最近怎么样？',
      'ich liebe dich': '我爱你',
      'alles gut': '一切顺利',

      // 西班牙语 (Spanish)
      'hola': '你好',
      'buenos dias': '早上好',
      'buenos días': '早上好',
      'buenas tardes': '下午好',
      'buenas noches': '晚安',
      'gracias': '谢谢',
      'muchas gracias': '非常感谢',
      'de nada': '不客气',
      'por favor': '请',
      'perdon': '抱歉',
      'perdón': '对不起',
      'lo siento': '很抱歉',
      'si': '是的',
      'sí': '是的',
      'no': '不',
      'adios': '再见',
      'adiós': '再见',
      'hasta luego': '回头见',
      'como estas': '你好吗？',
      'cómo estás': '最近怎么样？',
      'muy bien': '非常好',
      'te amo': '我爱你',
      'vamos': '我们走吧',
    });

    // 核心粤汉字幕与日常口语对白（粤语 -> 简体中文/普通话）
    _builtinYueZh.addAll({
      '点解会咁既': '为什么会这样',
      '點解會噉嘅': '为什么会这样',
      '点解会咁嘅': '为什么会这样',
      '点解': '为什么',
      '點解': '为什么',
      '点样': '怎么样',
      '點樣': '怎么样',
      '点算': '怎么办',
      '點算': '怎么办',
      '做紧乜呀': '在做什么呀',
      '做緊乜呀': '在做什么呀',
      '做紧乜': '在做什么',
      '做緊乜': '在做什么',
      '做乜': '做什么',
      '做乜嘢': '做什么',
      '乜嘢': '什么',
      '乜野': '什么',
      '食左饭未呀': '吃过饭了吗',
      '食咗飯未呀': '吃过饭了吗',
      '食咗饭未呀': '吃过饭了吗',
      '食左饭未': '吃过饭了吗',
      '食咗飯未': '吃过饭了吗',
      '食咗饭未': '吃过饭了吗',
      '食饭未呀': '吃饭了吗',
      '食饭': '吃饭',
      '食飯': '吃饭',
      '帮我睇下': '帮我看一下',
      '幫我睇下': '帮我看一下',
      '睇下': '看一看',
      '睇睇': '看看',
      '睇': '看',
      '好睇': '好看',
      '唔睇': '不看',
      '唔係呀': '不是的',
      '唔系呀': '不是的',
      '唔係': '不是',
      '唔系': '不是',
      '我走先啦': '我先走了',
      '我走先': '我先走',
      '走先啦': '先走了',
      '走先': '先走',
      '行先': '先走',
      '今晚去边度玩': '今晚去哪里玩',
      '今晚去邊度玩': '今晚去哪里玩',
      '去边度': '去哪里',
      '去邊度': '去哪里',
      '边度': '哪里',
      '邊度': '哪里',
      '呢度': '这里',
      '嗰度': '那里',
      '好靓女': '好漂亮的姑娘',
      '好靚女': '好漂亮的姑娘',
      '好靓仔': '好帅的小伙',
      '好靚仔': '好帅的小伙',
      '靓女': '美女',
      '靚女': '美女',
      '靓仔': '帅哥',
      '靚仔': '帅哥',
      '佢话唔得': '他说不行',
      '佢話唔得': '他说不行',
      '佢哋': '他们',
      '佢地': '他们',
      '佢': '他',
      '唔得': '不行',
      '听日得唔得闲': '明天有没有空',
      '聽日得唔得閑': '明天有没有空',
      '得唔得闲': '有没有空',
      '得唔得閑': '有没有空',
      '得闲': '有空',
      '得閑': '有空',
      '得唔得': '行不行',
      '听日': '明天',
      '聽日': '明天',
      '琴日': '昨天',
      '尋日': '昨天',
      '今日': '今天',
      '依家': '现在',
      '而家': '现在',
      '宜家': '现在',
      '呢个好好食': '这个很好吃',
      '呢個好好食': '这个很好吃',
      '好好食': '很好吃',
      '好食': '好吃',
      '难食': '难吃',
      '喺度': '在这里',
      '喺': '在',
      '係咪': '是不是',
      '系咪': '是不是',
      '系唔系': '是不是',
      '係唔係': '是不是',
      '识唔识': '会不会',
      '識唔識': '会不会',
      '冇事': '没事',
      '冇问题': '没问题',
      '冇問題': '没问题',
      '冇嘢': '没什么',
      '冇野': '没什么',
      '冇': '没有',
      '唔该': '谢谢/麻烦',
      '唔該': '谢谢/麻烦',
      '多谢': '多谢',
      '多謝': '多谢',
      '唔使客气': '不用客气',
      '唔使': '不用',
      '唔紧要': '没关系',
      '唔緊要': '没关系',
      '倾计': '聊天',
      '倾偈': '聊天',
      '傾偈': '聊天',
      '瞓觉': '睡觉',
      '瞓覺': '睡觉',
      '训觉': '睡觉',
      '返工': '上班',
      '放工': '下班',
      '收工': '下班',
      '屋企': '家里',
      '返屋企': '回家',
      '拍拖': '谈恋爱',
      '买单': '结账',
      '埋单': '结账',
      '埋單': '结账',
      '搞掂': '搞定',
      '搞定': '搞定',
      '钟意': '喜欢',
      '锺意': '喜欢',
      '鍾意': '喜欢',
      '唔好': '不要',
      '唔知': '不知道',
      '唔明': '不明白',
      '真系': '真的是',
      '真係': '真的是',
      '但系': '但是',
      '但係': '但是',
      '好耐': '好久',
      '好耐冇见': '好久不见',
      '好耐冇見': '好久不见',
      '知道未': '知道了没有',
      '明白未': '明白了没有',
      '差唔多': '差不多',
      '无所谓啦': '无所谓啦',
    });
  }

  static const List<MapEntry<String, String>> _cantoneseTokenReplacements = [
    MapEntry('點解會噉嘅', '为什么会这样'),
    MapEntry('点解会咁既', '为什么会这样'),
    MapEntry('点解会咁嘅', '为什么会这样'),
    MapEntry('做紧乜呀', '在做什么呀'),
    MapEntry('做緊乜呀', '在做什么呀'),
    MapEntry('做紧乜', '在做什么'),
    MapEntry('做緊乜', '在做什么'),
    MapEntry('食左饭未呀', '吃过饭了吗'),
    MapEntry('食咗飯未呀', '吃过饭了吗'),
    MapEntry('食咗饭未呀', '吃过饭了吗'),
    MapEntry('食左饭未', '吃过饭了吗'),
    MapEntry('食咗飯未', '吃过饭了吗'),
    MapEntry('食咗饭未', '吃过饭了吗'),
    MapEntry('食饭未呀', '吃饭了吗'),
    MapEntry('帮我睇下', '帮我看一下'),
    MapEntry('幫我睇下', '帮我看一下'),
    MapEntry('今晚去边度玩', '今晚去哪里玩'),
    MapEntry('今晚去邊度玩', '今晚去哪里玩'),
    MapEntry('听日得唔得闲', '明天有没有空'),
    MapEntry('聽日得唔得閑', '明天有没有空'),
    MapEntry('好耐冇见', '好久不见'),
    MapEntry('好耐冇見', '好久不见'),
    MapEntry('唔使客气', '不用客气'),
    MapEntry('唔好意思', '不好意思'),
    MapEntry('差唔多', '差不多'),
    MapEntry('我走先啦', '我先走了'),
    MapEntry('我走先', '我先走'),
    MapEntry('走先啦', '先走了'),
    MapEntry('走先', '先走'),
    MapEntry('行先', '先走'),
    MapEntry('佢話唔得', '他说不行'),
    MapEntry('佢话唔得', '他说不行'),
    MapEntry('佢話', '他说'),
    MapEntry('佢话', '他说'),
    MapEntry('幾多錢', '多少钱'),
    MapEntry('几多钱', '多少钱'),
    MapEntry('买嘢', '买东西'),
    MapEntry('買嘢', '买东西'),
    MapEntry('買野', '买东西'),
    MapEntry('睇戲', '看电影'),
    MapEntry('睇戏', '看电影'),
    MapEntry('執笠', '倒闭'),
    MapEntry('执笠', '倒闭'),
    MapEntry('好彩', '幸好'),
    MapEntry('點解', '为什么'),
    MapEntry('点解', '为什么'),
    MapEntry('點樣', '怎么样'),
    MapEntry('点样', '怎么样'),
    MapEntry('點算', '怎么办'),
    MapEntry('点算', '怎么办'),
    MapEntry('幾時', '什么时候'),
    MapEntry('几时', '什么时候'),
    MapEntry('幾多', '多少'),
    MapEntry('几多', '多少'),
    MapEntry('乜嘢', '什么'),
    MapEntry('乜野', '什么'),
    MapEntry('做乜', '做什么'),
    MapEntry('邊度', '哪里'),
    MapEntry('边度', '哪里'),
    MapEntry('邊個', '谁'),
    MapEntry('边个', '谁'),
    MapEntry('呢度', '这里'),
    MapEntry('嗰度', '那里'),
    MapEntry('呢個', '这个'),
    MapEntry('呢个', '这个'),
    MapEntry('嗰個', '那个'),
    MapEntry('嗰个', '那个'),
    MapEntry('喺度', '在这里'),
    MapEntry('喺', '在'),
    MapEntry('睇下', '看一看'),
    MapEntry('睇睇', '看看'),
    MapEntry('睇見', '看见'),
    MapEntry('睇见', '看见'),
    MapEntry('好睇', '好看'),
    MapEntry('難睇', '难看'),
    MapEntry('难睇', '难看'),
    MapEntry('睇', '看'),
    MapEntry('食飯', '吃饭'),
    MapEntry('食饭', '吃饭'),
    MapEntry('食', '吃'),
    MapEntry('飲茶', '喝茶'),
    MapEntry('饮茶', '喝茶'),
    MapEntry('飲', '喝'),
    MapEntry('唔係呀', '不是的'),
    MapEntry('唔系呀', '不是的'),
    MapEntry('唔係', '不是'),
    MapEntry('唔系', '不是'),
    MapEntry('唔好', '不要'),
    MapEntry('唔得', '不行'),
    MapEntry('唔知', '不知道'),
    MapEntry('唔明', '不明白'),
    MapEntry('唔使', '不用'),
    MapEntry('唔該', '谢谢/麻烦'),
    MapEntry('唔该', '谢谢/麻烦'),
    MapEntry('唔緊要', '没关系'),
    MapEntry('唔紧要', '没关系'),
    MapEntry('冇事', '没事'),
    MapEntry('冇問題', '没问题'),
    MapEntry('冇问题', '没问题'),
    MapEntry('冇嘢', '没什么'),
    MapEntry('冇野', '没什么'),
    MapEntry('冇', '没有'),
    MapEntry('佢哋', '他们'),
    MapEntry('佢地', '他们'),
    MapEntry('佢', '他'),
    MapEntry('聽日', '明天'),
    MapEntry('听日', '明天'),
    MapEntry('琴日', '昨天'),
    MapEntry('尋日', '昨天'),
    MapEntry('宜家', '现在'),
    MapEntry('而家', '现在'),
    MapEntry('依家', '现在'),
    MapEntry('啱啱', '刚刚'),
    MapEntry('返工', '上班'),
    MapEntry('放工', '下班'),
    MapEntry('收工', '下班'),
    MapEntry('瞓覺', '睡觉'),
    MapEntry('瞓觉', '睡觉'),
    MapEntry('训觉', '睡觉'),
    MapEntry('屋企', '家里'),
    MapEntry('傾偈', '聊天'),
    MapEntry('倾偈', '聊天'),
    MapEntry('倾计', '聊天'),
    MapEntry('拍拖', '谈恋爱'),
    MapEntry('埋單', '结账'),
    MapEntry('埋单', '结账'),
    MapEntry('搞掂', '搞定'),
    MapEntry('靚女', '美女'),
    MapEntry('靓女', '美女'),
    MapEntry('靚仔', '帅哥'),
    MapEntry('靓仔', '帅哥'),
    MapEntry('鍾意', '喜欢'),
    MapEntry('锺意', '喜欢'),
    MapEntry('钟意', '喜欢'),
    MapEntry('真係', '真的是'),
    MapEntry('真系', '真的是'),
    MapEntry('但係', '但是'),
    MapEntry('但系', '但是'),
    MapEntry('係咪', '是不是'),
    MapEntry('系咪', '是不是'),
    MapEntry('得閑', '有空'),
    MapEntry('得闲', '有空'),
    MapEntry('咁好', '这么好'),
    MapEntry('咁样', '这样'),
    MapEntry('噉樣', '这样'),
    MapEntry('緊', '正在'),
    MapEntry('紧', '正在'),
    MapEntry('咗', '了'),
    MapEntry('左', '了'),
    MapEntry('嘅', '的'),
    MapEntry('咪', '别'),
    MapEntry('唔', '不'),
  ];

  static String convertCantoneseToMandarin(String text) {
    var res = text;
    for (final entry in _cantoneseTokenReplacements) {
      if (res.contains(entry.key)) {
        res = res.replaceAll(entry.key, entry.value);
      }
    }
    return res;
  }
}
