import requests
import json

urls = [
    "https://cdn.jsdelivr.net/gh/davidluzgouveia/kanji-data@master/kanji.json",
    "https://fastly.jsdelivr.net/gh/davidluzgouveia/kanji-data@master/kanji.json",
    "https://gcore.jsdelivr.net/gh/davidluzgouveia/kanji-data@master/kanji.json"
]

for url in urls:
    try:
        print("Trying:", url)
        r = requests.get(url, timeout=10)
        if r.status_code == 200:
            data = r.json()
            print("Kanji count:", len(data))
            first_k = list(data.keys())[0]
            print("First:", first_k, data[first_k])
            with open("scratch/kanji.json", "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            print("Saved to scratch/kanji.json")
            break
    except Exception as e:
        print("Error:", e)
