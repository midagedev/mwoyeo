#!/bin/bash
# FAIL-first check of the keep columns of tools/usecase-bench/score.py. Builds renders of k04-stackoverflow-en from its expected.txt:
#   good      keep units come back as written, the others translated, inline substrings intact
#   code      one code line translated      -> kept_ok must drop by one, detail names the line
#   prose     one prose unit not translated -> translated_ok must drop by one
#   inline    a translation that changes an inline substring -> inline_ok must drop by one
# and compares with the numbers a good run must have. The segmentation columns score the `code` render as perfect (correct 12/12):
# a translated code line is a unit read whole. That is what the keep columns exist to catch.
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bench/set" && cp "$HERE/../usecase-bench/score.py" "$T/bench/" && cp "$HERE/../usecase-bench/set/k04-stackoverflow-en.expected.txt" "$T/bench/set/"
printf 'name\tuse_case\tsrc\twidth\theight\nk04-stackoverflow-en\tcode\ten\t900\t560\n' > "$T/bench/set/index.tsv"
python3 - "$T" <<'PY'
import re, sys, os
T = sys.argv[1]
NOTE = re.compile(r'\s*\((keep(?::\w+)?|inline:.*)\)\s*$')
units = []
for ln in open(f'{T}/bench/set/k04-stackoverflow-en.expected.txt'):
    ln = ln.rstrip('\n')
    m = NOTE.search(ln)
    if m: units.append((ln[:m.start()], m.group(1)))
    else: units.append((re.sub(r'\s*\(optional\)$', '', ln), 'optional' if ln.endswith('(optional)') else ''))
def render(name, edit=lambda u, n, t: t):
    os.makedirs(f'{T}/{name}/out', exist_ok=True)
    out = ['pipeline: 1 ms']
    for u, n in units:
        t = u if n.startswith('keep') else '번역: ' + u
        out += [f'  {u}', f'    → {edit(u, n, t)}']
    open(f'{T}/{name}/out/k04-stackoverflow-en-swift.out', 'w').write('\n'.join(out) + '\nissues=0\n')
first_keep = next(u for u, n in units if n.startswith('keep'))
first_prose = next(u for u, n in units if n == '' )
first_inline = next((u, n) for u, n in units if n.startswith('inline:'))
render('good')
render('code', lambda u, n, t: '코드 ' + u if u == first_keep else t)
render('prose', lambda u, n, t: u if u == first_prose else t)
render('inline', lambda u, n, t: t.replace(n[len('inline:'):].split(' ; ')[0].strip(), 'X') if u == first_inline[0] else t)
PY
fail=0
want() { # name, regex
    out=$(python3 "$T/bench/score.py" "$T/$1" swift | grep -E "^(code|TOTAL) .* all ")
    if echo "$out" | grep -q -E "$2"; then echo "PASS $1: $(echo "$out" | head -1 | sed 's/.*| //')"; else echo "FAIL $1: wanted /$2/, got:"; echo "$out"; fail=1; fi
}
want good   'kept_ok 5/5 translated_ok 6/6 inline_ok 2/2'
want code   'kept_ok 4/5 translated_ok 6/6 inline_ok 2/2'
want prose  'kept_ok 5/5 translated_ok 5/6 inline_ok 2/2'
want inline 'kept_ok 5/5 translated_ok 6/6 inline_ok 1/2'
grep -q 'kept_fail' "$T/code/detail.txt" && echo "PASS code: detail names the line: $(grep kept_fail "$T/code/detail.txt")" || { echo "FAIL code: no kept_fail in detail"; fail=1; }
echo "segmentation columns of the same code render (they cannot see the translated line): $(python3 "$T/bench/score.py" "$T/code" swift | grep -E '^code .* all ' | sed 's/ |.*//')"
exit $fail
