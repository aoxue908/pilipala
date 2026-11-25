import json

with open("scratch/kanji.json", "r", encoding="utf-8") as f:
    data = json.load(f)

# Sort kanji by frequency / grade / jlpt
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
print("Top 10 kanji:", [k for k, v in sorted_kanji[:10]])

# Build mapping for top 3500 kanji
kanji_to_kana = {}
for k, v in sorted_kanji[:3500]:
    ons = v.get('readings_on', [])
    kuns = v.get('readings_kun', [])
    
    # Clean readings
    # Prefer kun stem if it has a period (verb/adjective stem) e.g. "ま.つ" -> "ま"
    stem = None
    for kun in kuns:
        clean_kun = kun.replace('!', '').replace('-', '')
        if '.' in clean_kun:
            stem = clean_kun.split('.')[0]
            break
        elif not stem and clean_kun:
            stem = clean_kun
            
    reading = None
    # For verbs/adjectives (which have okurigana like 待つ, 食べる), stem is best
    if stem and len(stem) <= 3:
        # Check if it has frequent on-reading or kun-reading
        # Usually verbs like 待, 食, 飲, 見, 聞, 行, 来, 言, 話, 走, 歩 use stem
        if kuns and '.' in kuns[0]:
            reading = stem
        elif ons:
            reading = ons[0]
        else:
            reading = stem
    elif ons:
        reading = ons[0]
    elif kuns:
        reading = kuns[0].replace('!', '').replace('-', '').split('.')[0]
        
    if reading:
        kanji_to_kana[k] = reading

print(f"Generated {len(kanji_to_kana)} kanji readings.")
for check in ['待', '休', '業', '館', '超', '電', '磁', '砲', '啊', '私', '本', '当']:
    print(check, "->", kanji_to_kana.get(check))
