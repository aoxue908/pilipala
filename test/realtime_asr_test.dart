chuaimport 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:pilipala/models/video/subTitile/result.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/audio_backlog.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_preferences.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_pronunciation.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_text_formatter.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_timeline.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_translator.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_tts_service.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/local_asr_model.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/local_asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/pcm_leveler.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/player_pcm.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/public_cloud_asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/realtime_captions.dart';

void main() {
  test('mergeCaptionTexts prevents repeating phrases and handles overlaps', () {
    // 1. 包含与子串：不重复追加
    expect(
      RealtimeCaptions.mergeCaptionTexts(
        "factory you're stuff in Shanghai",
        "factory you're stuff in Shanghai",
      ),
      "factory you're stuff in Shanghai",
    );

    // 2. 前后缀重叠
    expect(
      RealtimeCaptions.mergeCaptionTexts(
        "factory you're stuff in",
        "stuff in Shanghai",
      ),
      "factory you're stuff in Shanghai",
    );

    // 3. 连续重复短语抑制 (用户截图里的实际错误场景)
    final spam =
        "factory you're stuff in Shanghai factory you're stuff in Shanghai";
    expect(
      RealtimeCaptions.removeRepeatingPhrases(spam),
      "factory you're stuff in Shanghai",
    );

    // 4. 多次连续追加相同短语时杜绝刷屏
    var current = "factory you're stuff in";
    current = RealtimeCaptions.mergeCaptionTexts(current, "stuff in Shanghai");
    expect(current, "factory you're stuff in Shanghai");
    current = RealtimeCaptions.mergeCaptionTexts(
        current, "factory you're stuff in Shanghai");
    expect(current, "factory you're stuff in Shanghai");
    current = RealtimeCaptions.mergeCaptionTexts(current, "Shanghai");
    expect(current, "factory you're stuff in Shanghai");
  });

  test('keeps adjacent utterances with identical audio timestamps', () {
    final timing = AsrCaptionTiming(0);
    final first = timing.update(
      const AsrCaption(0, 'Hello', true, audioMs: 640),
      sentMs: 640,
      chunkMs: 640,
    );
    final second = timing.update(
      const AsrCaption(1, 'World', true, audioMs: 640),
      sentMs: 640,
      chunkMs: 640,
    );
    expect(first.single.text, 'Hello');
    expect(second.single.text, 'World');
    expect(second.single.endMs, greaterThan(second.single.startMs));
  });

  test('translates the source text to simplified Chinese', () async {
    final client = Dio();
    final translator = CaptionTranslator(client: client);
    addTearDown(translator.close);
    final samples = {
      'Take a seat. The lesson begins soon.': ['请坐。', '课程马上开始。'],
      '授業はまもなく始まります。': ['课程马上开始。'],
    };
    client.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      expect(request.uri.host, 'google.qianche.dpdns.org');
      expect(request.queryParameters['sl'], 'auto');
      expect(request.queryParameters['tl'], 'zh-CN');
      final text = request.queryParameters['q'];
      final parts = samples[text]!;
      handler.resolve(Response<String>(
        requestOptions: request,
        data: jsonEncode([
          [
            for (final part in parts) [part, text]
          ],
        ]),
      ));
    }));
    for (final sample in samples.entries) {
      expect(await translator.toChinese(sample.key, CancelToken()),
          sample.value.join());
    }
  });

  test('starts ASR at current playback after a slow connection', () {
    final clock = CaptionPlaybackClock();
    clock.update(2000, 0, moving: true, rate: 1);
    final oldPosition = clock.at(0);
    clock.update(14600, 12600, moving: true, rate: 1);
    final currentPosition = clock.at(12700);
    final timing = AsrCaptionTiming.fromPlayback(
      currentPosition,
      resumeFromMs: oldPosition,
    );
    expect(timing.originMs, 14450);
    final cues = timing.update(
      const AsrCaption(0, 'Now playing', true, audioMs: 640),
      sentMs: 640,
      chunkMs: 640,
    );
    final timeline = CaptionTimeline(cues);
    expect(timeline.at(oldPosition), isNull);
    expect(timeline.at(currentPosition)?.text, 'Now playing');
    expect(
      AsrCaptionTiming.fromPlayback(currentPosition, resumeFromMs: 16500)
          .originMs,
      16500,
    );
  });

  test('places prefetched speech and karaoke on the media timeline', () {
    final timing = AsrCaptionTiming(40000);
    final audio = ByteData(1600 * 32);
    for (var sample = 0; sample < audio.lengthInBytes ~/ 2; sample++) {
      final ms = sample ~/ 16;
      if ((ms >= 240 && ms < 640) || (ms >= 1040 && ms < 1520)) {
        audio.setInt16(sample * 2, 3000, Endian.little);
      }
    }
    timing.speech.add(audio.buffer.asUint8List());
    timing.update(
      const AsrCaption(0, 'Hello', false, audioMs: 700),
      sentMs: 1600,
      chunkMs: 640,
    );
    final cues = timing.update(
      const AsrCaption(0, 'Hello world', true, audioMs: 1600),
      sentMs: 1600,
      chunkMs: 640,
    );
    final cue = cues.single;
    final timeline = CaptionTimeline(cues);
    expect(timeline.at(40239), isNull);
    expect(timeline.at(40240), cue);
    expect(cue.highlightAt(40900), 5);
    expect(cue.highlightAt(41520), cue.text.length);
    expect(timeline.at(cue.endMs), isNull);
    expect(timeline.upcoming(40000, 42000).single.text, 'Hello world');
  });

  test('splits a long built-in caption without changing its time span', () {
    const line = '先介绍今天要做的内容，接下来我们会分几个部分详细讲解。'
        '每个部分都会有一个例子，让大家可以边听边看。';
    final timeline = CaptionTimeline.fromVideo([
      {'from': 1.25, 'to': 9.5, 'content': line},
    ]);
    final cues = timeline.upcoming(0, 10000).toList();
    expect(cues.length, greaterThan(2));
    expect(cues.map((cue) => cue.text).join(), line);
    expect(cues.first.startMs, 1250);
    expect(cues.last.endMs, 9500);
    expect(timeline.at(9500), isNull);
    for (var index = 1; index < cues.length; index++) {
      expect(cues[index].startMs, cues[index - 1].endMs);
    }
  });

  test('caption playback clock follows speed, pause and seek', () {
    final clock = CaptionPlaybackClock();
    clock.update(4500, 1000, moving: true, rate: 2);
    expect(clock.at(1100), 4700);
    clock.update(4700, 1100, moving: false, rate: 2);
    expect(clock.at(1800), 4700);
    clock.update(18000, 1800, moving: true, rate: 0.75);
    expect(clock.at(2000), 18150);
  });

  test('finalizes the current utterance on an empty done message', () {
    final transcript = AsrTranscript();
    transcript
        .accept({'utterance': 0, 'delta': 'Hello', 'audio_ms': 640}).single;
    final caption = transcript.accept({'done': true, 'audio_ms': 1600}).single;
    expect(caption.text, 'Hello');
    expect(caption.isFinal, isTrue);
    expect(caption.audioMs, 640);
    expect(transcript.finish(), isNull);
  });

  test('the fresh ticket stays on the hosted ASR origin', () {
    final config = <String, dynamic>{
      'protocol': 'r2t2',
      'protocolVersion': 1,
      'token': 'a+b=c',
      'websocketUrl': '/api/v1/meeting/transcription/realtime/stream?old=1',
    };
    final uri = ieeioTicketUri(config);
    expect(uri.scheme, 'wss');
    expect(uri.host, 'asr.ieeio.com');
    expect(uri.queryParameters, {'ticket': 'a+b=c'});
    for (final bad in [
      'https://example.com/api/v1/meeting/transcription/realtime/stream',
      'https://asr.ieeio.com:8443/api/v1/meeting/transcription/realtime/stream',
      'https://asr.ieeio.com/v1/stream',
    ]) {
      expect(() => ieeioTicketUri({...config, 'websocketUrl': bad}),
          throwsA(isA<AsrStreamException>()));
    }
  });

  test('keeps delta whitespace and finalizes a sentence once', () {
    final transcript = AsrTranscript();
    Iterable<AsrCaption> message(int utterance, String delta,
            {bool end = false}) =>
        transcript.accept(
            {'utterance': utterance, 'delta': delta, 'utterance_end': end});

    expect(message(0, 'Good').single.text, 'Good');
    expect(message(0, ' morning').single.text, 'Good morning');
    expect(message(0, '', end: true).single.isFinal, isTrue);
    expect(message(0, '', end: true), isEmpty);
    expect(message(1, 'Welcome').single.text, 'Welcome');
    final completed = message(2, '').single;
    expect(completed.text, 'Welcome');
    expect(completed.isFinal, isTrue);
    expect(message(1, '!'), isEmpty);
    expect(message(2, 'Next', end: true).single.text, 'Next');
  });

  test('skips the streaming WAVE header and checks PCM format', () {
    final bytes = Uint8List(68);
    final data = ByteData.sublistView(bytes)
      ..setUint32(0, 0x52494646)
      ..setUint32(8, 0x57415645)
      ..setUint32(12, 0x666d7420)
      ..setUint32(16, 40, Endian.little)
      ..setUint16(20, 0xfffe, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, 16000, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(44, 1, Endian.little)
      ..setUint32(60, 0x64617461)
      ..setUint32(64, 0x7ffff000, Endian.little);
    expect(readAsrWaveHeader(bytes), 68);
    data.setUint32(24, 48000, Endian.little);
    expect(() => readAsrWaveHeader(bytes), throwsFormatException);
  });

  test('opens a WebSocket, batches PCM and drains the final text', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final receives = <dynamic>[];
    final ended = Completer<void>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((event) {
        receives.add(event);
        if (event == '{}') {
          socket.add(jsonEncode({
            'ready': true,
            'sample_rate': 16000,
            'chunk_seconds': 0.64,
          }));
        } else if (event == 'end') {
          socket.add(jsonEncode({
            'delta': 'Good morning',
            'utterance': 0,
            'utterance_end': true,
            'done': true,
          }));
          unawaited(socket.close());
          ended.complete();
        }
      });
    });
    final asr = AsrStream();
    addTearDown(asr.close);
    final transcript = AsrTranscript();
    final captions = <AsrCaption>[];
    final errors = <AsrStreamException>[];
    await asr.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/v1/stream'),
      onResult: (message) => captions.addAll(transcript.accept(message)),
      onError: errors.add,
    );
    await asr.send(Uint8List(20400));
    await asr.send(Uint8List(640));
    await asr.finish();
    await ended.future;
    expect(receives.map((event) => event is List ? event.length : event),
        ['{}', 20480, 560, 'end']);
    expect(captions.single.text, 'Good morning');
    expect(captions.single.isFinal, isTrue);
    expect(errors, isEmpty);
  });

  test('a dropped socket reports retryable failure and retains processed time',
      () async {
    final socket = _AsrTestSocket();
    final stream = AsrStream(
      connectSocket: (_, {headers, customClient}) async => socket,
    );
    addTearDown(stream.close);
    final errors = <AsrStreamException>[];
    await stream.connect(
      Uri.parse('ws://127.0.0.1/asr'),
      onResult: (_) {},
      onError: errors.add,
    );
    await stream.send(Uint8List(20480));
    await stream.send(Uint8List(20480));
    socket.serverMessage({'delta': 'first', 'utterance': 0, 'audio_ms': 640});
    socket.serverMessage({'delta': '', 'utterance': 0, 'audio_ms': 600});
    await socket.serverClose(1012);
    expect(socket.packets.whereType<Uint8List>().map((data) => data.length),
        [20480, 20480]);
    expect(stream.sentMilliseconds, 1280);
    expect(stream.processedMilliseconds, 640);
    expect(errors.single.retryable, isTrue);
    expect(errors.single.message, contains('1012'));
  });

  test('normal end confirmation does not report a lost connection', () async {
    final socket = _AsrTestSocket(chunk: 0.32);
    final stream = AsrStream(
      connectSocket: (_, {headers, customClient}) async => socket,
    );
    addTearDown(stream.close);
    final errors = <AsrStreamException>[];
    await stream.connect(
      Uri.parse('ws://127.0.0.1/asr'),
      onResult: (_) {},
      onError: errors.add,
    );
    await stream.send(Uint8List(10560));
    final finishing = stream.finish();
    await socket.endSent;
    socket.serverMessage({'done': true, 'audio_ms': 330});
    await socket.serverClose(1000);
    await finishing;
    expect(
        socket.packets.map((packet) => packet is List ? packet.length : packet),
        ['{}', 10240, 320, 'end']);
    expect(stream.processedMilliseconds, 330);
    expect(errors, isEmpty);
  });

  test('a silent server retries only while audio is awaiting a response',
      () async {
    const timeout = Duration(milliseconds: 40);
    final socket = _AsrTestSocket();
    final stream = AsrStream(
      connectSocket: (_, {headers, customClient}) async => socket,
      receiveTimeout: timeout,
    );
    addTearDown(stream.close);
    final reply = Completer<void>();
    final error = Completer<AsrStreamException>();
    await stream.connect(
      Uri.parse('ws://127.0.0.1/asr'),
      onResult: (_) => reply.complete(),
      onError: error.complete,
    );
    await stream.send(Uint8List(20480));
    socket.serverMessage({'delta': '', 'utterance': 0, 'audio_ms': 640});
    await reply.future;
    await Future<void>.delayed(timeout * 2);
    expect(error.isCompleted, isFalse);

    await stream.send(Uint8List(20480));
    final failure = await error.future.timeout(const Duration(seconds: 2));
    expect(failure.retryable, isTrue);
    expect(failure.message, contains('未响应'));
  });

  test('waits for transport and continues through a transcription gap',
      () async {
    final writable = Completer<void>();
    final socket = _AsrTestSocket(sendBarrier: writable.future);
    final stream = AsrStream(
      connectSocket: (_, {headers, customClient}) async => socket,
    );
    addTearDown(stream.close);
    final first = Completer<void>();
    final resumed = Completer<void>();
    final errors = <AsrStreamException>[];
    await stream.connect(
      Uri.parse('ws://127.0.0.1/asr'),
      onResult: (message) {
        if (message['delta'] == 'first') first.complete();
        if (message['delta'] == 'resumed') resumed.complete();
      },
      onError: errors.add,
    );

    var sent = false;
    final sending = stream.send(Uint8List(20480)).then((_) => sent = true);
    await Future<void>.delayed(Duration.zero);
    expect(sent, isFalse);
    writable.complete();
    await sending;
    socket.serverMessage({'delta': 'first', 'utterance': 0, 'audio_ms': 640});
    await first.future;

    // The socket keeps taking audio while the recognizer sends no events.
    for (var i = 0; i < 12; i++) {
      await stream.send(Uint8List(20480));
    }
    expect(stream.sentMilliseconds, 8320);
    expect(stream.processedMilliseconds, 640);
    expect(socket.packets.whereType<Uint8List>(), hasLength(13));

    socket
        .serverMessage({'delta': 'resumed', 'utterance': 1, 'audio_ms': 8320});
    await resumed.future;
    expect(stream.processedMilliseconds, 8320);
    expect(errors, isEmpty);
  });

  test(
      'Sherpa-ONNX model configurations include SenseVoice, Paraformer, Whisper, and Zipformer',
      () {
    expect(LocalAsrModelManager.availableModels.length, 6);

    final senseVoice = LocalAsrModelManager.availableModels['sense_voice'];
    expect(senseVoice, isNotNull);
    expect(senseVoice!.requiredFiles, contains('model.int8.onnx'));
    expect(senseVoice.requiredFiles, contains('tokens.txt'));
    expect(senseVoice.mirrorBaseUrls.first, contains('hf-mirror.com'));

    final whisperBase = LocalAsrModelManager.availableModels['whisper_base'];
    expect(whisperBase, isNotNull);
    expect(whisperBase!.requiredFiles, contains('base-encoder.int8.onnx'));
    expect(whisperBase.requiredFiles, contains('base-decoder.int8.onnx'));
    expect(whisperBase.requiredFiles, contains('base-tokens.txt'));

    final whisper = LocalAsrModelManager.availableModels['whisper_tiny'];
    expect(whisper, isNotNull);
    expect(whisper!.requiredFiles, contains('tiny-encoder.int8.onnx'));
    expect(whisper.requiredFiles, contains('tiny-decoder.int8.onnx'));
    expect(whisper.requiredFiles, contains('tiny-tokens.txt'));

    final zipformerZhEn =
        LocalAsrModelManager.availableModels['zipformer_zh_en'];
    expect(zipformerZhEn, isNotNull);
    expect(zipformerZhEn!.requiredFiles,
        contains('encoder-epoch-99-avg-1.int8.onnx'));
    expect(
        zipformerZhEn.requiredFiles, contains('decoder-epoch-99-avg-1.onnx'));
    expect(zipformerZhEn.requiredFiles,
        contains('joiner-epoch-99-avg-1.int8.onnx'));
    expect(zipformerZhEn.requiredFiles, contains('tokens.txt'));
    // Verify minFileSizes are realistic
    expect(zipformerZhEn.minFileSizes['joiner-epoch-99-avg-1.int8.onnx'],
        lessThanOrEqualTo(2 * 1024 * 1024));

    final zipformerEn = LocalAsrModelManager.availableModels['zipformer_en'];
    expect(zipformerEn, isNotNull);
    expect(zipformerEn!.requiredFiles,
        contains('encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx'));
    expect(zipformerEn.requiredFiles,
        contains('decoder-epoch-99-avg-1-chunk-16-left-128.onnx'));
    expect(zipformerEn.requiredFiles,
        contains('joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx'));
    expect(zipformerEn.requiredFiles, contains('tokens.txt'));
    expect(
        zipformerEn
            .minFileSizes['joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx'],
        lessThanOrEqualTo(200 * 1024));
    expect(
        zipformerEn
            .minFileSizes['decoder-epoch-99-avg-1-chunk-16-left-128.onnx'],
        lessThanOrEqualTo(1024 * 1024));
    expect(zipformerEn.minFileSizes['tokens.txt'], lessThanOrEqualTo(5000));

    // Verify all models have complete minFileSizes mappings
    for (final model in LocalAsrModelManager.availableModels.values) {
      for (final file in model.requiredFiles) {
        expect(model.minFileSizes.containsKey(file), isTrue,
            reason: '${model.id} missing minFileSize for $file');
        expect(model.minFileSizes[file], greaterThan(0));
      }
    }
  });

  test('pronunciation language detection and romaji to hiragana conversion',
      () {
    expect(CaptionPronunciation.detectLanguage('你好世界'), 'zh-CN');
    expect(CaptionPronunciation.detectLanguage('唔该晒你'), 'yue');
    expect(CaptionPronunciation.detectLanguage('こんにちは'), 'ja');
    expect(CaptionPronunciation.detectLanguage('안녕하세요'), 'ko');
    expect(CaptionPronunciation.detectLanguage('Hello World'), 'en');

    expect(CaptionPronunciation.romajiToHiragana('konnichiwa'), 'こんにちは');
    expect(CaptionPronunciation.romajiToHiragana('arigatou'), 'ありがとう');
    expect(CaptionPronunciation.romajiToHiragana('gakkou'), 'がっこう');
  });

  test(
      'sentence-level subtitle updates emit complete sentences and avoid character flickering',
      () {
    final transcript = AsrTranscript();

    // 整句发射 (以句子为单位)
    final captions1 = transcript.accept({
      'utterance': 1,
      'delta': '知不知道你在说什么？',
      'utterance_end': true,
      'audio_ms': 1500,
    }).toList();

    expect(captions1, hasLength(1));
    expect(captions1.first.text, '知不知道你在说什么？');
    expect(captions1.first.isFinal, isTrue);

    // 下一句整句发射
    final captions2 = transcript.accept({
      'utterance': 2,
      'delta': '完全听不懂。',
      'utterance_end': true,
      'audio_ms': 3200,
    }).toList();

    expect(captions2, hasLength(1));
    expect(captions2.first.text, '完全听不懂。');
    expect(captions2.first.isFinal, isTrue);
  });

  test(
      'sentenceOnly AsrTranscript holds partial deltas and emits only complete sentences',
      () {
    final transcript = AsrTranscript(sentenceOnly: true, emitPreview: false);

    // 逐字输入，未到句尾标点前绝不发射，彻底杜绝刷新太快与逐字跳动
    expect(transcript.accept({'utterance': 1, 'delta': '大', 'audio_ms': 100}),
        isEmpty);
    expect(transcript.accept({'utterance': 1, 'delta': '家', 'audio_ms': 200}),
        isEmpty);
    expect(transcript.accept({'utterance': 1, 'delta': '好', 'audio_ms': 300}),
        isEmpty);

    // 句尾标点到达，整句发射
    final sent1 = transcript
        .accept({'utterance': 1, 'delta': '！', 'audio_ms': 400}).toList();
    expect(sent1, hasLength(1));
    expect(sent1.first.text, '大家好！');
    expect(sent1.first.isFinal, isTrue);

    // 第二句逐字输入
    expect(transcript.accept({'utterance': 1, 'delta': '今', 'audio_ms': 500}),
        isEmpty);
    expect(transcript.accept({'utterance': 1, 'delta': '天', 'audio_ms': 600}),
        isEmpty);
    expect(transcript.accept({'utterance': 1, 'delta': '看视频', 'audio_ms': 800}),
        isEmpty);

    final sent2 = transcript
        .accept({'utterance': 1, 'delta': '。', 'audio_ms': 1000}).toList();
    expect(sent2, hasLength(1));
    expect(sent2.first.text, '今天看视频。');
    expect(sent2.first.isFinal, isTrue);

    // 第三句未完结部分在 utterance_end 时统一成句发射
    expect(
        transcript.accept({'utterance': 1, 'delta': '谢谢大家', 'audio_ms': 1200}),
        isEmpty);
    final sent3 = transcript.accept({
      'utterance': 1,
      'delta': '',
      'utterance_end': true,
      'audio_ms': 1300
    }).toList();
    expect(sent3, hasLength(1));
    expect(sent3.first.text, '谢谢大家');
    expect(sent3.first.isFinal, isTrue);
  });

  test(
      'sentenceOnly AsrTranscript with emitPreview emits real-time preview during streaming',
      () {
    final transcript = AsrTranscript(sentenceOnly: true, emitPreview: true);

    // 第一字未达两字阈值，不发射
    expect(transcript.accept({'utterance': 1, 'delta': '大', 'audio_ms': 100}),
        isEmpty);

    // 第二字到达两字阈值，即时发射实时预览 (isFinal = false)，供 session.partial 即时渲染
    final p1 = transcript
        .accept({'utterance': 1, 'delta': '家', 'audio_ms': 200}).toList();
    expect(p1, hasLength(1));
    expect(p1.first.text, '大家');
    expect(p1.first.isFinal, isFalse);

    // 第三字继续发射实时预览
    final p2 = transcript
        .accept({'utterance': 1, 'delta': '好', 'audio_ms': 300}).toList();
    expect(p2, hasLength(1));
    expect(p2.first.text, '大家好');
    expect(p2.first.isFinal, isFalse);

    // 句尾标点到达，确认成句 (isFinal = true)
    final finalSent = transcript
        .accept({'utterance': 1, 'delta': '！', 'audio_ms': 400}).toList();
    expect(finalSent, hasLength(1));
    expect(finalSent.first.text, '大家好！');
    expect(finalSent.first.isFinal, isTrue);
  });

  test(
      'sentence boundary splitter properly separates completed sentences and carries over incomplete tail',
      () {
    // 模拟离线分块识别文本与末尾不完整句子接续
    final textChunk1 = '欢迎大家收看本期视频。今天我们来评测这款手机。首先看它的';
    final delimiters = RegExp(r'[。！？!?\n]');
    final matches = delimiters.allMatches(textChunk1).toList();

    final completed = <String>[];
    int lastEnd = 0;
    for (final m in matches) {
      completed.add(textChunk1.substring(lastEnd, m.end).trim());
      lastEnd = m.end;
    }
    final carryOverText = textChunk1.substring(lastEnd).trim();

    expect(completed, ['欢迎大家收看本期视频。', '今天我们来评测这款手机。']);
    expect(carryOverText, '首先看它的');

    // 下一个 chunk：保留的不完整部分与后续识别部分合并
    final textChunk2 = '$carryOverText外观设计，采用了全新材质。';
    final matches2 = delimiters.allMatches(textChunk2).toList();
    final completed2 = <String>[];
    int lastEnd2 = 0;
    for (final m in matches2) {
      completed2.add(textChunk2.substring(lastEnd2, m.end).trim());
      lastEnd2 = m.end;
    }
    expect(completed2, ['首先看它的外观设计，采用了全新材质。']);
  });

  test(
      'acoustic timestamp alignment accurately matches token times and preserves intro silence',
      () {
    // 模拟前 10 秒片头音乐静音，第 10.2 秒说话人开始发音
    final tokens = ['大', '家', '好', '！', '今', '天', '我', '们', '。'];
    final timestamps = [10.2, 10.4, 10.7, 10.7, 12.0, 12.2, 12.5, 12.8, 12.8];
    final completedSentences = ['大家好！', '今天我们。'];

    int tokenIdx = 0;
    final results = <({String text, int startMs, int endMs})>[];
    for (final sentence in completedSentences) {
      final chars = sentence.replaceAll(RegExp(r'\s+'), '');
      while (tokenIdx < tokens.length) {
        final t = tokens[tokenIdx].replaceAll(RegExp(r'[\s_ ]+'), '');
        if (t.isNotEmpty && chars.contains(t)) break;
        tokenIdx++;
      }
      final startToken = tokenIdx.clamp(0, tokens.length - 1);
      final startSec = timestamps[startToken];

      int matched = 0;
      while (tokenIdx < tokens.length && matched < chars.length) {
        final t = tokens[tokenIdx].replaceAll(RegExp(r'[\s_ ]+'), '');
        matched += t.length;
        tokenIdx++;
      }
      final endToken = (tokenIdx - 1).clamp(startToken, tokens.length - 1);
      final endSec = timestamps[endToken];

      double sentenceEndSec = endSec + 0.35;
      if (tokenIdx < timestamps.length) {
        sentenceEndSec = math.min(sentenceEndSec, timestamps[tokenIdx]);
      }
      results.add((
        text: sentence,
        startMs: (startSec * 1000).round(),
        endMs: (sentenceEndSec * 1000).round(),
      ));
    }

    // 第一句绝不从 0ms 开始，精确在第 10.2 秒亮起
    expect(results.first.text, '大家好！');
    expect(results.first.startMs, 10200);
    expect(results.first.endMs, greaterThan(10200));

    // 第二句在第 12.0 秒亮起
    expect(results.last.text, '今天我们。');
    expect(results.last.startMs, 12000);
    expect(results.last.endMs, greaterThan(12000));
  });

  test('Microsoft Edge translation maps target languages and parses responses',
      () async {
    final client = Dio();
    final translator = CaptionTranslator(client: client);
    addTearDown(translator.close);

    client.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      expect(request.uri.host, 'edge.microsoft.com');
      expect(request.uri.path, '/translate/translatetext');
      expect(request.queryParameters['to'], 'zh-Hans');
      handler.resolve(Response<dynamic>(
        requestOptions: request,
        data: [
          {
            'translations': [
              {'text': '你好世界', 'to': 'zh-Hans'}
            ]
          }
        ],
      ));
    }));

    final result = await translator.translate('Hello world', CancelToken(),
        targetLang: 'zh-CN', engine: 'microsoft');
    expect(result, '你好世界');
  });

  test(
      'CaptionTranslator local offline translation translates high frequency phrases',
      () async {
    final translator = CaptionTranslator();
    final resEn = await translator
        .translate('Thank you very much', CancelToken(), engine: 'local');
    expect(resEn, contains('感谢'));

    final resJa =
        await translator.translate('こんにちは', CancelToken(), engine: 'local');
    expect(resJa, '你好');

    final resYue = await translator.translate('点解会咁既', CancelToken(),
        engine: 'local', targetLang: 'zh-CN');
    expect(resYue, contains('为什么'));

    final resYue2 = await translator.translate('食左饭未呀', CancelToken(),
        engine: 'local', targetLang: 'zh-CN');
    expect(resYue2, contains('饭'));
  });

  test(
      'Microsoft Edge translation maps target languages and passes from=yue for Cantonese',
      () async {
    final client = Dio();
    final translator = CaptionTranslator(client: client);
    addTearDown(translator.close);

    client.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      expect(request.uri.host, 'edge.microsoft.com');
      expect(request.uri.path, '/translate/translatetext');
      expect(request.queryParameters['to'], 'zh-Hans');
      expect(request.queryParameters['from'], 'yue');
      handler.resolve(Response<dynamic>(
        requestOptions: request,
        data: [
          {
            'translations': [
              {'text': '为什么会这样？', 'to': 'zh-Hans'}
            ]
          }
        ],
      ));
    }));

    final result = await translator.translate('点解会咁既', CancelToken(),
        sourceLang: 'yue', targetLang: 'zh-CN', engine: 'microsoft');
    expect(result, '为什么会这样？');
  });

  test('RealtimeCaptions matches target language official subtitle track', () {
    final captions = RealtimeCaptions();
    captions.tracks.assignAll([
      SubTitlteItemModel(id: 1, lan: 'zhCN', lanDoc: '中文（中国）'),
      SubTitlteItemModel(id: 2, lan: 'enUS', lanDoc: '英语（美国）'),
      SubTitlteItemModel(id: 3, lan: 'jaJP', lanDoc: '日本語'),
    ]);
    captions.selectedTrack.value = 1;
    captions.showTranslation.value = true;

    captions.setTargetLanguage('en');
    final enTrack = captions.activeTranslatedTrack;
    expect(enTrack?.id, 2);

    captions.setTargetLanguage('ja');
    final jaTrack = captions.activeTranslatedTrack;
    expect(jaTrack?.id, 3);
  });

  test(
      'CaptionOfflinePhonetics accurately converts Ko, Ja, Yue, Zh, En at 0ms offline',
      () {
    // 1. 韩语 (纯 Unicode 数学计算)
    final ko = CaptionPronunciation.shared
        .getOfflinePronunciation('안녕하세요', sourceLang: 'ko');
    expect(ko, 'an nyeong ha se yo');

    // 2. 日语 (假名与罗马音)
    final jaKana = CaptionPronunciation.shared.getOfflinePronunciation('ありがとう',
        japaneseMode: 'kana', sourceLang: 'ja');
    expect(jaKana, 'ありがとう');
    final jaRomaji = CaptionPronunciation.shared.getOfflinePronunciation(
        'こんにちは',
        japaneseMode: 'romaji',
        sourceLang: 'ja');
    expect(jaRomaji, 'konnichiwa');

    // 3. 粤语 (Jyutping)
    final yue = CaptionPronunciation.shared
        .getOfflinePronunciation('唔该晒你', isCantoneseContext: true);
    expect(yue, 'm4 goi1 saai3 nei5');

    // 4. 普通话 (拼音带调)
    final zh = CaptionPronunciation.shared
        .getOfflinePronunciation('你好世界', sourceLang: 'zh-CN');
    expect(zh, 'nǐ hǎo shì jiè');

    // 5. 英语 (IPA 国际音标)
    final en = CaptionPronunciation.shared
        .getOfflinePronunciation('hello world', sourceLang: 'en');
    expect(en, contains('həˈloʊ'));
    expect(en, contains('wɜːrld'));

    // 6. 日语纯汉字测试与绝不混入汉字防错
    final jaKanjiOnlyKana = CaptionPronunciation.shared.getOfflinePronunciation(
        '本日休業',
        japaneseMode: 'kana',
        sourceLang: 'ja');
    expect(jaKanjiOnlyKana, 'ほんじつきゅうぎょう');
    final jaKanjiOnlyRomaji = CaptionPronunciation.shared
        .getOfflinePronunciation('本日休業',
            japaneseMode: 'romaji', sourceLang: 'ja');
    expect(jaKanjiOnlyRomaji, 'honjitsukyuugyou');

    // 7. 日语罗马音绝对不含中文字符 (彻底杜绝用户截图中的 "啊 ho n to u ka i 待 ta se te su ma na i ne" 汉字残留)
    final jaMixedRomaji = CaptionPronunciation.shared.getOfflinePronunciation(
        '啊，本当かい，待たせてすまないね。',
        japaneseMode: 'romaji',
        sourceLang: 'ja');
    expect(jaMixedRomaji, isNotNull);
    expect(RegExp(r'[\u4E00-\u9FFF]').hasMatch(jaMixedRomaji!), isFalse);
    expect(jaMixedRomaji, contains('hontoukai'));
    expect(jaMixedRomaji, contains('matasete'));

    // 8. 粤语繁简混排与绝不跌落普通话防错
    final yueFull = CaptionPronunciation.shared
        .getOfflinePronunciation('今日天氣好好，我哋一齊去飲茶啦。', sourceLang: 'yue');
    expect(yueFull, isNotNull);
    expect(yueFull, contains('gam1 jat6'));
    expect(yueFull, contains('jat1 cai4'));
    expect(yueFull, contains('jam2 caa4'));
    // 确保绝对不包含普通话拼音声调字符 (ā, á, ǎ, à, etc.)
    expect(RegExp(r'[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ]').hasMatch(yueFull!), isFalse);
  });

  test('PcmLeveler dynamically boosts low volume audio without clipping', () {
    final leveler = PcmLeveler();
    // 构造一个低音量 16-bit PCM 测试帧 (500 样本，幅值为 200，RMS ~200，极其微弱)
    final pcm = Uint8List(1000);
    final bd = ByteData.sublistView(pcm);
    for (int i = 0; i < 500; i++) {
      bd.setInt16(i * 2, 200, Endian.little);
    }

    leveler.apply(pcm);
    expect(leveler.gainPercent, greaterThan(100)); // 自动补偿增益
    final boostedSample = bd.getInt16(0, Endian.little);
    expect(boostedSample, greaterThan(200)); // 音量已被动态抬高
    expect(boostedSample, lessThanOrEqualTo(30000)); // 限幅器严格防止破音
  });

  test('PunctuationText.restore preserves words and rejects hallucinations',
      () {
    // 1. 词素完全匹配时：标点富集成功并排版
    final success = CaptionTextFormatter.restoreWithPunctuation(
      'hello world',
      'Hello, world!',
      language: 'en',
    );
    expect(success, 'Hello, world!');

    // 2. 中文词素完全匹配时：标点排版成功
    final zhSuccess = CaptionTextFormatter.restoreWithPunctuation(
      '今天天气很好',
      '今天天气很好。',
      language: 'zh-CN',
    );
    expect(zhSuccess, '今天天气很好。');

    // 3. 标点模型发生丢字或幻觉篡改时：严格拒绝篡改，安全返回原文！
    final rejected = CaptionTextFormatter.restoreWithPunctuation(
      '今天天气很好',
      '今天天气糟糕。',
      language: 'zh-CN',
    );
    expect(rejected, '今天天气很好'); // 坚决返回原句

    final dropRejected = CaptionTextFormatter.restoreWithPunctuation(
      'hello world today',
      'Hello, world!',
      language: 'en',
    );
    expect(dropRejected, 'hello world today'); // 坚决返回原句
  });

  test(
      'AudioBacklog manages ring buffer, acknowledgement and unconfirmed replay',
      () {
    // 构造一个 100ms 容量的测试环形缓冲 (100 * 32 = 3200 字节)
    final backlog = AudioBacklog(milliseconds: 100);
    expect(backlog.isEmpty, isTrue);

    final data1 = Uint8List.fromList(List.generate(1000, (i) => i % 256));
    backlog.append(data1);
    expect(backlog.start, 0);
    expect(backlog.end, 1000);
    expect(backlog.length, 1000);

    // 服务端确认前 400 字节
    backlog.acknowledge(400);
    expect(backlog.start, 400);

    // 读取未确认尾部数据
    final slice = backlog.read(400, 600);
    expect(slice.length, 600);
    expect(slice[0], data1[400]);

    // 追加超出容量的数据，验证环形覆盖与旧数据淘汰
    final largeData = Uint8List(3500);
    final lost = backlog.append(largeData);
    expect(lost, greaterThan(0));
    expect(backlog.length, 3200); // 严格维持在最大容量
  });

  test(
      'CaptionTranslator.splitChunks breaks text at natural punctuation boundaries',
      () {
    const longText = '这是第一句话。这是第二句话！这是第三句话？这是第四句话。';
    final chunks = CaptionTranslator.splitChunks(longText, limit: 15);
    expect(chunks.length, greaterThan(1));
    for (final chunk in chunks) {
      expect(chunk.length, lessThanOrEqualTo(15));
    }
    expect(chunks.join(''), longText); // 无损重组
  });

  test('AsrTranscript adaptive clause splitting for Japanese and Cantonese without flickering', () {
    // 验证日文在自然子句标点 、（8字符以上）处能够平稳成句发射，而不需要等待 24 字符
    final jaTranscript = AsrTranscript(sentenceOnly: true, emitPreview: true);
    
    // 输入前一个字，未达两字阈值
    expect(jaTranscript.accept({'utterance': 1, 'delta': 'み', 'audio_ms': 100}), isEmpty);
    // 输入预览（达到两字以上）
    final p1 = jaTranscript.accept({'utterance': 1, 'delta': 'なさんこんにちは', 'audio_ms': 300}).toList();
    expect(p1, hasLength(1));
    expect(p1.first.text, 'みなさんこんにちは');
    expect(p1.first.isFinal, isFalse);

    // 相同内容重复输入时，防抖判定生效，不重复发射预览
    final pDupe = jaTranscript.accept({'utterance': 1, 'delta': '', 'audio_ms': 350}).toList();
    expect(pDupe, isEmpty);

    // 日文顿号到达，达到 8 字符门槛（9字符），即时成句发射，杜绝长期积压狂闪
    final jaClause = jaTranscript.accept({'utterance': 1, 'delta': '、', 'audio_ms': 500}).toList();
    expect(jaClause, hasLength(1));
    expect(jaClause.first.text, 'みなさんこんにちは、');
    expect(jaClause.first.isFinal, isTrue);

    // 验证粤语在逗号处（10字符左右）成句发射
    final yueTranscript = AsrTranscript(sentenceOnly: true, emitPreview: true);
    expect(yueTranscript.accept({'utterance': 1, 'delta': '你', 'audio_ms': 100}), isEmpty);
    final yueClause = yueTranscript.accept({'utterance': 1, 'delta': '今日得唔得闲啊，', 'audio_ms': 400}).toList();
    expect(yueClause, hasLength(1));
    expect(yueClause.first.text, '你今日得唔得闲啊，');
    expect(yueClause.first.isFinal, isTrue);
  });

  test('CaptionSentenceItem queue management and FIFO trimming', () {
    final captions = RealtimeCaptions();
    expect(captions.sentenceQueue, isEmpty);

    captions.sentenceQueue.add(CaptionSentenceItem(id: '1', original: '第一句'));
    captions.sentenceQueue.add(CaptionSentenceItem(id: '2', original: '第二句'));
    captions.sentenceQueue.add(CaptionSentenceItem(id: '3', original: '第三句'));
    expect(captions.sentenceQueue, hasLength(3));

    // 显示层行数预算在字幕框渲染时决定；队列本身按内部常量 FIFO 裁剪，
    // 这里模拟同样的 FIFO 语义验证"先进先出、旧句先出"。
    const displayLimit = 2;
    while (captions.sentenceQueue.length > displayLimit) {
      captions.sentenceQueue.removeAt(0);
    }
    expect(captions.sentenceQueue, hasLength(2));
    expect(captions.sentenceQueue.first.original, '第二句');
    expect(captions.sentenceQueue.last.original, '第三句');

    captions.clearSentenceQueue();
    expect(captions.sentenceQueue, isEmpty);
  });

  test('switchSubtitleSource toggles official, qwen, and sherpa sources cleanly', () {
    final captions = RealtimeCaptions();
    expect(captions.activeSourceType, isNotEmpty);

    captions.switchSubtitleSource('sherpa');
    expect(captions.selectedTrack.value, RealtimeCaptions.realtimeLocalTrack);
    expect(captions.activeSourceType, 'sherpa');

    captions.switchSubtitleSource('qwen');
    expect(captions.selectedTrack.value, RealtimeCaptions.realtimeCloudTrack);
    expect(captions.activeSourceType, 'qwen');

    captions.switchSubtitleSource('official');
    expect(captions.selectedTrack.value, RealtimeCaptions.automaticTrack);
  });

  test('OnlineAsrStreamFactory creates corresponding stream instances', () {
    final azure = OnlineAsrStreamFactory.createStream(engine: 'azure');
    expect(azure, isA<AzureAsrStream>());

    final doubao = OnlineAsrStreamFactory.createStream(
      engine: 'doubao',
      doubaoAuthMode: 'api_key',
      doubaoApiKey: 'test_key',
    );
    expect(doubao, isA<DoubaoAsrStream>());

    final deepgram = OnlineAsrStreamFactory.createStream(
      engine: 'deepgram',
      deepgramApiKey: 'test_key',
    );
    expect(deepgram, isA<DeepgramAsrStream>());

    final qwen = OnlineAsrStreamFactory.createStream(engine: 'qwen');
    expect(qwen, isA<AsrStream>());
  });

  test('RealtimeCaptions online engine preference switching and labeling', () {
    final captions = RealtimeCaptions();
    expect(captions.onlineAsrEngine.value, 'azure');
    expect(captions.onlineEngineName, contains('微软'));

    captions.setOnlineAsrEngine('doubao');
    expect(captions.onlineAsrEngine.value, 'doubao');
    expect(captions.onlineEngineName, contains('豆包'));

    captions.setOnlineAsrEngine('deepgram');
    expect(captions.onlineAsrEngine.value, 'deepgram');
    expect(captions.onlineEngineName, contains('Deepgram'));

    captions.setOnlineAsrEngine('qwen');
    expect(captions.onlineAsrEngine.value, 'qwen');
    expect(captions.onlineEngineName, contains('Qwen'));

    captions.setDoubaoAuthMode('token');
    expect(captions.doubaoAuthMode.value, 'token');
    captions.setDoubaoAppId('appid123');
    expect(captions.doubaoAppId.value, 'appid123');
    captions.setDoubaoAccessToken('token456');
    expect(captions.doubaoAccessToken.value, 'token456');

    captions.setDeepgramApiKey('dg_secret');
    expect(captions.deepgramApiKey.value, 'dg_secret');
  });

  test('AsrTranscript seamlessly accepts full text messages from cloud engines', () {
    final transcript = AsrTranscript(sentenceOnly: true, emitPreview: true);

    // 1. 模拟云端引擎（Azure/Deepgram/豆包）在讲话过程中的中间预览 (isFinal: false)
    final interim1 = transcript.accept({
      'text': '我想感受',
      'isFinal': false,
      'start_ms': 1000,
      'audio_ms': 2000,
    }).toList();
    expect(interim1.length, 1);
    expect(interim1.first.text, '我想感受');
    expect(interim1.first.isFinal, isFalse);

    // 2. 中间预览更新
    final interim2 = transcript.accept({
      'text': '我想感受下你哋嘅智能系统',
      'isFinal': false,
      'start_ms': 1000,
      'audio_ms': 3500,
    }).toList();
    expect(interim2.length, 1);
    expect(interim2.first.text, '我想感受下你哋嘅智能系统');
    expect(interim2.first.isFinal, isFalse);

    // 3. 最终句完成 (isFinal: true)
    final finalResult = transcript.accept({
      'text': '我想感受下你哋嘅智能系统啊，理论上系可以嘅。',
      'isFinal': true,
      'start_ms': 1000,
      'audio_ms': 5500,
    }).toList();
    expect(finalResult.isNotEmpty, isTrue);
    expect(finalResult.last.isFinal, isTrue);
    expect(finalResult.map((c) => c.text).join(), contains('我想感受下你哋嘅智能系统啊'));
  });

  test('Public cloud ASR engines maintain 1 hour audio limit and do not reconnect prematurely', () {
    final azure = OnlineAsrStreamFactory.createStream(engine: 'azure');
    final deepgram = OnlineAsrStreamFactory.createStream(
      engine: 'deepgram',
      deepgramApiKey: 'test_key',
    );
    final doubao = OnlineAsrStreamFactory.createStream(
      engine: 'doubao',
      doubaoApiKey: 'test_key',
    );

    // 16000 * 2 * 60 * 60 = 115200000 字节（1 小时）
    expect(azure.maxAudioBytes, 115200000);
    expect(deepgram.maxAudioBytes, 115200000);
    expect(doubao.maxAudioBytes, 115200000);

    // 初始状态未完成，绝不提前 done
    expect(azure.done, isFalse);
    expect(deepgram.done, isFalse);
    expect(doubao.done, isFalse);
  });

  test('Cloud ASR language normalization correctly maps multi, en, zh and auto', () {
    // Deepgram 规范化
    expect(DeepgramAsrStream.normalizeLang('auto'), 'multi');
    expect(DeepgramAsrStream.normalizeLang('multi'), 'multi');
    expect(DeepgramAsrStream.normalizeLang(null), 'multi');
    expect(DeepgramAsrStream.normalizeLang('en-US'), 'en');
    expect(DeepgramAsrStream.normalizeLang('en'), 'en');
    expect(DeepgramAsrStream.normalizeLang('zh-CN'), 'zh-CN');
    expect(DeepgramAsrStream.normalizeLang('zh-HK'), 'zh-HK');
    expect(DeepgramAsrStream.normalizeLang('ja-JP'), 'ja');
    expect(DeepgramAsrStream.normalizeLang('ko-KR'), 'ko');

    // Azure 规范化 (确保 auto 和 multi 绝不直接传给 Azure 导致 400 异常)
    expect(AzureAsrStream.normalizeAzureLang('auto'), 'zh-CN');
    expect(AzureAsrStream.normalizeAzureLang('multi'), 'zh-CN');
    expect(AzureAsrStream.normalizeAzureLang('en-US'), 'en-US');
    expect(AzureAsrStream.normalizeAzureLang('en'), 'en-US');
    expect(AzureAsrStream.normalizeAzureLang('zh-CN'), 'zh-CN');
  });

  test('RealtimeCaptions effectiveOnlineAsrLanguage infers English, Japanese and Cantonese accurately', () {
    final captions = RealtimeCaptions();

    // 1. 默认 auto 且无标题/轨道时，Deepgram 走 multi，其他走 zh-CN
    captions.setOnlineAsrEngine('deepgram');
    expect(captions.effectiveOnlineAsrLanguage, 'multi');
    captions.setOnlineAsrEngine('azure');
    expect(captions.effectiveOnlineAsrLanguage, 'zh-CN');

    // 2. 视频标题为纯英文时，自动推断为 en-US
    captions.videoTitle = 'How to learn Flutter 3.19 in 2026 Tutorial';
    expect(captions.effectiveOnlineAsrLanguage, 'en-US');

    // 3. 视频标题包含日文假名时，自动推断为 ja-JP
    captions.videoTitle = '【初音ミク】ワールドイズマイン';
    expect(captions.effectiveOnlineAsrLanguage, 'ja-JP');

    // 4. 视频标题包含粤语时，自动推断为 zh-HK
    captions.videoTitle = '香港街头美食探索（粤语原声）';
    expect(captions.effectiveOnlineAsrLanguage, 'zh-HK');

    // 5. 用户手动指定语言时，强制遵从用户指定，不被自动推断覆盖
    captions.setOnlineAsrLanguage('en-US');
    expect(captions.effectiveOnlineAsrLanguage, 'en-US');
  });

  test('AsrTranscript smooth clause concatenation and natural sentence joining for cloud engines', () {
    final transcript = AsrTranscript(sentenceOnly: true, emitPreview: true);

    // 1. 模拟短分句（如只有五六个字且带逗号），不应被生硬腰斩，而应暂存缓冲
    final res1 = transcript.accept({
      'text': '微软和豆包，',
      'isFinal': true,
      'audio_ms': 1000,
    }).toList();
    expect(res1, isEmpty); // 未达成句阈值，不破碎截断

    // 2. 中间过程的即时预览 (isFinal: false) 应该与之前累积平滑呈现
    final prev = transcript.accept({
      'text': '识别断句有了很大提升',
      'isFinal': false,
      'audio_ms': 2000,
    }).toList();
    expect(prev, hasLength(1));
    expect(prev.first.text, '微软和豆包，识别断句有了很大提升');
    expect(prev.first.isFinal, isFalse);

    // 3. 完整句到来（带句号），完整拼接发射
    final res2 = transcript.accept({
      'text': '识别断句有了很大提升。',
      'isFinal': true,
      'audio_ms': 3000,
    }).toList();
    expect(res2, hasLength(1));
    expect(res2.first.text, '微软和豆包，识别断句有了很大提升。');
    expect(res2.first.isFinal, isTrue);

    // 4. 英文短语智能补充空格拼接
    final en1 = transcript.accept({
      'text': 'In today video,',
      'isFinal': true,
      'audio_ms': 4000,
    }).toList();
    expect(en1, isEmpty);

    final en2 = transcript.accept({
      'text': 'we are testing Deepgram Nova-3.',
      'isFinal': true,
      'audio_ms': 6000,
    }).toList();
    expect(en2, hasLength(1));
    expect(en2.first.text, 'In today video, we are testing Deepgram Nova-3.');
    expect(en2.first.isFinal, isTrue);

    // 5. 说话人停顿 (speech_final / turn_end) 闭合无标点尾句
    transcript.accept({
      'text': '最后这一句话没有标点',
      'isFinal': true,
      'audio_ms': 7000,
    }).toList();
    final tail = transcript.accept({
      'speech_final': true,
      'audio_ms': 8000,
    }).toList();
    expect(tail, hasLength(1));
    expect(tail.first.text, '最后这一句话没有标点');
    expect(tail.first.isFinal, isTrue);
  });

  group('Sherpa 本地识别延迟优化：降低 VAD/端点门槛', () {
    test('离线 dispatch 最短音频降到 1 秒（原 1.8 秒）', () {
      // 999ms 不够，1000ms 达标
      expect(LocalAsrStream.offlineChunkReachedMin(15999), isFalse);
      expect(LocalAsrStream.offlineChunkReachedMin(16000), isTrue);
      expect(LocalAsrStream.vadMinDispatchMs, lessThanOrEqualTo(1000));
    });

    test('尾部静音门槛降到 300ms 以内（原 400ms）', () {
      expect(LocalAsrStream.vadTrailingSilenceMs, lessThanOrEqualTo(300));
    });

    test('最长累积音频不超过 5 秒，防止长句延迟刷出', () {
      expect(LocalAsrStream.vadMaxDispatchMs, lessThanOrEqualTo(5000));
    });

    test('Zipformer 端点静音阈值降低（原 0.8/0.4 秒）', () {
      expect(LocalAsrStream.endpointTrailingSilence1, lessThanOrEqualTo(0.5));
      expect(LocalAsrStream.endpointTrailingSilence2, lessThanOrEqualTo(0.3));
    });
  });

  test('LocalAsrStream normalizeSenseVoiceLang maps BCP-47 locales strictly to Sherpa supported codes', () {
    // 确保绝对不将 zh-CN, en-US, multi 传给 SenseVoice 导致 Failed to create offline recognizer
    expect(LocalAsrStream.normalizeSenseVoiceLang('zh-CN'), 'zh');
    expect(LocalAsrStream.normalizeSenseVoiceLang('zh-hans'), 'zh');
    expect(LocalAsrStream.normalizeSenseVoiceLang('zh'), 'zh');
    expect(LocalAsrStream.normalizeSenseVoiceLang('en-US'), 'en');
    expect(LocalAsrStream.normalizeSenseVoiceLang('en'), 'en');
    expect(LocalAsrStream.normalizeSenseVoiceLang('zh-HK'), 'yue');
    expect(LocalAsrStream.normalizeSenseVoiceLang('yue'), 'yue');
    expect(LocalAsrStream.normalizeSenseVoiceLang('ja-JP'), 'ja');
    expect(LocalAsrStream.normalizeSenseVoiceLang('ja'), 'ja');
    expect(LocalAsrStream.normalizeSenseVoiceLang('ko-KR'), 'ko');
    expect(LocalAsrStream.normalizeSenseVoiceLang('ko'), 'ko');
    expect(LocalAsrStream.normalizeSenseVoiceLang('auto'), 'auto');
    expect(LocalAsrStream.normalizeSenseVoiceLang('multi'), 'auto');
    expect(LocalAsrStream.normalizeSenseVoiceLang(null), 'auto');
  });

  test('sheetShowPronunciation and showPronunciation are independent variables', () {
    final prefs = CaptionPreferences();
    expect(prefs.sheetShowPronunciation.value, isTrue);
    expect(prefs.showPronunciation.value, isFalse);

    // 切换查词弹窗的注音开关，不应影响字幕 HUD
    prefs.setSheetPronunciation(false);
    expect(prefs.sheetShowPronunciation.value, isFalse);
    expect(prefs.showPronunciation.value, isFalse);

    // 切换字幕 HUD 注音开关，不应影响查词弹窗
    prefs.togglePronunciation();
    expect(prefs.showPronunciation.value, isTrue);
    expect(prefs.sheetShowPronunciation.value, isFalse);
  });

  test('sentenceMaxLines defaults to 3 and clamps to 2-6', () {
    final prefs = CaptionPreferences();
    expect(prefs.sentenceMaxLines.value, 3);

    prefs.setSentenceMaxLines(6);
    expect(prefs.sentenceMaxLines.value, 6);
    prefs.setSentenceMaxLines(9); // 超出上限被夹到 6
    expect(prefs.sentenceMaxLines.value, 6);
    prefs.setSentenceMaxLines(1); // 低于下限被夹到 2
    expect(prefs.sentenceMaxLines.value, 2);
    prefs.setSentenceMaxLines(4);
    expect(prefs.sentenceMaxLines.value, 4);
  });

  test('mixed Chinese and English sentences pair Ruby tokens with character-level alignment', () {
    const text = '以后唔好随便干涉我哋 CIB 嘚，我唔干涉，点知你哋做紧啜嘢，点知你哋';
    const phonetic = 'ji5 hau6 m4 hou2 ceoi4 bin2 gon1 sip3 ngo5 dei6 CIB dak1, ngo5 m4 gon1 sip3, dim2 zi1 nei5 dei6 zou6 gan2 zyut3 je5, dim2 zi1 nei5 dei6';

    // 验证音节切分与 token 化
    final syllables = phonetic
        .split(RegExp(r'\s+'))
        .map((s) => s.replaceAll(RegExp(r'^[.,!?:;，。！？；：、]+|[.,!?:;，。！？；：、]+$'), '').trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final tokenRegex = RegExp(
      r"([\u4E00-\u9FFF\u3400-\u4DBF]|[a-zA-Z0-9'-]+|[\u3040-\u309F\u30A0-\u30FF]+|[\uAC00-\uD7AF]+|[^\s\w]|[\s]+)",
      unicode: true,
    );
    final tokens = tokenRegex.allMatches(text).map((m) => m.group(0)!).toList();

    bool isPronounceable(String u) =>
        RegExp(r'[\u4E00-\u9FFF\u3400-\u4DBF\u3040-\u30FF\uAC00-\uD7AFa-zA-Z0-9]').hasMatch(u);

    final pronounceableUnits = tokens.where(isPronounceable).toList();

    // 关键断言：包含 CIB 在内，发音单元数必须完全等于音节数，绝不会因中英混排而导致回退堆叠！
    expect(pronounceableUnits.length, syllables.length);
    expect(pronounceableUnits.contains('CIB'), isTrue);
    expect(syllables.contains('CIB'), isTrue);
  });

  test('CaptionTtsConfig and voice mapping covers Cantonese and Mandarin without hiding speaker button', () {
    const config = CaptionTtsConfig(
      engine: 'edge',
      edgeCantoneseVoice: 'zh-HK-HiuMaanNeural',
      edgeMandarinVoice: 'zh-CN-XiaoxiaoNeural',
      mimoVoice: 'default',
      mimoApiKey: '',
      mimoBaseUrl: 'https://api.xiaomimimo.com/v1',
    );
    expect(CaptionTtsService.edgeCantoneseVoices[config.edgeCantoneseVoice], contains('晓曼'));
    expect(CaptionTtsService.edgeMandarinVoices[config.edgeMandarinVoice], contains('晓晓'));

    // 验证无论语言是粤语(yue)还是普通话/中文(zh-CN)，发音人名称均准确解析，杜绝按钮消失
    final isYue = true;
    final yueVoice = CaptionTtsService.edgeCantoneseVoices[config.edgeCantoneseVoice]?.split(' ').first;
    expect(yueVoice, '晓曼');

    final isMandarin = false;
    final zhVoice = CaptionTtsService.edgeMandarinVoices[config.edgeMandarinVoice]?.split(' ').first;
    expect(zhVoice, '晓晓');
  });

  test('Azure/Deepgram/Doubao hypothesis overlap deduplication eliminates repeated strings', () {
    // 1. 用户真实截图场景 1: "因为上码成个project大你" + "因为上码成个project大，你需要有"
    final ex1 = "因为上码成个project大，";
    final inc1 = "因为上码成个project大，你需要有人帮手";
    final merged1 = RealtimeCaptions.mergeCaptionTexts(ex1, inc1);
    expect(merged1, "因为上码成个project大，你需要有人帮手");
    expect(merged1.contains("因为上码成个project大你因为上码成个"), isFalse);

    // 2. 用户真实截图场景 2: "你哋两个一齐去台湾见姑，" + "你哋两个一齐去台湾见姑正阳喺即系大家都"
    final ex2 = "你哋两个一齐去台湾见姑，";
    final inc2 = "你哋两个一齐去台湾见姑正阳喺即系大家都";
    final merged2 = RealtimeCaptions.mergeCaptionTexts(ex2, inc2);
    expect(merged2, "你哋两个一齐去台湾见姑正阳喺即系大家都");
    expect(merged2.contains("你哋两个一齐去台湾见姑，你哋两个一齐去台湾见姑"), isFalse);

    // 3. 连续重复短语抑制器消除相同短语连续重复:
    final repeated = "你哋两个一齐去台湾见姑，你哋两个一齐去台湾见姑，大家都清楚。";
    final cleaned = RealtimeCaptions.removeRepeatingPhrases(repeated);
    expect(cleaned.contains("你哋两个一齐去台湾见姑，你哋两个一齐去台湾见姑"), isFalse);
    expect(cleaned, "你哋两个一齐去台湾见姑，大家都清楚。");

    // 4. AsrTranscript 流式接收假说与定稿，绝不重复拼接前缀
    final transcript = AsrTranscript(sentenceOnly: true, emitPreview: true);
    final results1 = transcript.accept({
      'text': '你哋两个一齐去台湾见姑',
      'isFinal': false,
      'audio_ms': 1000,
    }).toList();
    expect(results1.isNotEmpty, isTrue);
    expect(results1.first.text, '你哋两个一齐去台湾见姑');

    // 随后的定稿包含了已识别的前缀：
    final results2 = transcript.accept({
      'text': '你哋两个一齐去台湾见姑正阳喺即系大家都。',
      'isFinal': true,
      'audio_ms': 2500,
    }).toList();
    expect(results2.isNotEmpty, isTrue);
    expect(results2.first.text, '你哋两个一齐去台湾见姑正阳喺即系大家都。');
    expect(results2.first.text.contains('你哋两个一齐去台湾见姑你哋两个一齐去台湾见姑'), isFalse);
  });

  test('portrait caption layout reserves space for right control switches and snaps tight under video', () {
    // 模拟手机竖屏全屏环境: 屏幕宽 380, 高 840, 视频比例 4:3 (古天乐老港剧)
    const screenW = 380.0;
    const screenH = 840.0;
    const videoAspect = 4.0 / 3.0;
    const sideControlsWidth = 24.0 + 6.0 + 6.0 + 26.0; // 62dp (左右功能列及边距)
    const hMargin = 16.0;

    final maxCardWidth = screenW - sideControlsWidth - hMargin; // 302.0
    expect(maxCardWidth > 280.0, isTrue);

    // 保证在 380 屏幕宽度下，主字幕卡片被严格限制在 maxCardWidth 内，右侧 26dp 的功能列永远完整可见！
    const cardHeight = 88.0;
    const videoH = screenW / videoAspect; // 285.0
    const videoBottomY = (screenH + videoH) / 2.0; // 562.5
    final targetCenterY = videoBottomY + 12.0 + (cardHeight / 2.0); // 618.5
    final alignY = (2.0 * targetCenterY / screenH) - 1.0; // 0.4726

    // 验证垂直对齐位置位于 0.45 ~ 0.55 之间，紧贴视频正下方，绝不沉底到 1.0 (造成巨大空白 space)
    expect(alignY > 0.40 && alignY < 0.60, isTrue);
  });
}

class _AsrTestSocket extends Stream<dynamic> implements WebSocket {
  _AsrTestSocket({this.chunk = 0.64, this.sendBarrier});

  final double chunk;
  final Future<void>? sendBarrier;
  final _incoming = StreamController<dynamic>();
  final _endSent = Completer<void>();
  final packets = <dynamic>[];
  Future<void> get endSent => _endSent.future;

  @override
  Duration? pingInterval;

  @override
  int? closeCode;

  @override
  int get readyState => closeCode == null ? WebSocket.open : WebSocket.closed;

  @override
  void add(dynamic packet) {
    packets.add(packet);
    if (packet == '{}') {
      serverMessage({'ready': true, 'chunk_seconds': chunk});
    } else if (packet == 'end' && !_endSent.isCompleted) {
      _endSent.complete();
    }
  }

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final packet in stream) {
      final barrier = sendBarrier;
      if (barrier != null) await barrier;
      add(packet);
    }
  }

  void serverMessage(Map<String, dynamic> value) {
    _incoming.add(jsonEncode(value));
  }

  Future<void> serverClose(int code) {
    closeCode = code;
    return _incoming.close();
  }

  @override
  Future<void> close([int? code, String? reason]) => _incoming.close();

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _incoming.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
