#!/usr/bin/env python3
"""FAIL-first test of h2_labels.py --set h3 on H3's units with a fake OCR (no Vision): the same method as test_h2_labels.py, on the screens and kinds of units H3 adds
(a flag / identifier / path / hash / hotkey cell, a url chip, a name, an `nl -ba` row read as ONE block, the two gutters of the review look, a diff header).
usage: test_h3_labels.py <dir with h3.py's output> [--mutate]      --mutate flips every `keep` unit to translate before labelling: the checks must FAIL."""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_h2_labels import fake_ocr


def main():
    d = sys.argv[1]
    mutate = '--mutate' in sys.argv
    tmp = tempfile.mkdtemp()
    names = ['cli-ko.docs-light', 'nl-ko.term-green', 'review-ko.review-light', 'cards-ko.card-light', 'ref-en.docs-dark']
    extras = {'nl-ko.term-green': ['44  def monthly_active(history, today):', '46  month = today[:7]'], 'review-ko.review-light': ['67 67 68 68', '70 71 72']}
    rows = ['name\tlook\tsrc\twidth\theight']
    for n in names:
        meta = json.load(open(f'{d}/{n}.units.json'))
        if mutate:
            for u in meta['units']:
                if u['keep']: u['keep'] = False
        json.dump(meta, open(f'{tmp}/{n}.units.json', 'w'), ensure_ascii=False)
        json.dump(fake_ocr(meta['units'], extras.get(n, ())), open(f'{tmp}/{n}.ocr.jsonl', 'w'), ensure_ascii=False)
        rows.append(f'{n}\t{meta["look"].split("-")[0]}\t{meta["lang"]}\t1000\t0')
    open(f'{tmp}/index.tsv', 'w').write('\n'.join(rows) + '\n')
    subprocess.run([sys.executable, '-B', '-I', f'{HERE}/h2_labels.py', tmp, f'{tmp}/h3.jsonl', '--set', 'h3'], check=True, capture_output=True)
    recs = [json.loads(l) for l in open(f'{tmp}/h3.jsonl')]
    head = recs[0]
    blocks = [r for r in recs if r['kind'] == 'block' and r['read'] == 'doc']
    word = {}
    for b in blocks:
        for k, w in enumerate(b['words']):
            word.setdefault((b['paper'], w[5]), []).append((w[2], w[3], k in b['unc']))
    fails = 0

    def check(what, ok, note=''):
        nonlocal fails
        print(f'test_h3_labels: {"PASS" if ok else "FAIL"} {what}' + ('' if ok else f' [{note}]'))
        fails += 0 if ok else 1

    def first(screen, w): return word.get((screen, w), [('', '', False)])[0][:2]
    check('the header names the set h3', head['id'] == 'h3' and all(c['set'] == 'h3' for c in head['cases']), f'{head["id"]} {head["cases"][0]["set"]}')
    s = names[0]
    check('a flag cell is keep flag', first(s, '--settings-path') == ('keep', 'flag') and first(s, '--check-settings') == ('keep', 'flag'), f'{first(s, "--settings-path")}')
    check('a hotkey cell is keep hotkey', first(s, 'Ctrl+C') == ('keep', 'hotkey') and first(s, 'Cmd+T') == ('keep', 'hotkey'), f'{first(s, "Ctrl+C")}')
    check('a url chip is keep url', first(s, 'https://github.com/midagedev/mwoyeo/releases') == ('keep', 'url'), f'{first(s, "https://github.com/midagedev/mwoyeo/releases")}')
    check('a path chip of a sentence is keep path, a prose syllable is translate', first(s, 'scripts/release.sh') == ('keep', 'path') and first(s, '릴') == ('translate', 'prose'),
          f'{first(s, "scripts/release.sh")} {first(s, "릴")}')
    check('a name is either', first(s, 'GitHub')[0] == 'either', f'{first(s, "GitHub")}')
    t = names[1]
    check('an `nl -ba` row read as one block: the number is keep lineno, the line is keep code',
          first(t, '44') == ('keep', 'lineno') and first(t, 'def') == ('keep', 'code') and first(t, '46') == ('keep', 'lineno'), f'{first(t, "44")} {first(t, "def")} {first(t, "46")}')
    check('the command line of a terminal is keep cmd', first(t, 'nl') == ('keep', 'cmd'), f'{first(t, "nl")}')
    u = names[2]
    gl = [b for b in blocks if b['paper'] == u and b['text'] in ('67 67 68 68', '70 71 72')]
    check('the old / new gutters of the review look are keep lineno', [b['words'][0][2:4] for b in gl] == [['keep', 'lineno'], ['keep', 'lineno']], f'{[b["words"][0][2:4] for b in gl]}')
    check('a hash cell is keep hash', first(u, 'b459840') == ('keep', 'hash') and first(u, 'd0c8bea') == ('keep', 'hash'), f'{first(u, "b459840")}')
    check('a hunk header is keep diffmark', first(u, '@@') == ('keep', 'diffmark'), f'{first(u, "@@")}')
    check('a diff code line is keep code', first(u, 'static') == ('keep', 'code') or first(u, 'guard') == ('keep', 'code'), f'{first(u, "static")} {first(u, "guard")}')
    check('a word of the title and of a commit summary is translate', first(u, '엔')[0] == 'translate' and first(u, '앱')[0] == 'translate', f'{first(u, "엔")} {first(u, "앱")}')
    v = names[3]
    check('the app name and the time of a card are either', first(v, 'Terminal')[0] == 'either' and first(v, '09:43')[0] == 'either', f'{first(v, "Terminal")} {first(v, "09:43")}')
    check('a card title is translate, its code chip is keep cmd', first(v, '빌')[0] == 'translate' and first(v, 'swift') == ('keep', 'cmd'), f'{first(v, "빌")} {first(v, "swift")}')
    w = names[4]
    check('an identifier cell is keep id, a file cell keep path', first(w, 'MenuBarIcon') == ('keep', 'id') and first(w, 'scripts/release.sh') == ('keep', 'path'), f'{first(w, "MenuBarIcon")}')
    bad = [(k, x) for k, xs in word.items() for x in xs if x[0] == 'translate' and not any(ch.isalpha() for ch in k[1])]
    check('no translate word without a letter', not bad, f'{bad[:3]}')
    reasons = ('code', 'cmd', 'log', 'config', 'path', 'id', 'flag', 'url', 'hash', 'hotkey', 'lineno', 'diffmark')
    check('every keep word names a reason of the taxonomy', all(x[1] in reasons for xs in word.values() for x in xs if x[0] == 'keep'), str({x[1] for xs in word.values() for x in xs if x[0] == 'keep'}))
    print(f'test_h3_labels: {"ALL PASS" if not fails else str(fails) + " FAIL"}{" (mutated units)" if mutate else ""}')
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
