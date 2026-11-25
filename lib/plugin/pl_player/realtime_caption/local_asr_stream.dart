import 'asr_repetition.dart';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_stream.dart';
import 'caption_text_formatter.dart';
import 'local_asr_model.dart';

/// Sherpa-ONNX 本地离线识别实现
/// 接口与 AsrStream 完全一致，实现 CaptionAsrStream
class LocalAsrStream implements CaptionAsrStream {
  LocalAsrStream({
    this.receiveTimeout = const Duration(seconds: 90),
  });

  final Duration receiveTimeout;

  static const _sampleRate = 16000;
  static const _bytesPerMillisecond = _sampleRate * 2 ~/ 1000;
  static const _frameBytes = _bytesPerMillisecond * 640;

  /// 离线模型（SenseVoice/Whisper）送解码的 VAD 门槛。
  /// 原为 1800ms + 400ms 静音，短句说完要再等近 2 秒才出字幕；
  /// 降到 1000ms + 280ms：明显减少延迟，同时保留足够的声学上下文。
  /// 未成句的音频由 _carryOverSamples 跨 chunk 合并，最终断句按标点，不会被切碎。
  static const int vadMinDispatchMs = 1000;
  static const int vadTrailingSilenceMs = 280;
  /// 最长累积音频，超时强制送解码（防止长句一直不 dispatch）。
  static const int vadMaxDispatchMs = 5000;

  /// 流式 Zipformer 的端点静音阈值（秒）。原 0.8/0.4/6.0 偏高，
  /// 说话停顿后要等较久才成句；适度降低以加快成句，不改动解码逻辑。
  static const double endpointTrailingSilence1 = 0.5;
  static const double endpointTrailingSilence2 = 0.3;
  static const double endpointMinUtterance = 5.0;

  /// 是否达到离线 chunk 的时长门槛（可测试）。
  static bool offlineChunkReachedMin(int samples, {int sampleRate = _sampleRate}) =>
      samples >= (vadMinDispatchMs * sampleRate) ~/ 1000;

  /// 实际保留音频的起点也必须作为下一块的时间起点。
  static int offlineCarryStart({
    required int sampleCount,
    required int splitSampleIndex,
    required bool hasIncompleteSentence,
  }) {
    final split = splitSampleIndex.clamp(0, sampleCount);
    if (!hasIncompleteSentence || split == sampleCount) return sampleCount;
    return math.max(0, split - _sampleRate * 400 ~/ 1000);
  }

  /// Sherpa 只提供 token 起点，终点最多外推 350ms，且不跨下一 token/音频结尾。
  static List<AsrWord> offlineWordTimings({
    required List<String> tokens,
    required List<double> timestamps,
    required int chunkAudioStartMs,
    required int totalDurationMs,
  }) {
    if (tokens.length != timestamps.length || tokens.isEmpty) return const [];
    final words = <Map<String, dynamic>>[];
    for (var i = 0; i < tokens.length; i++) {
      final seconds = timestamps[i];
      if (!seconds.isFinite || seconds < 0) return const [];
      final start = (seconds * 1000).round();
      var end = math.min(totalDurationMs, start + 350);
      if (i + 1 < timestamps.length) {
        final next = timestamps[i + 1];
        if (!next.isFinite || next < seconds) return const [];
        end = math.min(end, (next * 1000).round());
      }
      words.add({
        'word': tokens[i],
        'start_ms': chunkAudioStartMs + start,
        'end_ms': chunkAudioStartMs + end,
      });
    }
    return readAsrWords(words);
  }

  sherpa.OnlineRecognizer? _onlineRecognizer;
  sherpa.OnlineStream? _onlineStream;

  // 针对非流式离线模型 (如 SenseVoice, Whisper)，利用专用工作 Isolate + NPU 异步后台推理，杜绝 UI 卡顿
  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  ReceivePort? _workerReceivePort;
  bool _isOfflineModel = false;
  bool _isZipformer = false;
  int _nextTaskId = 0;
  Completer<void>? _finishCompleter;
  Float32List? _lastDispatchedSamples;

  // 针对非流式离线模型的分块缓冲与句子断句遗留
  final List<double> _pendingSamples = <double>[];
  final List<double> _carryOverSamples = <double>[];
  int _chunkStartSampleOffset = 0; // 当前 chunk 起始音频相对会话开头的采样偏移
  bool _isDecoding = false;

  bool _isOnlineDecoding = false;
  int? _onlineUtteranceStartMs;
  void Function(Map<String, dynamic>)? _onResult;
  void Function(AsrStreamException)? _onError;
  Timer? _pollTimer;

  bool _closed = false;
  bool _ending = false;
  bool _done = false;
  int _bytesSent = 0;
  int _utteranceIndex = 0;
  int? _processedMs;
  String _lastEmittedText = '';
  int _lastEmittedEndMs = 0;

  @override
  bool get done => _done;

  @override
  int get sentMilliseconds => _bytesSent ~/ _bytesPerMillisecond;

  @override
  int? get processedMilliseconds => _processedMs;

  @override
  int get maxAudioBytes => _sampleRate * 2 * 60 * 60; // 1 小时上限

  @override
  int get decodeChunkMs =>
      _isOfflineModel ? 8000 : math.max(1, _frameBytes ~/ _bytesPerMillisecond);

  static String normalizeSenseVoiceLang(String? lang) {
    if (lang == null || lang.isEmpty || lang == 'auto' || lang == 'multi') {
      return 'auto';
    }
    final l = lang.trim().toLowerCase();
    if (l.startsWith('zh-cn') || l.startsWith('zh-hans') || l == 'zh') return 'zh';
    if (l.startsWith('yue') || l.startsWith('zh-hk')) return 'yue';
    if (l.startsWith('en')) return 'en';
    if (l.startsWith('ja')) return 'ja';
    if (l.startsWith('ko')) return 'ko';
    return 'auto';
  }

  static String normalizeWhisperLang(String? lang) {
    if (lang == null || lang.isEmpty || lang == 'auto' || lang == 'multi') {
      return '';
    }
    final l = lang.trim().toLowerCase();
    if (l.startsWith('zh-cn') || l.startsWith('zh-hans') || l == 'zh') return 'zh';
    if (l.startsWith('yue') || l.startsWith('zh-hk')) return 'yue';
    if (l.startsWith('en')) return 'en';
    if (l.startsWith('ja')) return 'ja';
    if (l.startsWith('ko')) return 'ko';
    return '';
  }

  @override
  Future<void> connect(
    Uri endpoint, {
    IeeioTokenLoader? ieeioLoginToken,
    String? language,
    required void Function(Map<String, dynamic>) onResult,
    required void Function(AsrStreamException) onError,
  }) async {
    _onResult = onResult;
    _onError = onError;

    try {
      final ready = await LocalAsrModelManager.shared.isModelReady();
      if (!ready) {
        throw const AsrStreamException(
          '本地识别模型尚未下载，请在字幕设置中下载离线模型',
          retryable: false,
        );
      }

      final modelDir = await LocalAsrModelManager.shared.getModelDir();

      // 初始化 Sherpa 原生底层绑定
      LocalAsrModelManager.ensureInitialized();

      final currentModel = LocalAsrModelManager.shared.currentModel;
      _isZipformer = currentModel.id.contains('zipformer');
      if (currentModel.id == 'sense_voice' ||
          currentModel.id.startsWith('whisper_')) {
        final isSenseVoice = currentModel.id == 'sense_voice';
        if (isSenseVoice) {
          final modelPath = '$modelDir/model.int8.onnx';
          final tokensPath = '$modelDir/tokens.txt';
          if (!File(modelPath).existsSync() || !File(tokensPath).existsSync()) {
            throw const AsrStreamException('SenseVoice 离线模型文件缺失，请重新下载',
                retryable: false);
          }
        } else {
          final prefix = currentModel.id.replaceFirst('whisper_', '');
          final encoderPath = '$modelDir/$prefix-encoder.int8.onnx';
          final decoderPath = '$modelDir/$prefix-decoder.int8.onnx';
          final tokensPath = '$modelDir/$prefix-tokens.txt';
          if (!File(encoderPath).existsSync() ||
              !File(decoderPath).existsSync() ||
              !File(tokensPath).existsSync()) {
            throw AsrStreamException('${currentModel.name} 离线模型文件缺失，请重新下载',
                retryable: false);
          }
        }

        // 启动独立 Worker Isolate，将神经网络完全移至工作线程并启用 NPU/NNAPI 加速，避免阻塞主 UI 线程
        final handshakeCompleter = Completer<SendPort>();
        final receivePort = ReceivePort();
        _workerReceivePort = receivePort;

        receivePort.listen((message) {
          if (!handshakeCompleter.isCompleted) {
            if (message is SendPort) {
              handshakeCompleter.complete(message);
            } else {
              handshakeCompleter.completeError(
                AsrStreamException('$message', retryable: false),
              );
            }
            return;
          }
          if (message is _OfflineWorkerResult) {
            _handleWorkerResult(message);
          }
        });

        _workerIsolate = await Isolate.spawn(
          _offlineWorkerEntry,
          _OfflineWorkerInitParams(
            replyPort: receivePort.sendPort,
            modelType: currentModel.id,
            modelDir: modelDir,
            preferNnapi: Platform.isAndroid,
            language: normalizeSenseVoiceLang(language),
          ),
        );

        _workerSendPort = await handshakeCompleter.future;
        _isOfflineModel = true;
      } else {
        // Zipformer 系列（中文/英文双语及纯英文）
        // Determine suffix for English‑only model
        final isZipformerEn = currentModel.id == 'zipformer_en';
        final suffix = isZipformerEn ? '-chunk-16-left-128' : '';
        final encoderPath = '$modelDir/encoder-epoch-99-avg-1$suffix.int8.onnx';
        final decoderPath = '$modelDir/decoder-epoch-99-avg-1$suffix.onnx';
        final joinerPath = '$modelDir/joiner-epoch-99-avg-1$suffix.int8.onnx';
        final tokensPath = '$modelDir/tokens.txt';

        // Validate presence of all required files
        if (!File(encoderPath).existsSync() ||
            !File(decoderPath).existsSync() ||
            !File(joinerPath).existsSync() ||
            !File(tokensPath).existsSync()) {
          throw const AsrStreamException('Zipformer 离线模型文件缺失，请重新下载',
              retryable: false);
        }

        final transducerConfig = sherpa.OnlineTransducerModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
          joiner: joinerPath,
        );

        sherpa.OnlineRecognizer createZipformer() {
          final modelConfig = sherpa.OnlineModelConfig(
            transducer: transducerConfig,
            tokens: tokensPath,
            numThreads: math.max(1, math.min(4, Platform.numberOfProcessors)),
            debug: false,
            provider: 'cpu',
            modelType: '', // 留空使 sherpa-onnx 自动检测 zipformer2 架构，切勿写死 zipformer 导致崩溃
          );
          final featConfig = sherpa.FeatureConfig(
            sampleRate: _sampleRate,
            featureDim: 80,
          );
          final config = sherpa.OnlineRecognizerConfig(
            model: modelConfig,
            feat: featConfig,
            enableEndpoint: true,
            rule1MinTrailingSilence: endpointTrailingSilence1,
            rule2MinTrailingSilence: endpointTrailingSilence2,
            rule3MinUtteranceLength: endpointMinUtterance,
            decodingMethod: 'greedy_search',
          );
          return sherpa.OnlineRecognizer(config);
        }

        // 统一使用稳定高效的 CPU 多核推断，严禁在 Transducer/Paraformer 上开启 Android NNAPI 导致 native abort 崩溃
        _onlineRecognizer = createZipformer();
        _onlineStream = _onlineRecognizer!.createStream();
      }

      // 模拟握手 ready 事件与主播放器时钟对齐
      onResult({
        'ready': true,
        'sample_rate': _sampleRate,
        'format': 'int16_le',
        'channels': 1,
        'protocol_version': 1,
        'chunk_seconds': 0.64,
        'max_session_seconds': 3600,
      });

      // 启动定时轮询解码结果（仅针对流式在线模型，离线模型由后台工作 Isolate 事件驱动）
      if (_onlineRecognizer != null) {
        _pollTimer = Timer.periodic(
          const Duration(milliseconds: 100),
          (_) => _decodeAndEmit(),
        );
      }
    } on AsrStreamException {
      rethrow;
    } catch (e) {
      throw AsrStreamException('本地语音引擎启动失败: $e', retryable: false);
    }
  }

  @override
  Future<void> send(Uint8List pcm) async {
    if (_closed || _ending || _done) return;

    final samples = _int16ToFloat32(pcm);
    try {
      _bytesSent += pcm.length;
      _processedMs = sentMilliseconds;

      if (_onlineStream != null) {
        _onlineStream!.acceptWaveform(samples: samples, sampleRate: _sampleRate);
        _decodeOnline(isFinal: false);
      } else if (_isOfflineModel) {
        _pendingSamples.addAll(samples);
        _checkAndDispatchOfflineChunk(isFinal: false);
      }
    } catch (e) {
      _onError?.call(AsrStreamException('本地识别处理异常: $e', retryable: true));
    }
  }

  @override
  Future<void> finish() async {
    if (_closed || _ending || _done) return;
    _ending = true;

    try {
      if (_onlineStream != null) {
        // 借鉴 D:\app\realtime-asr SherpaEngine 算法：
        // 冲刷 Zipformer/Transducer 的未来声学上下文预测窗 (Look-Ahead Window, 约 500ms 静音)，
        // 确保句末最后一个词/音节绝不被卡在预测窗中被截断丢弃！
        _onlineStream!.acceptWaveform(
          samples: Float32List(8000),
          sampleRate: _sampleRate,
        );
        _onlineStream!.inputFinished();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        _decodeOnline(isFinal: true);
      } else if (_isOfflineModel) {
        while (_isDecoding && !_closed) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final hasRemaining =
            _pendingSamples.isNotEmpty || _carryOverSamples.isNotEmpty;
        if (hasRemaining && !_closed) {
          final completer = Completer<void>();
          _finishCompleter = completer;
          _checkAndDispatchOfflineChunk(isFinal: true);
          await completer.future.timeout(
            const Duration(seconds: 8),
            onTimeout: () {},
          );
        }
      }
    } catch (_) {}

    _onResult?.call({'done': true});
    _done = true;
  }

  void _decodeAndEmit({bool isFinal = false}) {
    if (_closed) return;

    try {
      if (_onlineRecognizer != null && _onlineStream != null) {
        _decodeOnline(isFinal: isFinal);
      }
    } catch (e) {
      // 容错处理
    }
  }

  void _decodeOnline({required bool isFinal}) {
    if (_closed || _isOnlineDecoding) return;
    final recognizer = _onlineRecognizer;
    final stream = _onlineStream;
    if (recognizer == null || stream == null) return;

    _isOnlineDecoding = true;
    try {
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }

      final result = recognizer.getResult(stream);
      final String text = CaptionTextFormatter.format(
        tokens: result.tokens,
        rawText: result.text,
        lowerCaseEnglish: _isZipformer,
      );

      if (text.isEmpty && !isFinal) return;

      if (text.isNotEmpty && _onlineUtteranceStartMs == null) {
        _onlineUtteranceStartMs = math.max(0, sentMilliseconds - 640);
      }

      final isEndpoint = recognizer.isEndpoint(stream) || isFinal;

      // 只有在说话人自然停顿(isEndpoint)或会话结束(isFinal)时才成句发射并安全重置流状态：
      // 严禁在说话人说话未停顿时强行 reset(stream)，否则会瞬间清空流式神经网络内部的特征缓存，导致后续几个词全部丢失（严重漏词）！
      if (isEndpoint && text.isNotEmpty) {
        _utteranceIndex++;
        final startMs = _onlineUtteranceStartMs ?? math.max(0, sentMilliseconds - 1500);
        _onResult?.call({
          'utterance': _utteranceIndex,
          'delta': text,
          'start_ms': startMs,
          'audio_ms': sentMilliseconds,
          'utterance_end': true,
        });
        recognizer.reset(stream);
        _onlineUtteranceStartMs = null;
      }
    } catch (_) {
      // 容错处理
    } finally {
      _isOnlineDecoding = false;
    }
  }

  void _checkAndDispatchOfflineChunk({required bool isFinal}) {
    if (_isDecoding || _closed || _workerSendPort == null) return;

    const maxSamples = vadMaxDispatchMs * _sampleRate ~/ 1000;

    final shouldDispatch = isFinal
        ? (_pendingSamples.isNotEmpty || _carryOverSamples.isNotEmpty)
        : (_pendingSamples.length >= maxSamples ||
            (offlineChunkReachedMin(_pendingSamples.length) &&
                _hasTrailingSilence(
                    _pendingSamples, silenceMs: vadTrailingSilenceMs)));

    if (!shouldDispatch) return;

    final samplesToDecode = Float32List.fromList([
      ..._carryOverSamples,
      ..._pendingSamples,
    ]);
    if (samplesToDecode.isEmpty) return;

    _pendingSamples.clear();
    _carryOverSamples.clear();
    _isDecoding = true;

    final chunkAudioStartMs = (_chunkStartSampleOffset * 1000) ~/ _sampleRate;
    final totalDurationMs = (samplesToDecode.length * 1000) ~/ _sampleRate;

    _lastDispatchedSamples = samplesToDecode;

    _nextTaskId++;
    _workerSendPort!.send(_OfflineWorkerTask(
      taskId: _nextTaskId,
      samples: samplesToDecode,
      isFinal: isFinal,
      chunkAudioStartMs: chunkAudioStartMs,
      totalDurationMs: totalDurationMs,
    ));
  }

  void _handleWorkerResult(_OfflineWorkerResult res) {
    if (_closed) return;
    _isDecoding = false;

    if (res.error != null) {
      _onError?.call(AsrStreamException('离线解码失败: ${res.error}', retryable: true));
    } else {
      _processOfflineResult(
        allSamples: _lastDispatchedSamples ?? Float32List(0),
        chunkAudioStartMs: res.chunkAudioStartMs,
        totalDurationMs: res.totalDurationMs,
        text: res.text,
        tokens: res.tokens,
        timestamps: res.timestamps,
        isFinal: res.isFinal,
      );
    }

    _lastDispatchedSamples = null;

    if (res.isFinal) {
      _finishCompleter?.complete();
      _finishCompleter = null;
    } else if (!_ending && !_closed) {
      // 若解码期间主线程积累了新音频并达到断句门槛，立即发起下一批解码
      _checkAndDispatchOfflineChunk(isFinal: false);
    }
  }

  static bool _hasTrailingSilence(List<double> samples, {int silenceMs = 700}) {
    final silenceSamples = (silenceMs * _sampleRate) ~/ 1000;
    if (samples.length < silenceSamples) return false;

    const windowSize = 320; // 20ms @ 16kHz
    const silenceEnergyThreshold = 0.0003;

    final startIdx = samples.length - silenceSamples;
    for (int i = startIdx; i + windowSize <= samples.length; i += windowSize) {
      double energy = 0.0;
      for (int w = 0; w < windowSize; w++) {
        final s = samples[i + w];
        energy += s * s;
      }
      if ((energy / windowSize) >= silenceEnergyThreshold) {
        return false;
      }
    }
    return true;
  }

  void _processOfflineResult({
    required Float32List allSamples,
    required int chunkAudioStartMs,
    required int totalDurationMs,
    required String text,
    required List<String> tokens,
    required List<double> timestamps,
    required bool isFinal,
  }) {
    if (_closed || _done || allSamples.isEmpty) return;

    final trimmed = suppressAsrShortLoops(text.trim());
    final hadLoop = trimmed != text.trim();
    if (hadLoop) {
      // Do not feed a degenerate unfinished tail back into the next decode.
      tokens = const [];
      timestamps = const [];
    }
    if (trimmed.isEmpty) {
      if (isFinal) {
        _chunkStartSampleOffset = 0;
      } else {
        // 该分段为静音/背景音，推进时间偏移，避免时间戳滞后
        _chunkStartSampleOffset += allSamples.length;
      }
      return;
    }

    // 解析并切分整句与末尾未完结句
    final split = _splitSentences(trimmed, isFinal: isFinal || hadLoop);
    List<String> completedSentences = split.completed;
    String incompleteSentence = split.incomplete;

    if (isFinal) {
      final allToEmit = [...completedSentences];
      if (incompleteSentence.isNotEmpty) {
        allToEmit.add(incompleteSentence);
      }
      if (allToEmit.isNotEmpty) {
        _processChunkResult(
          allSamples: allSamples,
          chunkAudioStartMs: chunkAudioStartMs,
          totalDurationMs: totalDurationMs,
          completedSentences: allToEmit,
          incompleteSentence: '',
          tokens: tokens,
          timestamps: timestamps,
        );
      }
      _chunkStartSampleOffset = 0;
      return;
    }

    if (completedSentences.isEmpty) {
      final forcedSplit = _forceSplitLongText(trimmed);
      completedSentences = forcedSplit.completed;
      incompleteSentence = forcedSplit.incomplete;
    }

    if (completedSentences.isNotEmpty) {
      _processChunkResult(
        allSamples: allSamples,
        chunkAudioStartMs: chunkAudioStartMs,
        totalDurationMs: totalDurationMs,
        completedSentences: completedSentences,
        incompleteSentence: incompleteSentence,
        tokens: tokens,
        timestamps: timestamps,
      );
    } else {
      _carryOverSamples.addAll(allSamples);
    }
  }

  void _processChunkResult({
    required Float32List allSamples,
    required int chunkAudioStartMs,
    required int totalDurationMs,
    required List<String> completedSentences,
    required String incompleteSentence,
    required List<String> tokens,
    required List<double> timestamps,
  }) {
    final sentenceTimings = <({String text, int startMs, int endMs})>[];
    final sentenceWords = <int, List<AsrWordTiming>>{};
    int splitSampleIndex = allSamples.length;

    final timedWords = alignAsrWords(
      [...completedSentences, incompleteSentence].join('\n'),
      offlineWordTimings(
        tokens: tokens,
        timestamps: timestamps,
        chunkAudioStartMs: chunkAudioStartMs,
        totalDurationMs: totalDurationMs,
      ),
    );
    if (timedWords.isNotEmpty) {
      // 按原文偏移匹配 token，标点不再误消耗下一句的第一个词。
      var offset = 0;
      for (final sentence in completedSentences) {
        final words = timedWords.where((word) =>
            word.startOffset >= offset &&
            word.startOffset < offset + sentence.length).toList();
        offset += sentence.length + 1;
        if (words.isEmpty) continue;
        sentenceWords[sentenceTimings.length] = words;
        sentenceTimings.add((text: sentence,
            startMs: words.first.startMs, endMs: words.last.endMs));
      }

      final incompleteWords = timedWords.where((word) => word.startOffset >= offset);
      if (incompleteSentence.isNotEmpty && incompleteWords.isNotEmpty) {
        final incStartMs = incompleteWords.first.startMs - chunkAudioStartMs;
        // 预留 100ms 安全前导余量，避免切碎首个字的发音
        splitSampleIndex = ((incStartMs - 100) * _sampleRate ~/ 1000)
            .clamp(0, allSamples.length);
      }
    } else {
      // 容灾：模型没有返回时间戳时，基于实际能量检测（VAD）定位发音区间，跳过静音和片头BGM
      final ranges = _detectSpeechRanges(allSamples);
      if (ranges.isNotEmpty) {
        final completedLen =
            completedSentences.map((s) => s.length).fold<int>(0, (a, b) => a + b);
        final totalChars = completedLen + incompleteSentence.length;

        var charOffset = 0;
        for (final sentence in completedSentences) {
          final sRatio = charOffset / totalChars;
          charOffset += sentence.length;
          final eRatio = charOffset / totalChars;

          final sSample = _sampleAtSpeechRatio(ranges, sRatio);
          final eSample = _sampleAtSpeechRatio(ranges, eRatio);

          final startMs = chunkAudioStartMs + (sSample * 1000) ~/ _sampleRate;
          final endMs = chunkAudioStartMs + (eSample * 1000) ~/ _sampleRate;
          sentenceTimings.add(
              (text: sentence, startMs: startMs, endMs: math.max(endMs, startMs + 400)));
        }

        if (incompleteSentence.isNotEmpty && totalChars > 0) {
          splitSampleIndex = _sampleAtSpeechRatio(ranges, completedLen / totalChars);
        }
      } else {
        // 全静音无能量保护兜底
        final totalChars =
            completedSentences.map((s) => s.length).fold<int>(0, (a, b) => a + b) +
                incompleteSentence.length;
        var curMs = chunkAudioStartMs;
        for (final s in completedSentences) {
          final dur = totalChars > 0
              ? ((s.length / totalChars) * totalDurationMs).round()
              : 1000;
          sentenceTimings.add((text: s, startMs: curMs, endMs: curMs + dur));
          curMs += dur;
        }
      }
    }

    // 发射所有完整句子（增加声学回退重叠完全重复抑制保护）
    for (var index = 0; index < sentenceTimings.length; index++) {
      final st = sentenceTimings[index];
      final text = st.text.trim();
      if (text.isEmpty) continue;

      // 若与刚刚发射的文本完全一致，且时间重叠或紧随其后（<= 400ms），判定为声学回退重复。
      // 但短句（<8字）是用户真的在重复（"对，对"、"一，二，一"），必须放行，否则漏词。
      if (text == _lastEmittedText &&
          text.length >= 8 &&
          st.startMs <= _lastEmittedEndMs + 400) {
        continue;
      }

      _lastEmittedText = text;
      _lastEmittedEndMs = st.endMs;

      _utteranceIndex++;
      _onResult?.call({
        'utterance': _utteranceIndex,
        'delta': st.text,
        'start_ms': st.startMs,
        'audio_ms': st.endMs,
        'utterance_end': true,
        'words': [
          for (final word in sentenceWords[index] ?? const <AsrWordTiming>[])
            word.toJson(),
        ],
      });
    }

    // 将未完结句子的音频留存至下一次 chunk ("对应句子不完整的部分，可以保留接上后来识别的部分合并起来，不断循环")
    _carryOverSamples.clear();
    final carryStart = offlineCarryStart(
      sampleCount: allSamples.length,
      splitSampleIndex: splitSampleIndex,
      hasIncompleteSentence: incompleteSentence.isNotEmpty,
    );
    if (carryStart < allSamples.length) {
      _carryOverSamples.addAll(allSamples.sublist(carryStart));
    }
    _chunkStartSampleOffset += carryStart;
  }

  List<({int start, int end})> _detectSpeechRanges(Float32List samples) {
    const windowSize = 320; // 20ms @ 16kHz
    const silenceEnergyThreshold = 0.0003; // RMS ~0.017
    final ranges = <({int start, int end})>[];
    int? speechStart;
    int silenceWindows = 0;

    for (int i = 0; i + windowSize <= samples.length; i += windowSize) {
      double energy = 0.0;
      for (int w = 0; w < windowSize; w++) {
        final s = samples[i + w];
        energy += s * s;
      }
      final isSpeech = (energy / windowSize) >= silenceEnergyThreshold;

      if (isSpeech) {
        speechStart ??= math.max(0, i - windowSize * 2);
        silenceWindows = 0;
      } else if (speechStart != null) {
        silenceWindows++;
        if (silenceWindows >= 15) {
          // 300ms 沉默
          ranges.add((start: speechStart, end: i));
          speechStart = null;
          silenceWindows = 0;
        }
      }
    }
    if (speechStart != null) {
      ranges.add((start: speechStart, end: samples.length));
    }
    return ranges;
  }

  int _sampleAtSpeechRatio(List<({int start, int end})> ranges, double ratio) {
    if (ranges.isEmpty) return 0;
    final total = ranges.fold<int>(0, (sum, r) => sum + (r.end - r.start));
    var target = (total * ratio.clamp(0.0, 1.0)).round();
    for (final r in ranges) {
      final len = r.end - r.start;
      if (target <= len) return r.start + target;
      target -= len;
    }
    return ranges.last.end;
  }

  ({List<String> completed, String incomplete}) _splitSentences(
    String text, {
    required bool isFinal,
  }) {
    if (text.isEmpty) return (completed: const <String>[], incomplete: '');

    // 句末主标点：句号、叹号、问号、换行，或英文句末句号+空格/结尾（代表完整语义结束）
    final majorDelimiters = RegExp(r'[。！？!?\n]|(?<=[a-zA-Z0-9])\.(?:\s+|$)');
    final majorMatches = majorDelimiters.allMatches(text).toList();

    if (majorMatches.isNotEmpty) {
      final completed = <String>[];
      int lastEnd = 0;
      for (final match in majorMatches) {
        final sentence = text.substring(lastEnd, match.end).trim();
        if (sentence.isNotEmpty) {
          completed.add(sentence);
        }
        lastEnd = match.end;
      }
      final trailing = text.substring(lastEnd).trim();
      if (isFinal && trailing.isNotEmpty) {
        completed.add(trailing);
        return (completed: completed, incomplete: '');
      }
      return (completed: completed, incomplete: trailing);
    }

    if (isFinal) {
      return (completed: [text], incomplete: '');
    }

    // 次级标点断句（逗号、顿号、分号、冒号）：
    // 只有当整个子句长度达到足够完整（中文 >= 20字，或西文 >= 10个单词）时，才允许按逗号自然分段，
    // 杜绝将 2-5 个字短语（如"大家好，"、"关注，"）切碎成孤立无意义的小碎块！
    final secDelimiters = RegExp(r'[，、；：,;:]');
    final secMatches = secDelimiters.allMatches(text).toList();
    if (secMatches.isNotEmpty && text.length >= 20) {
      RegExpMatch? bestMatch;
      for (final m in secMatches) {
        if (m.end >= 14 && m.end <= 28) {
          bestMatch = m;
          break;
        }
      }
      bestMatch ??= secMatches.last;
      if (bestMatch.end >= 10) {
        final clause = text.substring(0, bestMatch.end).trim();
        final remaining = text.substring(bestMatch.end).trim();
        if (clause.isNotEmpty) {
          return (completed: [clause], incomplete: remaining);
        }
      }
    }

    // 西文长句保护：按空格完整单词边界切分，保留未完结单词
    if (text.contains(' ') && text.length >= 45) {
      final spaceIdx = text.lastIndexOf(' ', 40);
      if (spaceIdx > 15) {
        return (
          completed: [text.substring(0, spaceIdx).trim()],
          incomplete: text.substring(spaceIdx + 1).trim(),
        );
      }
    } else if (text.length >= 35) {
      // 中文超长未断句保护：满 30 字以上才切分，避免切成过短的小碎块
      return (
        completed: [text.substring(0, 26)],
        incomplete: text.substring(26),
      );
    }

    return (completed: const <String>[], incomplete: text);
  }

  ({List<String> completed, String incomplete}) _forceSplitLongText(
      String text) {
    if (text.isEmpty) return (completed: const <String>[], incomplete: '');
    final secDelimiters = RegExp(r'[，、；：,;:]');
    final matches = secDelimiters.allMatches(text).toList();
    if (matches.isNotEmpty) {
      final completed = <String>[];
      int lastEnd = 0;
      for (final match in matches) {
        final sentence = text.substring(lastEnd, match.end).trim();
        if (sentence.isNotEmpty) {
          completed.add(sentence);
        }
        lastEnd = match.end;
      }
      final trailing = text.substring(lastEnd).trim();
      return (completed: completed, incomplete: trailing);
    }
    if (text.length > 30) {
      if (text.contains(' ')) {
        final spaceIdx = text.lastIndexOf(' ', 30);
        if (spaceIdx > 10) {
          return (
            completed: [text.substring(0, spaceIdx).trim()],
            incomplete: text.substring(spaceIdx + 1).trim(),
          );
        }
      }
      return (
        completed: [text.substring(0, 25)],
        incomplete: text.substring(25),
      );
    }
    return (completed: [text], incomplete: '');
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _onError = null;
    _onResult = null;

    if (_finishCompleter != null && !_finishCompleter!.isCompleted) {
      try {
        _finishCompleter!.complete();
      } catch (_) {}
      _finishCompleter = null;
    }

    try {
      _workerSendPort?.send('close');
    } catch (_) {}
    _workerReceivePort?.close();
    _workerReceivePort = null;
    _workerSendPort = null;
    try {
      _workerIsolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _workerIsolate = null;

    try {
      _onlineStream?.free();
    } catch (_) {}
    _onlineStream = null;

    try {
      _onlineRecognizer?.free();
    } catch (_) {}
    _onlineRecognizer = null;

    _carryOverSamples.clear();
    _pendingSamples.clear();
    _chunkStartSampleOffset = 0;
    _done = true;
  }

  static Float32List _int16ToFloat32(Uint8List pcm) {
    final byteData = ByteData.sublistView(pcm);
    final count = pcm.length ~/ 2;
    final floats = Float32List(count);
    for (int i = 0; i < count; i++) {
      floats[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return floats;
  }
}

class _OfflineWorkerInitParams {
  final SendPort replyPort;
  final String modelType;
  final String modelDir;
  final bool preferNnapi;
  final String language;

  const _OfflineWorkerInitParams({
    required this.replyPort,
    required this.modelType,
    required this.modelDir,
    required this.preferNnapi,
    this.language = 'auto',
  });
}

class _OfflineWorkerTask {
  final int taskId;
  final Float32List samples;
  final bool isFinal;
  final int chunkAudioStartMs;
  final int totalDurationMs;

  const _OfflineWorkerTask({
    required this.taskId,
    required this.samples,
    required this.isFinal,
    required this.chunkAudioStartMs,
    required this.totalDurationMs,
  });
}

class _OfflineWorkerResult {
  final int taskId;
  final String text;
  final List<String> tokens;
  final List<double> timestamps;
  final bool isFinal;
  final int chunkAudioStartMs;
  final int totalDurationMs;
  final int sampleCount;
  final String? error;

  const _OfflineWorkerResult({
    required this.taskId,
    required this.text,
    required this.tokens,
    required this.timestamps,
    required this.isFinal,
    required this.chunkAudioStartMs,
    required this.totalDurationMs,
    required this.sampleCount,
    this.error,
  });
}

void _offlineWorkerEntry(_OfflineWorkerInitParams params) {
  try {
    sherpa.initBindings();
  } catch (e) {
    params.replyPort.send('ERROR: 初始化 Sherpa 原生绑定失败: $e');
    return;
  }

  sherpa.OfflineRecognizer? recognizer;

  sherpa.OfflineRecognizer createRecognizer(String provider) {
    if (params.modelType == 'sense_voice') {
      final modelPath = '${params.modelDir}/model.int8.onnx';
      final tokensPath = '${params.modelDir}/tokens.txt';
      final senseVoiceConfig = sherpa.OfflineSenseVoiceModelConfig(
        model: modelPath,
        language: LocalAsrStream.normalizeSenseVoiceLang(params.language),
        useInverseTextNormalization: true,
      );
      final modelConfig = sherpa.OfflineModelConfig(
        senseVoice: senseVoiceConfig,
        tokens: tokensPath,
        numThreads: math.max(1, math.min(4, Platform.numberOfProcessors)),
        debug: false,
        provider: provider,
        modelType: 'sense_voice',
      );
      return sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
        model: modelConfig,
        decodingMethod: 'greedy_search',
      ));
    } else {
      // whisper_tiny / whisper_base / whisper_small
      final prefix = params.modelType.startsWith('whisper_')
          ? params.modelType.replaceFirst('whisper_', '')
          : 'tiny';
      final encoderPath = '${params.modelDir}/$prefix-encoder.int8.onnx';
      final decoderPath = '${params.modelDir}/$prefix-decoder.int8.onnx';
      final tokensPath = '${params.modelDir}/$prefix-tokens.txt';
      final whisperConfig = sherpa.OfflineWhisperModelConfig(
        encoder: encoderPath,
        decoder: decoderPath,
        language: LocalAsrStream.normalizeWhisperLang(params.language),
      );
      final modelConfig = sherpa.OfflineModelConfig(
        whisper: whisperConfig,
        tokens: tokensPath,
        numThreads: math.max(1, math.min(4, Platform.numberOfProcessors)),
        debug: false,
        provider: provider,
        modelType: 'whisper',
      );
      return sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
        model: modelConfig,
        decodingMethod: 'greedy_search',
      ));
    }
  }

  try {
    if (params.preferNnapi) {
      try {
        recognizer = createRecognizer('nnapi');
      } catch (_) {
        recognizer = createRecognizer('cpu');
      }
    } else {
      recognizer = createRecognizer('cpu');
    }
  } catch (e) {
    params.replyPort.send('ERROR: 创建离线语音识别模型失败: $e');
    return;
  }

  final commandPort = ReceivePort();
  params.replyPort.send(commandPort.sendPort);

  commandPort.listen((message) {
    final rec = recognizer;
    if (message is _OfflineWorkerTask) {
      if (rec == null) return;
      try {
        final stream = rec.createStream();
        stream.acceptWaveform(samples: message.samples, sampleRate: 16000);
        rec.decode(stream);
        final result = rec.getResult(stream);
        stream.free();

        final formattedText = CaptionTextFormatter.format(
          tokens: result.tokens,
          rawText: result.text,
          lowerCaseEnglish: params.modelType.contains('zipformer'),
        );

        params.replyPort.send(_OfflineWorkerResult(
          taskId: message.taskId,
          text: formattedText,
          tokens: List<String>.from(result.tokens),
          timestamps: List<double>.from(result.timestamps),
          isFinal: message.isFinal,
          chunkAudioStartMs: message.chunkAudioStartMs,
          totalDurationMs: message.totalDurationMs,
          sampleCount: message.samples.length,
        ));
      } catch (e) {
        params.replyPort.send(_OfflineWorkerResult(
          taskId: message.taskId,
          text: '',
          tokens: const [],
          timestamps: const [],
          isFinal: message.isFinal,
          chunkAudioStartMs: message.chunkAudioStartMs,
          totalDurationMs: message.totalDurationMs,
          sampleCount: message.samples.length,
          error: '$e',
        ));
      }
    } else if (message == 'close') {
      try {
        recognizer?.free();
      } catch (_) {}
      recognizer = null;
      commandPort.close();
    }
  });
}
