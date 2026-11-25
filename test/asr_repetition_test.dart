import 'package:flutter_test/flutter_test.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/asr_repetition.dart';
import 'package:pilipala/plugin/pl_player/realtime_caption/asr_stream.dart';

void main() {
  test(
      'screenshot loop, variable separators and suffix are preserved correctly',
      () {
    expect(suppressAsrShortLoops('前面，${List.filled(20, '我，').join()}後面。'),
        '前面，我，我，後面。');
    expect(suppressAsrShortLoops('我,我， 我、我；我 我,我， 我。正常。'), '我,我。正常。');
    expect(
        suppressAsrShortLoops('${List.filled(8, '唔知，').join()}繼續'), '唔知，唔知，繼續');
    expect(suppressAsrShortLoops(List.filled(8, '𠮩').join()), '𠮩𠮩');
  });

  test('ordinary stutters, emphasis, counting and separated words survive', () {
    for (final text in [
      '我，我覺得唔係。',
      '不不不，聽我講',
      '我不知道我不知道他在哪裡',
      'no no, I mean the other one',
      '一二三四五六七八',
      '我叫你，你叫我，我再叫你'
    ]) {
      expect(suppressAsrShortLoops(text), text);
    }
  });

  test(
      'direct and delta providers both guard a whole loop before sentence splitting',
      () {
    for (final sentenceOnly in [false, true]) {
      for (final key in ['text', 'delta']) {
        final transcript = AsrTranscript(sentenceOnly: sentenceOnly);
        final captions = transcript.accept({
          key: '${List.filled(20, '我，').join()}繼續。',
          'utterance': 1,
          'utterance_end': true,
          'audio_ms': 1000
        }).toList();
        final text = captions.map((c) => c.text).join();
        expect(text, contains('繼續'));
        expect('我'.allMatches(text).length, lessThanOrEqualTo(2));
      }
    }
  });

  test('repeated finalized short packets stop and normal speech resumes', () {
    final transcript = AsrTranscript();
    final output = <AsrCaption>[];
    for (var i = 0; i < 30; i++) {
      output.addAll(transcript
          .accept({'text': '我，', 'isFinal': true, 'audio_ms': i * 200}));
    }
    expect(output.length, 7);
    expect(
        transcript
            .accept({'text': '今次唔同。', 'isFinal': true, 'audio_ms': 6200})
            .single
            .text,
        '今次唔同。');
  });

  test('previews do not accumulate; a time gap and new stream reset repetition',
      () {
    final guard = AsrRepetitionGuard();
    for (var i = 0; i < 20; i++) {
      expect(guard.accept('我，', isFinal: false, audioMs: 100), '我，');
    }
    for (var i = 0; i < 8; i++) {
      guard.accept('我，', isFinal: true, audioMs: i * 100);
    }
    expect(guard.accept('我，', isFinal: true, audioMs: 900), isEmpty);
    expect(guard.accept('我。', isFinal: true, audioMs: 6000), '我。');
    expect(AsrRepetitionGuard().accept('我。', isFinal: true, audioMs: 0), '我。');
  });

  test(
      'a stream of tiny deltas cannot evade the guard through clause splitting',
      () {
    final transcript = AsrTranscript(sentenceOnly: true);
    final finals = <AsrCaption>[];
    for (var i = 0; i < 30; i++) {
      finals.addAll(transcript
          .accept({'utterance': 1, 'delta': '我，', 'audio_ms': 200 * i}).where(
              (c) => c.isFinal));
    }
    finals.addAll(transcript.accept({
      'utterance': 1,
      'delta': '我返嚟喇。',
      'utterance_end': true,
      'audio_ms': 6300
    }));
    final text = finals.map((c) => c.text).join();
    expect('我'.allMatches(text).length, lessThanOrEqualTo(8));
    expect(text, contains('我返嚟喇'));
    expect(transcript.finish(), isNull);
  });

  test(
      'edited loops discard stale word offsets rather than shifting the suffix',
      () {
    final transcript = AsrTranscript();
    final caption = transcript.accept({
      'text': '${List.filled(20, '我，').join()}走。',
      'isFinal': true,
      'start_ms': 100,
      'audio_ms': 2200,
      'words': [
        for (var i = 0; i < 20; i++)
          {'text': '我', 'start_ms': i * 100, 'end_ms': i * 100 + 100}
      ]
    }).single;
    expect(caption.text, '我，我，走。');
    expect(caption.words, isEmpty);
    expect(caption.audioMs, 2200);
  });
}
