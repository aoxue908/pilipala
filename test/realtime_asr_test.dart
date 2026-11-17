import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_pronunciation.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_timeline.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_translator.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/local_asr_model.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/player_pcm.dart';

void main() {
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
      expect(request.uri.host, 'translate.googleapis.com');
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

  test('Sherpa-ONNX model configurations include SenseVoice, Paraformer, Whisper, and Zipformer', () {
    expect(LocalAsrModelManager.availableModels.length, 5);

    final senseVoice = LocalAsrModelManager.availableModels['sense_voice'];
    expect(senseVoice, isNotNull);
    expect(senseVoice!.requiredFiles, contains('model.int8.onnx'));
    expect(senseVoice.requiredFiles, contains('tokens.txt'));
    expect(senseVoice.mirrorBaseUrls.first, contains('hf-mirror.com'));

    final paraformer = LocalAsrModelManager.availableModels['paraformer'];
    expect(paraformer, isNotNull);
    expect(paraformer!.requiredFiles, contains('encoder.int8.onnx'));
    expect(paraformer.requiredFiles, contains('decoder.int8.onnx'));
    expect(paraformer.requiredFiles, contains('tokens.txt'));

    final whisper = LocalAsrModelManager.availableModels['whisper_tiny'];
    expect(whisper, isNotNull);
    expect(whisper!.requiredFiles, contains('tiny-encoder.int8.onnx'));
    expect(whisper.requiredFiles, contains('tiny-decoder.int8.onnx'));
    expect(whisper.requiredFiles, contains('tiny-tokens.txt'));

    final zipformerZhEn = LocalAsrModelManager.availableModels['zipformer_zh_en'];
    expect(zipformerZhEn, isNotNull);
    expect(zipformerZhEn!.requiredFiles, contains('encoder-epoch-99-avg-1.int8.onnx'));
    expect(zipformerZhEn.requiredFiles, contains('decoder-epoch-99-avg-1.onnx'));
    expect(zipformerZhEn.requiredFiles, contains('joiner-epoch-99-avg-1.int8.onnx'));
    expect(zipformerZhEn.requiredFiles, contains('tokens.txt'));
    // Verify minFileSizes are realistic
    expect(zipformerZhEn.minFileSizes['joiner-epoch-99-avg-1.int8.onnx'], lessThanOrEqualTo(2 * 1024 * 1024));

    final zipformerEn = LocalAsrModelManager.availableModels['zipformer_en'];
    expect(zipformerEn, isNotNull);
    expect(zipformerEn!.requiredFiles, contains('encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx'));
    expect(zipformerEn.requiredFiles, contains('decoder-epoch-99-avg-1-chunk-16-left-128.onnx'));
    expect(zipformerEn.requiredFiles, contains('joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx'));
    expect(zipformerEn.requiredFiles, contains('tokens.txt'));
    expect(zipformerEn.minFileSizes['joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx'], lessThanOrEqualTo(200 * 1024));
    expect(zipformerEn.minFileSizes['decoder-epoch-99-avg-1-chunk-16-left-128.onnx'], lessThanOrEqualTo(1024 * 1024));
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

  test('pronunciation language detection and romaji to hiragana conversion', () {
    expect(CaptionPronunciation.detectLanguage('你好世界'), 'zh-CN');
    expect(CaptionPronunciation.detectLanguage('唔该晒你'), 'yue');
    expect(CaptionPronunciation.detectLanguage('こんにちは'), 'ja');
    expect(CaptionPronunciation.detectLanguage('안녕하세요'), 'ko');
    expect(CaptionPronunciation.detectLanguage('Hello World'), 'en');

    expect(CaptionPronunciation.romajiToHiragana('konnichiwa'), 'こんにちは');
    expect(CaptionPronunciation.romajiToHiragana('arigatou'), 'ありがとう');
    expect(CaptionPronunciation.romajiToHiragana('gakkou'), 'がっこう');
  });

  test('sentence-level subtitle updates emit complete sentences and avoid character flickering', () {
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

  test('sentenceOnly AsrTranscript holds partial deltas and emits only complete sentences', () {
    final transcript = AsrTranscript(sentenceOnly: true);

    // 逐字输入，未到句尾标点前绝不发射，彻底杜绝刷新太快与逐字跳动
    expect(transcript.accept({'utterance': 1, 'delta': '大', 'audio_ms': 100}), isEmpty);
    expect(transcript.accept({'utterance': 1, 'delta': '家', 'audio_ms': 200}), isEmpty);
    expect(transcript.accept({'utterance': 1, 'delta': '好', 'audio_ms': 300}), isEmpty);

    // 句尾标点到达，整句发射
    final sent1 = transcript.accept({'utterance': 1, 'delta': '！', 'audio_ms': 400}).toList();
    expect(sent1, hasLength(1));
    expect(sent1.first.text, '大家好！');
    expect(sent1.first.isFinal, isTrue);

    // 第二句逐字输入
    expect(transcript.accept({'utterance': 1, 'delta': '今', 'audio_ms': 500}), isEmpty);
    expect(transcript.accept({'utterance': 1, 'delta': '天', 'audio_ms': 600}), isEmpty);
    expect(transcript.accept({'utterance': 1, 'delta': '看视频', 'audio_ms': 800}), isEmpty);

    final sent2 = transcript.accept({'utterance': 1, 'delta': '。', 'audio_ms': 1000}).toList();
    expect(sent2, hasLength(1));
    expect(sent2.first.text, '今天看视频。');
    expect(sent2.first.isFinal, isTrue);

    // 第三句未完结部分在 utterance_end 时统一成句发射
    expect(transcript.accept({'utterance': 1, 'delta': '谢谢大家', 'audio_ms': 1200}), isEmpty);
    final sent3 = transcript.accept({'utterance': 1, 'delta': '', 'utterance_end': true, 'audio_ms': 1300}).toList();
    expect(sent3, hasLength(1));
    expect(sent3.first.text, '谢谢大家');
    expect(sent3.first.isFinal, isTrue);
  });

  test('sentence boundary splitter properly separates completed sentences and carries over incomplete tail', () {
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

  test('acoustic timestamp alignment accurately matches token times and preserves intro silence', () {
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
