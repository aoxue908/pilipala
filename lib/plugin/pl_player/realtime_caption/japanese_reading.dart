import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'japanese_calendar_readings.dart';

class JapaneseReadingToken {
  const JapaneseReadingToken(this.text, this.reading, this.start);
  final String text;
  final String reading;
  final int start;
  int get end => start + text.length;
}

typedef JapaneseAnalyzer = Future<List<dynamic>?> Function(String text);

/// Sentence-keyed, bounded cache. Native dictionary initialization and Viterbi
/// analysis run on a dedicated worker; no subtitle text is sent to a server.
class JapaneseReadingService extends ChangeNotifier {
  JapaneseReadingService({JapaneseAnalyzer? analyze})
      : _analyze = analyze ?? _nativeAnalyze;
  static final shared = JapaneseReadingService();
  static const _channel = MethodChannel('pilipala/japanese_reading');
  final JapaneseAnalyzer _analyze;
  final _cache = <String, List<JapaneseReadingToken>>{};
  final _pending = <String, Future<List<JapaneseReadingToken>>>{};
  bool _unavailable = false;

  static Future<List<dynamic>?> _nativeAnalyze(String text) =>
      _channel.invokeListMethod<dynamic>('analyze', {'text': text});

  List<JapaneseReadingToken>? cached(String sentence) => _cache[sentence];

  Future<List<JapaneseReadingToken>> analyze(String sentence) {
    final cached = _cache[sentence];
    if (cached != null) return Future.value(cached);
    final pending = _pending[sentence];
    if (pending != null) return pending;
    if (_unavailable ||
        sentence.isEmpty ||
        sentence.length > 4096 ||
        _pending.length >= 4) {
      return Future.value(const []);
    }
    return _pending[sentence] ??= _load(sentence);
  }

  Future<List<JapaneseReadingToken>> _load(String sentence) async {
    List<JapaneseReadingToken> tokens = const [];
    try {
      tokens = parse(sentence,
          await _analyze(sentence).timeout(const Duration(seconds: 20)) ?? const []);
    } on MissingPluginException {
      _unavailable = true;
    } catch (_) {
      // Missing/invalid analysis stays unannotated; never fall back to arbitrary
      // per-character readings or guess an alignment from romanized text.
    } finally {
      _pending.remove(sentence);
    }
    _cache[sentence] = tokens;
    while (_cache.length > 256) {
      _cache.remove(_cache.keys.first);
    }
    notifyListeners();
    return tokens;
  }

  static List<JapaneseReadingToken> parse(String sentence, List<dynamic> raw) {
    final result = <JapaneseReadingToken>[];
    var cursor = 0;
    for (final item in raw) {
      if (item is! Map || item['surface'] is! String || item['start'] is! int) {
        throw const FormatException('Invalid Japanese token');
      }
      final text = item['surface'] as String;
      final start = item['start'] as int;
      if (text.isEmpty ||
          start < cursor ||
          start + text.length > sentence.length ||
          sentence.substring(start, start + text.length) != text) {
        throw const FormatException('Japanese token offset mismatch');
      }
      if (start > cursor) {
        result.add(JapaneseReadingToken(
            sentence.substring(cursor, start), '', cursor));
      }
      final rawReading = item['known'] == true && item['reading'] is String
          ? item['reading'] as String
          : '';
      final reading =
          RegExp(r'^[\u3041-\u3096\u30A1-\u30FAー]+$').hasMatch(rawReading)
              ? toHiragana(rawReading)
              : '';
      result.add(JapaneseReadingToken(text, reading, start));
      cursor = start + text.length;
    }
    if (cursor < sentence.length) {
      result.add(JapaneseReadingToken(sentence.substring(cursor), '', cursor));
    }
    // Merge numeric calendar expressions into a single text/reading unit.
    // Only replace complete token ranges; never shift adjacent annotations.
    for (final calendar in japaneseCalendarReadings(sentence).reversed) {
      final first = result.indexWhere((token) => token.start == calendar.start);
      final last = result.indexWhere((token) => token.end == calendar.end);
      if (first < 0 || last < first) continue;
      result.replaceRange(first, last + 1, [
        JapaneseReadingToken(sentence.substring(calendar.start, calendar.end),
            calendar.reading, calendar.start)
      ]);
    }
    return List.unmodifiable(result);
  }

  static String toHiragana(String text) => String.fromCharCodes(text.runes
      .map((rune) => rune >= 0x30A1 && rune <= 0x30F6 ? rune - 0x60 : rune));
}
