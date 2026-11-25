import re

with open("lib/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart", "r", encoding="utf-8") as f:
    content = f.read()

with open("scratch/kanji_dart_entries.txt", "r", encoding="utf-8") as f:
    kanji_entries = f.read()

# Replace _japaneseKanjiToKana in content
kanji_start = content.find("static const Map<String, String> _japaneseKanjiToKana = {")
kanji_end = content.find("};", kanji_start) + 2

new_kanji_def = "static const Map<String, String> _japaneseKanjiToKana = {\n" + kanji_entries + "  };"
content = content[:kanji_start] + new_kanji_def + content[kanji_end:]

# Also ensure Cantonese entries have common traditional characters
cant_pattern = r"(static const Map<String, String> _cantoneseChars = \{)([\s\S]*?)(\};)"
extra_cantonese = """
    '齊': 'cai4', '點': 'dim2', '樣': 'joeng2', '邊': 'bin1', '個': 'go3',
    '聽': 'ting1', '廣': 'gwong2', '東': 'dung1', '話': 'waa6', '學': 'hok6',
    '習': 'zaap6', '歡': 'fun1', '樂': 'lok6', '這': 'ze5', '麼': 'mo1',
    '飲': 'jam2', '飯': 'faan6', '車': 'ce1', '開': 'hoi1', '門': 'mun4',
    '見': 'gin3', '說': 'syut3', '買': 'maai5', '賣': 'maai6', '錢': 'cin2',
    '愛': 'oi3', '國': 'gwok3', '會': 'wui5', '時': 'si4', '問': 'man6',
    '題': 'tai4', '無': 'mou4', '過': 'gwo3', '來': 'loi4', '頭': 'tau4',
    '體': 'tai2', '電': 'din6', '話': 'waa6', '機': 'gei1', '關': 'gwaan1',
"""

content = re.sub(cant_pattern, r"\1" + extra_cantonese + r"\2\3", content, count=1)

# Also ensure _japaneseCommonVocab has 本日, 休業, 超電磁砲, 映画館, etc.
vocab_pattern = r"(static const Map<String, String> _japaneseCommonVocab = \{)([\s\S]*?)(\};)"
extra_vocab = """
    '本日': 'ほんじつ',
    '休業': 'きゅうぎょう',
    '本日休業': 'ほんじつきゅうぎょう',
    '映画館': 'えいがかん',
    '超電磁砲': 'ちょうでんじほう',
    '大勝利': 'だいしょうり',
    '本当かい': 'ほんとうかい',
    '待たせて': 'またせて',
    'すまないね': 'すまないね',
"""
content = re.sub(vocab_pattern, r"\1" + extra_vocab + r"\2\3", content, count=1)

with open("lib/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart", "w", encoding="utf-8") as f:
    f.write(content)

print("Updated caption_offline_phonetics.dart successfully!")
