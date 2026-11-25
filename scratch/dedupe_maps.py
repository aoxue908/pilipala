import re

with open("lib/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart", "r", encoding="utf-8") as f:
    content = f.read()

def deduplicate_map(map_name, text):
    pattern = rf"(static const Map<String, String> {map_name} = \{{)([\s\S]*?)(\n  \}};\n)"
    m = re.search(pattern, text)
    if not m:
        print(f"Could not find {map_name}")
        return text
    
    prefix = m.group(1)
    body = m.group(2)
    suffix = m.group(3)
    
    # Find all 'key': 'value'
    entries = re.findall(r"'([^']+)':\s*'([^']+)'", body)
    seen = {}
    for k, v in entries:
        seen[k] = v # keep latest
        
    print(f"{map_name}: {len(entries)} entries -> {len(seen)} unique entries")
    new_body = "\n"
    items = list(seen.items())
    for i in range(0, len(items), 8):
        chunk = items[i:i+8]
        line = "    " + ", ".join(f"'{k}': '{v}'" for k, v in chunk) + ",\n"
        new_body += line
        
    return text[:m.start()] + prefix + new_body + "  };\n" + text[m.end():]

content = deduplicate_map("_japaneseCommonVocab", content)
content = deduplicate_map("_cantoneseChars", content)
content = deduplicate_map("_japaneseKanjiToKana", content)

with open("lib/plugin/pl_player/realtime_caption/caption_offline_phonetics.dart", "w", encoding="utf-8") as f:
    f.write(content)

print("Deduplicated maps successfully!")
