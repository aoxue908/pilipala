import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class LocalAsrModelConfig {
  final String id;
  final String name;
  final String engineTag;
  final String languagesDesc;
  final String sizeDesc;
  final String dirName;
  final List<String> requiredFiles;
  final Map<String, int> minFileSizes;
  final List<String> mirrorBaseUrls;

  const LocalAsrModelConfig({
    required this.id,
    required this.name,
    required this.engineTag,
    required this.languagesDesc,
    required this.sizeDesc,
    required this.dirName,
    required this.requiredFiles,
    required this.minFileSizes,
    required this.mirrorBaseUrls,
  });
}

/// Sherpa-ONNX 本地离线识别模型管理
class LocalAsrModelManager {
  static final shared = LocalAsrModelManager._();
  LocalAsrModelManager._();

  /// 当前 Flutter 运行环境是否具备 Sherpa-ONNX 原生动态链接库
  static bool get isSupported {
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux;
  }

  static bool _initialized = false;
  static void ensureInitialized() {
    if (_initialized) return;
    try {
      sherpa.initBindings();
      _initialized = true;
    } catch (_) {}
  }

  static const Map<String, LocalAsrModelConfig> availableModels = {
    'sense_voice': LocalAsrModelConfig(
      id: 'sense_voice',
      name: 'SenseVoice 5语全能 [推荐]',
      engineTag: 'FunASR',
      languagesDesc: '支持中文、粤语、日语、韩语、英语',
      sizeDesc: '约 239MB',
      dirName: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
      requiredFiles: ['tokens.txt', 'model.int8.onnx'],
      minFileSizes: {
        'tokens.txt': 10 * 1024,
        'model.int8.onnx': 50 * 1024 * 1024,
      },
      mirrorBaseUrls: [
        'https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main',
        'https://www.modelscope.cn/models/fengge2024/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/master',
        'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main',
      ],
    ),
    'whisper_tiny': LocalAsrModelConfig(
      id: 'whisper_tiny',
      name: 'Whisper Tiny (极速·轻量)',
      engineTag: 'OpenAI',
      languagesDesc: '支持英语、中文、日语等99+语言，体积小速度快',
      sizeDesc: '约 103MB',
      dirName: 'sherpa-onnx-whisper-tiny',
      requiredFiles: [
        'tiny-tokens.txt',
        'tiny-encoder.int8.onnx',
        'tiny-decoder.int8.onnx',
      ],
      minFileSizes: {
        'tiny-tokens.txt': 100 * 1024,
        'tiny-encoder.int8.onnx': 5 * 1024 * 1024,
        'tiny-decoder.int8.onnx': 30 * 1024 * 1024,
      },
      mirrorBaseUrls: [
        'https://hf-mirror.com/csukuangfj/sherpa-onnx-whisper-tiny/resolve/main',
        'https://www.modelscope.cn/models/pengzhendong/sherpa-onnx-whisper-tiny/resolve/master',
        'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/resolve/main',
      ],
    ),
    'whisper_base': LocalAsrModelConfig(
      id: 'whisper_base',
      name: 'Whisper Base (平衡·推荐)',
      engineTag: 'OpenAI',
      languagesDesc: '支持英语、中文、日语等99+语言，平衡识别率与速度',
      sizeDesc: '约 180MB',
      dirName: 'sherpa-onnx-whisper-base',
      requiredFiles: [
        'base-tokens.txt',
        'base-encoder.int8.onnx',
        'base-decoder.int8.onnx',
      ],
      minFileSizes: {
        'base-tokens.txt': 100 * 1024,
        'base-encoder.int8.onnx': 10 * 1024 * 1024,
        'base-decoder.int8.onnx': 50 * 1024 * 1024,
      },
      mirrorBaseUrls: [
        'https://hf-mirror.com/csukuangfj/sherpa-onnx-whisper-base/resolve/main',
        'https://www.modelscope.cn/models/pengzhendong/sherpa-onnx-whisper-base/resolve/master',
        'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/main',
      ],
    ),
    'whisper_small': LocalAsrModelConfig(
      id: 'whisper_small',
      name: 'Whisper Small (高精度)',
      engineTag: 'OpenAI',
      languagesDesc: '支持英语、中文、日语等99+语言，高识别精度',
      sizeDesc: '约 460MB',
      dirName: 'sherpa-onnx-whisper-small',
      requiredFiles: [
        'small-tokens.txt',
        'small-encoder.int8.onnx',
        'small-decoder.int8.onnx',
      ],
      minFileSizes: {
        'small-tokens.txt': 100 * 1024,
        'small-encoder.int8.onnx': 30 * 1024 * 1024,
        'small-decoder.int8.onnx': 150 * 1024 * 1024,
      },
      mirrorBaseUrls: [
        'https://hf-mirror.com/csukuangfj/sherpa-onnx-whisper-small/resolve/main',
        'https://www.modelscope.cn/models/pengzhendong/sherpa-onnx-whisper-small/resolve/master',
        'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main',
      ],
    ),
    'zipformer_zh_en': LocalAsrModelConfig(
      id: 'zipformer_zh_en',
      name: 'Zipformer 中英双语',
      engineTag: 'Kaldi',
      languagesDesc: '新一代 Kaldi 中英流式识别，超低延迟',
      sizeDesc: '约 150MB',
      dirName: 'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20',
      requiredFiles: [
        'tokens.txt',
        'encoder-epoch-99-avg-1.int8.onnx',
        'decoder-epoch-99-avg-1.onnx',
        'joiner-epoch-99-avg-1.int8.onnx',
      ],
      minFileSizes: {
        'tokens.txt': 1024,
        'encoder-epoch-99-avg-1.int8.onnx': 20 * 1024 * 1024,
        'decoder-epoch-99-avg-1.onnx': 100 * 1024,
        'joiner-epoch-99-avg-1.int8.onnx': 100 * 1024,
      },
      mirrorBaseUrls: [
        'https://hf-mirror.com/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main',
        'https://www.modelscope.cn/models/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/master',
        'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main',
      ],
    ),
    'zipformer_en': LocalAsrModelConfig(
      id: 'zipformer_en',
      name: 'Zipformer 英语高精度',
      engineTag: 'Kaldi',
      languagesDesc: '新一代 Kaldi 纯英语流式识别，影视与外语学习专用',
      sizeDesc: '约 140MB',
      dirName: 'sherpa-onnx-streaming-zipformer-en-2023-06-26',
      requiredFiles: [
        'tokens.txt',
        'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
        'decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
        'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
      ],
      minFileSizes: {
        'tokens.txt': 1024,
        'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx': 20 * 1024 * 1024,
        'decoder-epoch-99-avg-1-chunk-16-left-128.onnx': 100 * 1024,
        'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx': 100 * 1024,
      },
      mirrorBaseUrls: [
        'https://hf-mirror.com/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main',
        'https://www.modelscope.cn/models/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/master',
        'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/main',
      ],
    ),
  };

  final RxString currentModelId = 'sense_voice'.obs;
  LocalAsrModelConfig get currentModel =>
      availableModels[currentModelId.value] ?? availableModels['sense_voice']!;

  final RxDouble downloadProgress = 0.0.obs;
  final RxString downloadStatus = ''.obs;
  final RxBool isDownloading = false.obs;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 45),
    followRedirects: true,
    maxRedirects: 10,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    },
  ));

  CancelToken? _cancelToken;

  /// 模型存放根目录
  Future<String> getModelDir([String? modelId]) async {
    final cfg = availableModels[modelId ?? currentModelId.value] ?? currentModel;
    final docDir = await getApplicationSupportDirectory();
    final dir = Directory('${docDir.path}/sherpa_models/${cfg.dirName}');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// 检查本地离线模型文件是否完备
  Future<bool> isModelReady([String? modelId]) async {
    try {
      final cfg = availableModels[modelId ?? currentModelId.value] ?? currentModel;
      final dir = await getModelDir(cfg.id);
      for (final filename in cfg.requiredFiles) {
        final file = File('$dir/$filename');
        final minSize = cfg.minFileSizes[filename] ?? 1024;
        if (!file.existsSync() || file.lengthSync() < minSize) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 下载离线模型（多镜像回退与临时文件原子替换）
  Future<void> downloadModel({
    String? modelId,
    void Function(double progress, String status)? onProgress,
  }) async {
    if (isDownloading.value) return;
    isDownloading.value = true;
    downloadProgress.value = 0.0;
    _cancelToken = CancelToken();

    final cfg = availableModels[modelId ?? currentModelId.value] ?? currentModel;

    try {
      final dir = await getModelDir(cfg.id);

      for (int i = 0; i < cfg.requiredFiles.length; i++) {
        final filename = cfg.requiredFiles[i];
        final savePath = '$dir/$filename';
        final file = File(savePath);
        final minSize = cfg.minFileSizes[filename] ?? 1024;

        // 如果文件已存在且大小达标，跳过
        if (file.existsSync() && file.lengthSync() >= minSize) {
          final p = (i + 1) / cfg.requiredFiles.length;
          downloadProgress.value = p;
          downloadStatus.value = '文件已就绪: $filename';
          onProgress?.call(p, downloadStatus.value);
          continue;
        }

        final tmpPath = '$savePath.tmp';
        final tmpFile = File(tmpPath);
        if (tmpFile.existsSync()) {
          try {
            tmpFile.deleteSync();
          } catch (_) {}
        }

        bool downloaded = false;
        String lastError = '';

        for (final baseUrl in cfg.mirrorBaseUrls) {
          if (_cancelToken?.isCancelled ?? false) break;

          final url = '$baseUrl/$filename';
          final mirrorName = baseUrl.contains('modelscope')
              ? 'ModelScope 镜像'
              : (baseUrl.contains('hf-mirror') ? 'HF 镜像' : 'HuggingFace 官方');

          downloadStatus.value =
              '正在从 $mirrorName 下载 $filename (${i + 1}/${cfg.requiredFiles.length})...';
          onProgress?.call(i / cfg.requiredFiles.length, downloadStatus.value);

          try {
            await _dio.download(
              url,
              tmpPath,
              cancelToken: _cancelToken,
              onReceiveProgress: (received, total) {
                if (total > 0) {
                  final fileRatio = received / total;
                  final totalRatio = (i + fileRatio) / cfg.requiredFiles.length;
                  downloadProgress.value = totalRatio;
                  final rMb = (received / 1024 / 1024).toStringAsFixed(1);
                  final tMb = (total / 1024 / 1024).toStringAsFixed(1);
                  final percent = (fileRatio * 100).toStringAsFixed(1);
                  downloadStatus.value =
                      '正在下载 $filename ($percent% - $rMb MB / $tMb MB)';
                  onProgress?.call(totalRatio, downloadStatus.value);
                }
              },
            );

            // 校验下载文件大小
            if (tmpFile.existsSync() && tmpFile.lengthSync() >= minSize) {
              if (file.existsSync()) file.deleteSync();
              tmpFile.renameSync(savePath);
              downloaded = true;
              break;
            } else {
              final actualBytes = tmpFile.existsSync() ? tmpFile.lengthSync() : 0;
              lastError = '下载文件损坏或大小异常 (期望 >= $minSize 字节, 实际 $actualBytes 字节)';
              if (tmpFile.existsSync()) tmpFile.deleteSync();
            }
          } catch (e) {
            if (_cancelToken?.isCancelled ?? false) rethrow;
            lastError = '$e';
            if (tmpFile.existsSync()) {
              try {
                tmpFile.deleteSync();
              } catch (_) {}
            }
          }
        }

        if (!downloaded) {
          throw Exception('下载 $filename 失败: $lastError');
        }
      }

      downloadProgress.value = 1.0;
      downloadStatus.value = '${cfg.name} 离线模型下载完成';
      onProgress?.call(1.0, downloadStatus.value);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        downloadStatus.value = '下载已取消';
      } else {
        downloadStatus.value = '下载失败: ${e.message}';
        rethrow;
      }
    } catch (e) {
      downloadStatus.value = '下载失败: $e';
      rethrow;
    } finally {
      isDownloading.value = false;
      _cancelToken = null;
    }
  }

  /// 取消当前下载
  void cancelDownload() {
    _cancelToken?.cancel('用户取消下载');
  }

  /// 删除本地模型
  Future<void> deleteModel([String? modelId]) async {
    final cfg = availableModels[modelId ?? currentModelId.value] ?? currentModel;
    try {
      final dir = await getModelDir(cfg.id);
      final d = Directory(dir);
      if (d.existsSync()) {
        await d.delete(recursive: true);
      }
      downloadProgress.value = 0.0;
      downloadStatus.value = '模型已清理';
    } catch (e) {
      downloadStatus.value = '删除模型失败: $e';
    }
  }
}
