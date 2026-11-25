import json

with open("scratch/kanji.json", "r", encoding="utf-8") as f:
    data = json.load(f)

for k in ['待', '休', '業', '館', '超', '電', '磁', '砲', '啊']:
    if k in data:
        print(k, data[k].get('readings_on'), data[k].get('readings_kun'))
    else:
        print(k, "not in data")
