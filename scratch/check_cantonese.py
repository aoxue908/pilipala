import re

with open("lib/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart", "r", encoding="utf-8") as f:
    content = f.read()

# Extract _cantoneseChars
m = re.search(r'static const Map<String, String> _cantoneseChars = \{([^}]+)\};', content)
if m:
    chars = m.group(1)
    pairs = re.findall(r"'([^']+)':\s*'([^']+)'", chars)
    cantonese_dict = dict(pairs)
    print("Current _cantoneseChars count:", len(cantonese_dict))
    
    # Check common traditional characters
    test_chars = ['齊', '點', '樣', '邊', '個', '聽', '廣', '東', '話', '學', '習', '歡', '樂', '買', '賣', '錢', '開', '門', '見', '說', '這', '那', '麼']
    missing = [c for c in test_chars if c not in cantonese_dict]
    print("Missing traditional:", missing)
