import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/caption_timeline.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/cloud_asr_flow.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/local_asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/public_cloud_asr_stream.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/realtime_captions.dart';

Uint8List pcm(int milliseconds, {bool speech = false}) {
  final data = ByteData(milliseconds * 32);
  if (speech) {
    for (var i = 0; i < data.lengthInBytes; i += 2) {
      data.setInt16(i, 3000, Endian.little);
    }
  }
  return data.buffer.asUint8List();
}

void main() {
  Map<String, dynamic> message(String text, List<AsrWord> words,
          {bool isFinal = true, bool speechFinal = true}) =>
      {
        'text': text,
        'isFinal': isFinal,
        'speech_final': speechFinal,
        'start_ms': words.isEmpty ? 0 : words.first.startMs,
        'audio_ms': words.isEmpty ? 10000 : words.last.endMs,
        'words': words.map((word) => word.toJson()).toList(),
      };

  test('Deepgram 词时间贯穿分句和媒体时间轴，长停顿不被均分', () {
    final words = DeepgramAsrStream.normalizedWordTimings([
      {'word': 'hello', 'punctuated_word': 'Hello.', 'start': 0.0, 'end': 1.0},
      {
        'word': 'goodbye',
        'punctuated_word': 'Goodbye.',
        'start': 9.0,
        'end': 10.0
      },
    ]);
    final transcript = AsrTranscript(sentenceOnly: true);
    final captions = transcript.accept({
      'text': 'Hello. Goodbye.',
      'isFinal': true,
      'start_ms': 0,
      'audio_ms': 10000,
      'words': words,
    }).toList();
    expect(captions.map((c) => c.startAudioMs), [0, 9000]);
    expect(captions.map((c) => c.audioMs), [1000, 10000]);
    final timing = AsrCaptionTiming(40000);
    final timeline = CaptionTimeline([
      for (final caption in captions)
        ...timing.update(caption, sentMs: 10000, chunkMs: 100),
    ]);
    expect(timeline.atOrLatest(44000), isNull);
    expect(timeline.at(48999), isNull);
    expect(timeline.at(49000)?.text, 'Goodbye.');
    expect(timing.confirmedEndMs, 50000);
  });

  test('微软 tick 与豆包毫秒统一后都能保留真实句间停顿', () {
    final providers = [
      AzureAsrStream.normalizedWordTimings([
        {'Word': '你好', 'Offset': 1000000, 'Duration': 9000000},
        {'Word': '再见', 'Offset': 90000000, 'Duration': 10000000},
      ]),
      DoubaoAsrStream.normalizedWordTimings([
        {'text': '你好', 'start_time': 100, 'end_time': 1000},
        {'text': '再见', 'start_time': 9000, 'end_time': 10000},
      ]),
    ];
    for (final words in providers) {
      final captions = AsrTranscript(sentenceOnly: true).accept({
        'text': '你好！再见！',
        'isFinal': true,
        'start_ms': 0,
        'audio_ms': 10000,
        'words': words,
      }).toList();
      expect(captions.map((c) => c.startAudioMs), [100, 9000]);
      expect(captions.map((c) => c.audioMs), [1000, 10000]);
    }
    expect(
        AzureAsrStream.normalizedWordTimings([
          {'Word': '坏时间', 'Offset': double.infinity, 'Duration': 1000},
        ]),
        isEmpty);
    expect(
        DoubaoAsrStream.normalizedWordTimings([
          {'text': '坏时间', 'start_time': 1000, 'end_time': 0},
        ]),
        isEmpty);
  });

  test('显示层长句换行也使用词时间，不把后半句提前', () {
    const text = 'abcdefghijklmnopqrstuvwx secondwordwhichislongenough';
    final captions = AsrTranscript(sentenceOnly: true)
        .accept(message(text, [
          const AsrWord('abcdefghijklmnopqrstuvwx', 0, 1000),
          const AsrWord('secondwordwhichislongenough', 9000, 10000),
        ]))
        .toList();
    final timing = AsrCaptionTiming(0);
    final cues = [
      for (final c in captions) ...timing.update(c, sentMs: 10000, chunkMs: 100)
    ];
    expect(cues.map((c) => c.text).join(' '), text);
    expect(cues.length, 2);
    expect(cues.last.startMs, 9000);
    expect(cues.last.highlightAt(8999), 0);
    expect(cues.last.highlightAt(10000), cues.last.text.length);
  });

  test('跨服务分段保留尚未成句的词时间', () {
    final transcript = AsrTranscript(sentenceOnly: true);
    expect(
        transcript.accept(message(
            'Hello',
            [
              const AsrWord('Hello', 100, 1000),
            ],
            speechFinal: false)),
        isEmpty);
    final sentence = transcript
        .accept(message('world.', [
          const AsrWord('world', 2000, 3000),
        ]))
        .single;
    expect(sentence.text, 'Hello world.');
    expect(sentence.words.length, 2);
    expect(sentence.startAudioMs, 100);
    expect(sentence.audioMs, 3000);
  });

  test('文字未变也接收词时间修正，定稿替换预览', () {
    final transcript = AsrTranscript(sentenceOnly: true);
    transcript
        .accept(message('Hello', [const AsrWord('Hello', 100, 500)],
            isFinal: false, speechFinal: false))
        .toList();
    final revised = transcript
        .accept(message(
            'Hello',
            [
              const AsrWord('Hello', 200, 900),
            ],
            isFinal: false,
            speechFinal: false))
        .single;
    expect(revised.startAudioMs, 200);
    expect(revised.audioMs, 900);
    final finalCaption = transcript
        .accept(message('Hello.', [
          const AsrWord('Hello', 200, 1200),
        ]))
        .single;
    expect(finalCaption.audioMs, 1200);
    expect(finalCaption.words.single.startMs, 200);
  });

  test('重复词按出现顺序绑定，标点和大小写不改变时间', () {
    final captions = AsrTranscript(sentenceOnly: true)
        .accept(message(
          '你好！你好！',
          [const AsrWord('你好', 0, 500), const AsrWord('你好', 5000, 5500)],
        ))
        .toList();
    expect(captions.map((c) => c.startAudioMs), [0, 5000]);
    final words = alignAsrWords("We're here!", [
      const AsrWord("we're", 0, 500),
      const AsrWord('HERE', 700, 900),
    ]);
    expect(words.last.startOffset, 6);
    expect(words.last.endOffset, 10);
  });

  test('无效或不匹配的词时间回退估算，不丢正文', () {
    for (final invalid in [
      [
        {'word': 'hello', 'start': -1, 'end': 1}
      ],
      [
        {'word': 'hello', 'start': double.nan, 'end': 1}
      ],
      [
        {'word': 'hello', 'start': 2, 'end': 1}
      ],
      [
        {'word': 'hello', 'start': 2, 'end': 3},
        {'word': 'world', 'start': 0, 'end': 1}
      ],
    ]) {
      expect(DeepgramAsrStream.normalizedWordTimings(invalid), isEmpty);
    }
    final caption = AsrTranscript(sentenceOnly: true)
        .accept(message(
          'Keep every word.',
          [const AsrWord('unrelated', 0, 1000)],
        ))
        .single;
    expect(caption.text, 'Keep every word.');
    expect(caption.words, isEmpty);
    expect(AsrCaptionTiming(0).update(caption, sentMs: 10000, chunkMs: 640),
        isNotEmpty);
  });

  test('离线 token 的实际起点可以穿过分句，句号不吞下个 token', () {
    final words = LocalAsrStream.offlineWordTimings(
      tokens: ['▁Hello', '▁world', '▁Goodbye'],
      timestamps: [0.1, 0.8, 9.0],
      chunkAudioStartMs: 5000,
      totalDurationMs: 10000,
    );
    final aligned = alignAsrWords('Hello world.\nGoodbye.', words);
    expect(aligned.last.startMs, 14000);
    final captions = AsrTranscript(sentenceOnly: true)
        .accept(message(
          'Hello world. Goodbye.',
          words,
        ))
        .toList();
    expect(captions.last.text, 'Goodbye.');
    expect(captions.last.startAudioMs, 14000);
  });

  test('没有词时间且定稿文字不变时仍更新音频结束时间', () {
    final timing = AsrCaptionTiming(0);
    timing.update(const AsrCaption(0, 'Hello', false, audioMs: 500),
        sentMs: 500, chunkMs: 640);
    timing.update(const AsrCaption(0, 'Hello', true, audioMs: 3000),
        sentMs: 3000, chunkMs: 640);
    expect(timing.confirmedEndMs, 3000);
  });

  test('连续续接保留的音频采样与下一块时间原点一致', () {
    var origin = 0;
    var samples = List<int>.generate(80000, (i) => i);
    for (var cycle = 0; cycle < 20; cycle++) {
      final carryStart = LocalAsrStream.offlineCarryStart(
        sampleCount: samples.length,
        splitSampleIndex: 48000,
        hasIncompleteSentence: true,
      );
      final tail = samples.sublist(carryStart);
      origin += carryStart;
      expect(origin, tail.first);
      expect(origin / 16, tail.first / 16);
      samples = [...tail, ...List.generate(48000, (i) => tail.last + i + 1)];
    }
  });

  test('短音频回退不产生负时间，完整分段消费所有采样', () {
    expect(
        LocalAsrStream.offlineCarryStart(
          sampleCount: 16000,
          splitSampleIndex: 3200,
          hasIncompleteSentence: true,
        ),
        0);
    expect(
        LocalAsrStream.offlineCarryStart(
          sampleCount: 16000,
          splitSampleIndex: 3200,
          hasIncompleteSentence: false,
        ),
        16000);
  });

  test('识别进度不更新的长静音仍可发送，之后的语音也能进入识别', () {
    final speech = CaptionSpeech(10000)..add(pcm(1000, speech: true));
    final flow = CloudAsrFlow();
    for (var seconds = 1; seconds <= 60; seconds++) {
      speech.add(pcm(1000));
      final pending = speech.activeDuration(11000, 11000 + seconds * 1000);
      expect(pending, 0);
      expect(
          flow.needsReconnect(
              nowMs: seconds * 1000,
              processedMs: 1000,
              pendingSpeechMs: pending),
          isFalse);
      expect(
          RealtimeCaptions.cloudAdaptiveSendRate(
            baseRate: 1.15,
            pendingMs: pending,
            readyLeadMs: -60000,
          ),
          greaterThan(0));
    }
    speech.add(pcm(1000, speech: true));
    expect(speech.activeDuration(11000, 72000), 1000);
    expect(speech.activeDuration(72000, 11000), 0);
  });

  test('真实语音积压仍限流，停发后无进展会超时恢复', () {
    final speech = CaptionSpeech(0)..add(pcm(7000, speech: true));
    final pending = speech.activeDuration(0, 7000);
    expect(
        RealtimeCaptions.cloudAdaptiveSendRate(
          baseRate: 1.15,
          pendingMs: pending,
          readyLeadMs: 0,
        ),
        0);
    final flow = CloudAsrFlow();
    expect(
        flow.needsReconnect(nowMs: 0, processedMs: 0, pendingSpeechMs: pending),
        isFalse);
    expect(
        flow.needsReconnect(
            nowMs: 14999, processedMs: 0, pendingSpeechMs: pending),
        isFalse);
    expect(
        flow.needsReconnect(
            nowMs: 15000, processedMs: 0, pendingSpeechMs: pending),
        isTrue);
    expect(
        flow.needsReconnect(
            nowMs: 16000, processedMs: 500, pendingSpeechMs: 6500),
        isFalse);
    expect(
        flow.needsReconnect(
            nowMs: 30000, processedMs: 500, pendingSpeechMs: 6500),
        isFalse);
    expect(
        flow.needsReconnect(
            nowMs: 31000, processedMs: 1000, pendingSpeechMs: 6000),
        isFalse);
  });
}
