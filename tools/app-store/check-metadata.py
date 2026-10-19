#!/usr/bin/env python3
"""App Store Connect metadata limits and preserved tokens, one line per locale.
Usage: python3 -I tools/app-store/check-metadata.py <file.md>...      (docs/app-store/metadata.md gives its ko and en sections;
                                                                       any other file is one locale named after its stem, e.g. metadata/pt-BR.md)

Limits are App Store Connect's: name and subtitle 30 characters, promotional text 170, keywords 100 UTF-8 bytes, description 4000.
The description must still contain the tokens a translation must not touch (the two hotkeys, the engine names, the OS and chip floor).
Also FAIL: a field missing, keywords with a space around a comma / an empty or repeated term, a name that does not start with
"Mwoyeo – ". Information, never a failure: `overlap` lists keywords that are also a word of the name or subtitle (Apple indexes those
already, so the bytes are wasted); `note` lists a stated count `(N)` that is not the real length (docs/app-store/metadata.md en says
(165) for a 169-character promotional text). Prints one line per locale; rc 1 when any line says FAIL, rc 2 on usage."""
import os
import re
import sys

SHORT = {'name': 'name', 'subtitle': 'sub', 'promotional': 'promo', 'keywords': 'kw', 'description': 'desc'}
LIMITS = {'name': 30, 'subtitle': 30, 'promotional': 170, 'keywords': 100, 'description': 4000}   # keywords in UTF-8 bytes
# Written as escapes so an editor cannot normalise them: U+2303 CONTROL, U+2325 OPTION.
TOKENS = ['⌃⌥L', '⌃⌥O', 'Ollama', 'LM Studio', 'macOS 26', 'M1']
LABELS = {
    'Name': 'name', '이름': 'name',
    'Subtitle': 'subtitle', '부제': 'subtitle',
    'Promotional text': 'promotional', '프로모션 텍스트': 'promotional',
    'Keywords': 'keywords', '키워드': 'keywords',
    'Description': 'description', '설명': 'description',
}
SECTIONS = {'English': 'en', '한국어': 'ko'}      # headings of docs/app-store/metadata.md
FIELD = re.compile(r'^\*\*([^*]+)\*\*(?:\s*\(([^)]*)\))?:\s*(.*)$')
CJK = re.compile('[぀-ヿ㐀-鿿가-힯]')


def parse(text):
    """{field: (value, stated count or None)} from the lines of one locale; a value is the `backticked` span of its line, else the block below."""
    fields = {}
    cur = None
    for line in text.split('\n'):
        m = FIELD.match(line)
        if m and m.group(1) in LABELS:
            cur = LABELS[m.group(1)]
            stated = int(m.group(2)) if m.group(2) and m.group(2).isdigit() else None
            inline = re.search(r'`([^`]*)`', m.group(3))
            fields[cur] = [inline.group(1) if inline else m.group(3), stated, bool(inline)]
        elif line.startswith('#'):
            cur = None
        elif cur and not fields[cur][2]:
            fields[cur][0] += '\n' + line
    return {k: (v[0].strip('\n').strip() if k not in ('name', 'subtitle', 'keywords') else v[0].strip(), v[1]) for k, v in fields.items()}


def locales(path):
    """[(locale, field dict)] of one file."""
    text = open(path, encoding='utf-8').read()
    parts = re.split(r'(?m)^## (.+)$', text)         # [preamble, title, body, title, body, ...]
    sections = [(SECTIONS[t.strip()], b) for t, b in zip(parts[1::2], parts[2::2]) if t.strip() in SECTIONS]
    if sections:
        return [(loc, parse(body)) for loc, body in sections]
    return [(os.path.splitext(os.path.basename(path))[0], parse(text))]


def words(s):
    return set(re.findall(r'\w+', s.lower()))


def overlap(f):
    """Keyword terms that the name or subtitle already carries: the same word, or (CJK has no spaces) a substring of them."""
    own = f.get('name', ('',))[0] + ' ' + f.get('subtitle', ('',))[0]
    seen = words(own)
    out = []
    for t in f.get('keywords', ('',))[0].split(','):
        if t and (t.lower() in seen or (CJK.search(t) and t in own)):
            out.append(t)
    return out


def check(loc, f):
    """The report line of one locale: counts, then `ok` or `FAIL: reasons`."""
    bad = []
    notes = []
    counts = []
    for key in ('name', 'subtitle', 'promotional', 'keywords', 'description'):
        if key not in f or not f[key][0]:
            bad.append(f'{key} missing')
            counts.append(f'{SHORT[key]} -')
            continue
        value, stated = f[key]
        n = len(value.encode('utf-8')) if key == 'keywords' else len(value)
        counts.append(f'{SHORT[key]} {n}/{LIMITS[key]}' + ('B' if key == 'keywords' else ''))
        if n > LIMITS[key]:
            bad.append(f'{key} {n}>{LIMITS[key]}')
        if stated is not None and stated != n:
            notes.append(f'{key} says ({stated}), is {n}')
    kw = f.get('keywords', ('',))[0]
    terms = kw.split(',') if kw else []
    if re.search(r'\s,|,\s', kw) or kw != kw.strip():
        bad.append('keywords have a space beside a comma')
    if any(not t for t in terms):
        bad.append('keywords have an empty term')
    if len({t.lower() for t in terms}) != len(terms):
        bad.append('keywords repeat a term')
    if 'name' in f and not f['name'][0].startswith('Mwoyeo – '):
        bad.append('name does not start with "Mwoyeo – "')
    desc = f.get('description', ('',))[0]
    missing = [t for t in TOKENS if t not in desc]
    if desc and missing:
        bad.append('description lacks ' + ' '.join(missing))
    ov = overlap(f)
    verdict = 'FAIL: ' + '; '.join(bad) if bad else 'ok'
    return f'{loc:8} {"  ".join(counts)}  overlap {",".join(ov) or "-"}  {verdict}' + (f'  [note: {"; ".join(notes)}]' if notes else ''), bool(bad)


def main(argv):
    if not argv:
        print('\n'.join(__doc__.split('\n')[1:3]), file=sys.stderr)
        return 2
    failed = False
    for path in argv:
        try:
            found = locales(path)
        except OSError as e:
            print(f'{path}: {e}', file=sys.stderr)
            return 2
        for loc, f in found:
            line, bad = check(loc, f)
            print(line)
            failed |= bad
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
