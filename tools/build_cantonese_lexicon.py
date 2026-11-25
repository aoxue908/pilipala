"""Rebuild the offline Jyutping asset from pinned, attributed upstream data.

Run with Python 3: python tools/build_cantonese_lexicon.py
No runtime network access or third-party Python packages are required.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/cantonese'
CACHE = ROOT / 'scratch/cantonese_source'
RIME = '259f0e48bba840c3a2e0d117539e96937f3d89bc'
OPENCC = 'fae2a0a911c30764e669a7d8b0591cd8e852934a'
SOURCES = {
    'chars': f'https://raw.githubusercontent.com/rime/rime-cantonese/{RIME}/jyut6ping3.chars.dict.yaml',
    'words': f'https://raw.githubusercontent.com/rime/rime-cantonese/{RIME}/jyut6ping3.words.dict.yaml',
    'LICENSE-RIME.txt': f'https://raw.githubusercontent.com/rime/rime-cantonese/{RIME}/LICENSE-CC-BY',
    'simplified': f'https://raw.githubusercontent.com/BYVoid/OpenCC/{OPENCC}/data/dictionary/TSCharacters.txt',
    'LICENSE-OPENCC.txt': f'https://raw.githubusercontent.com/BYVoid/OpenCC/{OPENCC}/LICENSE',
}


def fetch(item):
    name, url = item
    path = CACHE / (hashlib.sha256(url.encode()).hexdigest() + '.txt')
    if not path.exists():
        for attempt in range(3):
            try:
                req = urllib.request.Request(url, headers={'User-Agent': 'PiliPala-lexicon-builder'})
                data = urllib.request.urlopen(req, timeout=40).read()
                path.write_bytes(data)
                break
            except Exception:
                if attempt == 2:
                    raise
    return name, path.read_text(encoding='utf-8')


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        sources = dict(pool.map(fetch, SOURCES.items()))
    conversion = {}
    for line in sources['simplified'].splitlines():
        if line and not line.startswith('#'):
            key, values = line.split('\t')
            conversion[key] = values.split()[0]
    entries = {}
    skipped = []
    for name in ('chars', 'words'):
        body = sources[name].split('...', 1)[1]
        for line in body.splitlines():
            if not line.strip() or line.startswith('#'):
                continue
            fields = line.split('\t')
            if len(fields) < 2:
                skipped.append(line)
                continue
            term, reading = fields[:2]
            reading = ' '.join(reading.split())
            # Keep even non-aligned terms for exact dictionary lookup. The
            # renderer separately requires one syllable per Han character.
            if not re.fullmatch(r'[a-z]+[1-6](?: [a-z]+[1-6])*', reading):
                skipped.append(line)
                continue
            weight = float(fields[2].rstrip('%')) if len(fields) > 2 and fields[2] else 100.0
            variants = entries.setdefault(term, {})
            variants[reading] = max(weight, variants.get(reading, 0))
    data = {term: sorted(variants, key=lambda r: -variants[r]) for term, variants in entries.items()}
    original_count = len(data)
    # Original spellings always win collisions (e.g. traditional 發/髮 -> 发).
    aliases = {}
    for term, readings in data.items():
        alias = ''.join(conversion.get(char, char) for char in term)
        if alias != term and alias not in data:
            variants = aliases.setdefault(alias, [])
            variants.extend(r for r in readings if r not in variants)
    data.update(aliases)
    stats = {'originalEntries': original_count, 'simplifiedAliases': len(aliases),
             'characters': sum(len(term) == 1 for term in data),
             'phrases': sum(len(term) > 1 for term in data),
             'readings': sum(map(len, data.values())), 'skippedRows': len(skipped)}
    (OUT / 'lexicon.json').write_text(json.dumps({'version': 1, 'stats': stats, 'entries': data},
                                               ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    for name in ('LICENSE-RIME.txt', 'LICENSE-OPENCC.txt'):
        (OUT / name).write_text(sources[name], encoding='utf-8')
    attribution = f'''粤语离线字音及词组数据 / Offline Jyutping data

Rime Cantonese / 粤拼词库 — CanCLID (粤语计算语言学基础设施小组) and contributors.
https://github.com/rime/rime-cantonese
Upstream: https://github.com/CanCLID/rime-cantonese-upstream
Revision: {RIME}
Files: jyut6ping3.chars.dict.yaml, jyut6ping3.words.dict.yaml
License: Creative Commons Attribution 4.0 International (CC BY 4.0)
https://creativecommons.org/licenses/by/4.0/
See LICENSE-RIME.txt. No endorsement by the original authors is implied.

Simplified character aliases derived from OpenCC TSCharacters.txt.
OpenCC — BYVoid and contributors.
https://github.com/BYVoid/OpenCC
Revision: {OPENCC}
License: Apache License 2.0; see LICENSE-OPENCC.txt.

Modifications by PiliPala: converted TSV to JSON, deduplicated readings,
ranked by upstream weight (unweighted rows use 100; ties keep source order),
generated simplified spelling aliases without replacing original spellings.
Variants retained; subtitle alignment only uses Han-only entries with matching
character/syllable counts. This is pronunciation data, not a definitions dictionary.
Not included: maps dictionary (separately licensed), letter/symbol dictionaries.
Coverage is not a guarantee that every context-dependent reading is correct.
Runtime colloquial defaults: 嚟 lei4, 㗎 gaa3, 噶 gaa1; upstream variants retained.

Counts: {json.dumps(stats, ensure_ascii=False)}
'''
    (OUT / 'ATTRIBUTION.txt').write_text(attribution, encoding='utf-8')
    manifest = {'sources': {name: {'url': SOURCES[name], 'sha256': hashlib.sha256(value.encode()).hexdigest()}
                            for name, value in sources.items()}, 'stats': stats, 'skipped': skipped}
    (OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(stats), flush=True)


if __name__ == '__main__':
    build()
