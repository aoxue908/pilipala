import json

with open("scratch/kanji.json", "r", encoding="utf-8") as f:
    data = json.load(f)

# Common Joyo & JLPT kanji
def get_rank(item):
    k, v = item
    freq = v.get('freq')
    if freq is not None:
        return freq
    grade = v.get('grade')
    if grade is not None:
        return 3000 + grade * 200
    jlpt = v.get('jlpt_new')
    if jlpt is not None:
        return 5000 + (6 - jlpt) * 200
    return 10000

sorted_kanji = sorted(data.items(), key=get_rank)

# Specific overrides for high-frequency kanji to ensure natural readings
overrides = {
    '日': 'ひ', '本': 'ほん', '人': 'ひと', '一': 'いち', '二': 'に', '三': 'さん',
    '四': 'よん', '五': 'ご', '六': 'ろく', '七': 'なな', '八': 'はち', '九': 'きゅう',
    '十': 'じゅう', '百': 'ひゃく', '千': 'せん', '万': 'まん', '円': 'えん',
    '年': 'とし', '月': 'つき', '木': 'き', '水': 'みず', '火': 'ひ', '金': 'きん', '土': 'つち',
    '今': 'いま', '時': 'とき', '分': 'ふん', '秒': 'びょう', '前': 'まえ', '後': 'あと',
    '上': 'うえ', '下': 'した', '左': 'ひだり', '右': 'みぎ', '中': 'なか', '外': 'そと',
    '私': 'わたし', '僕': 'ぼく', '俺': 'おれ', '君': 'きみ', '誰': 'だれ', '何': 'なに',
    '見': 'み', '言': 'い', '話': 'はな', '行': 'い', '来': 'き', '出': 'で', '入': 'はい',
    '待': 'ま', '食': 'た', '飲': 'の', '買': 'か', '売': 'う', '聞': 'き', '読': 'よ',
    '書': 'か', '知': 'し', '思': 'おも', '考': 'かんが', '感': 'かん', '作': 'つく',
    '使': 'つか', '持': 'も', '取': 'と', '生': 'い', '死': 'し', '好': 'す',
    '大': 'おお', '小': 'ちい', '高': 'たか', '低': 'ひく', '新': 'あたら', '古': 'ふる',
    '長': 'なが', '短': 'みじか', '白': 'しろ', '黒': 'くろ', '赤': 'あか', '青': 'あお',
    '道': 'みち', '町': 'まち', '国': 'くに', '海': 'うみ', '山': 'やま', '川': 'かわ',
    '空': 'そら', '雨': 'あめ', '風': 'かぜ', '音': 'おと', '声': 'こえ', '心': 'こころ',
    '手': 'て', '目': 'め', '足': 'あし', '口': 'くち', '耳': 'みみ', '気': 'き',
    '啊': 'あ', '休': 'やす', '業': 'ぎょう', '超': 'ちょう', '電': 'でん', '磁': 'じ', '砲': 'ほう',
    '館': 'かん', '神': 'かみ', '魔': 'ま', '法': 'ほう', '勝': 'か', '負': 'ま',
    '当': 'とう', '強': 'つよ', '弱': 'よわ', '少': 'すこ', '多': 'おお',
}

kanji_map = {}
for k, v in overrides.items():
    kanji_map[k] = v

for k, v in sorted_kanji[:2800]:
    if k in kanji_map:
        continue
    ons = v.get('readings_on', [])
    kuns = v.get('readings_kun', [])
    
    stem = None
    for kun in kuns:
        clean_kun = kun.replace('!', '').replace('-', '')
        if '.' in clean_kun:
            stem = clean_kun.split('.')[0]
            break
        elif not stem and clean_kun:
            stem = clean_kun
            
    reading = None
    if stem and len(stem) <= 3 and kuns and '.' in kuns[0]:
        reading = stem
    elif ons:
        reading = ons[0]
    elif stem:
        reading = stem
        
    if reading:
        kanji_map[k] = reading

print(f"Total kanji in map: {len(kanji_map)}")
with open("scratch/kanji_dart_entries.txt", "w", encoding="utf-8") as f:
    entries = [f"'{k}': '{v}'" for k, v in kanji_map.items()]
    # write in chunks of 5 per line
    for i in range(0, len(entries), 8):
        f.write("    " + ", ".join(entries[i:i+8]) + ",\n")
print("Done writing scratch/kanji_dart_entries.txt")
