import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bundled Rime Cantonese data. Parsing/indexing runs outside the UI isolate;
/// subtitle rendering subsequently performs synchronous indexed lookups.
class CantoneseLexicon {
  CantoneseLexicon._(this.entries, this._lengths);

  static CantoneseLexicon shared = CantoneseLexicon._({}, {});
  static Future<void>? _initialization;
  static final _han = RegExp(r'^\p{Script=Han}+$', unicode: true);
  final Map<String, List<String>> entries;
  // First rune -> available UTF-16 lengths, longest first.
  final Map<int, List<int>> _lengths;

  static Future<void> initialize() => _initialization ??= _load();

  static Future<void> _load() async {
    LicenseRegistry.addLicense(() async* {
      for (final file in ['ATTRIBUTION', 'LICENSE-RIME', 'LICENSE-OPENCC']) {
        yield LicenseEntryWithLineBreaks(['Cantonese pronunciation data'],
            await rootBundle.loadString('assets/cantonese/$file.txt'));
      }
    });
    try {
      final data = await rootBundle.loadString('assets/cantonese/lexicon.json');
      shared = await compute(parse, data);
    } catch (error) {
      // The small built-in tables remain available if an asset is damaged.
      debugPrint('Could not load bundled Cantonese lexicon: $error');
      _initialization = null;
    }
  }

  static CantoneseLexicon parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    if (json['version'] != 1) throw const FormatException('Lexicon version');
    final entries = <String, List<String>>{};
    final lengths = <int, Set<int>>{};
    for (final entry in (json['entries'] as Map<String, dynamic>).entries) {
      final readings = List<String>.from(entry.value as List);
      if (entry.key.isEmpty || readings.isEmpty) continue;
      entries[entry.key] = List.unmodifiable(readings);
      if (!_han.hasMatch(entry.key)) continue;
      final count = entry.key.runes.length;
      if (count < 2 || !readings.any((r) => r.split(' ').length == count)) {
        continue;
      }
      lengths
          .putIfAbsent(entry.key.runes.first, () => {})
          .add(entry.key.length);
    }
    return CantoneseLexicon._(Map.unmodifiable(entries), {
      for (final entry in lengths.entries)
        entry.key: entry.value.toList()..sort((a, b) => b.compareTo(a)),
    });
  }

  // Preserve familiar colloquial defaults; all upstream alternatives remain
  // available in the lookup sheet. Phrase-specific readings still take priority.
  static const _colloquialDefaults = {'嚟': 'lei4', '㗎': 'gaa3', '噶': 'gaa1'};

  List<String> readings(String text) {
    final variants = entries[text] ?? const <String>[];
    final preferred = _colloquialDefaults[text];
    if (preferred == null ||
        !variants.contains(preferred) ||
        variants.first == preferred) return variants;
    return [preferred, ...variants.where((reading) => reading != preferred)];
  }

  ({String text, List<String> syllables})? phraseAt(String text, int offset) {
    final rune = text.substring(offset).runes.first;
    for (final length in _lengths[rune] ?? const <int>[]) {
      if (offset + length > text.length) continue;
      final phrase = text.substring(offset, offset + length);
      final variants = entries[phrase];
      if (variants == null) continue;
      final count = phrase.runes.length;
      for (final reading in variants) {
        final syllables = reading.split(' ');
        if (syllables.length == count) {
          return (text: phrase, syllables: syllables);
        }
      }
    }
    return null;
  }
}
