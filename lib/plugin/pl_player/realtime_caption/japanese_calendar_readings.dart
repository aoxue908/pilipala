/// Calendar/counter compounds need sound changes beyond a morphological
/// dictionary's standalone numeral reading. Source spelling stays unchanged.
class JapaneseCalendarReading {
  const JapaneseCalendarReading(this.start, this.end, this.reading);
  final int start;
  final int end;
  final String reading;
}

List<JapaneseCalendarReading> japaneseCalendarReadings(String sentence) {
  const digits = r'0-9０-９一二三四五六七八九十';
  final pattern =
      RegExp('(?<![$digits])([$digits]{1,3})([かカヵヶケ箇]月|週間|週|時間|時|日間|日|月)(?!曜日)');
  final result = <JapaneseCalendarReading>[];
  const months = [
    '',
    'いち',
    'に',
    'さん',
    'し',
    'ご',
    'ろく',
    'しち',
    'はち',
    'く',
    'じゅう',
    'じゅういち',
    'じゅうに'
  ];
  const days = {
    1: 'ついたち',
    2: 'ふつか',
    3: 'みっか',
    4: 'よっか',
    5: 'いつか',
    6: 'むいか',
    7: 'なのか',
    8: 'ようか',
    9: 'ここのか',
    10: 'とおか',
    14: 'じゅうよっか',
    19: 'じゅうくにち',
    20: 'はつか',
    24: 'にじゅうよっか',
    29: 'にじゅうくにち'
  };
  for (final match in pattern.allMatches(sentence)) {
    final number = _number(match[1]!);
    if (number == null || number < 1 || number > 99) continue;
    final unit = match[2]!;
    String? reading;
    if (unit == '月') {
      if (number <= 12) reading = '${months[number]}がつ';
    } else if (unit.endsWith('月')) {
      reading = '${_counter(number, month: true)}かげつ';
    } else if (unit.startsWith('週')) {
      reading = '${_counter(number)}しゅう${unit == '週間' ? 'かん' : ''}';
    } else if (unit.startsWith('時')) {
      if (number <= 24) {
        final last = number % 10;
        final prefix = number >= 10 ? _ordinary(number - last) : '';
        final stem = {4: 'よ', 7: 'しち', 9: 'く'}[last];
        reading =
            '${stem == null ? _ordinary(number) : '$prefix$stem'}じ${unit == '時間' ? 'かん' : ''}';
      }
    } else if (unit.startsWith('日') && number <= 31) {
      if (number == 1 && unit == '日') {
        final before = sentence.substring(0, match.start).trimRight();
        final after = sentence.substring(match.end);
        final date =
            RegExp('(?:[$digits]+月|毎月|翌月|来月|今月|先月|日付は|日付が)\$').hasMatch(before);
        final duration =
            RegExp(r'^(中|だけ|ずつ|あたり|当たり|おき|以内|以上|未満|で|かか|休|働|過ご|経|待|寝|に)')
                    .hasMatch(after) ||
                RegExp(r'(丸|たった|もう|約|合計|あと)$').hasMatch(before);
        // Bare "1日" cannot reliably distinguish date from elapsed time.
        reading = date
            ? 'ついたち'
            : duration
                ? 'いちにち'
                : '';
      } else {
        reading =
            number == 1 ? 'いちにち' : days[number] ?? '${_ordinary(number)}にち';
        if (unit == '日間') reading += 'かん';
      }
    }
    if (reading != null) {
      result.add(JapaneseCalendarReading(match.start, match.end, reading));
    }
  }
  return result;
}

int? _number(String raw) {
  final text = String.fromCharCodes(
      raw.runes.map((r) => r >= 0xFF10 && r <= 0xFF19 ? r - 0xFEE0 : r));
  final arabic = int.tryParse(text);
  if (arabic != null) return arabic;
  const kanji = '一二三四五六七八九';
  int? digit(String part) => part.isEmpty
      ? 0
      : part.length == 1 && kanji.contains(part)
          ? kanji.indexOf(part) + 1
          : null;
  final parts = text.split('十');
  if (parts.length == 1) return digit(text);
  if (parts.length != 2) return null;
  final tens = parts.first.isEmpty ? 1 : digit(parts.first);
  final ones = digit(parts.last);
  return tens == null || ones == null ? null : tens * 10 + ones;
}

String _ordinary(int number) {
  const ones = ['', 'いち', 'に', 'さん', 'よん', 'ご', 'ろく', 'なな', 'はち', 'きゅう'];
  if (number < 10) return ones[number];
  return '${number ~/ 10 == 1 ? '' : ones[number ~/ 10]}じゅう${ones[number % 10]}';
}

String _counter(int number, {bool month = false}) {
  final last = number % 10;
  final stem = {0: 'じゅっ', 1: 'いっ', 8: 'はっ', if (month) 6: 'ろっ'}[last];
  if (stem == null) return _ordinary(number);
  final prefix = last == 0
      ? (number < 20 ? '' : _ordinary(number ~/ 10))
      : number >= 10
          ? _ordinary(number - last)
          : '';
  return '$prefix$stem';
}
