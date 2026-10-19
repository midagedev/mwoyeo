#!/usr/bin/env python3
"""FAIL-first test of h2_labels.py with a fake OCR (no Vision): the words of the units of two screens, cut the way Vision cuts them (a run of
Latin / digits / punctuation is one word, every CJK character its own), are labelled and checked against what the construction says.
usage: test_h2_labels.py <dir with h2.py's output (units.json, index.tsv)> [--mutate]
--mutate flips the class of every `keep` unit to translate in the units before labelling: the checks must FAIL (the test's own FAIL-first)."""
import json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WORD = re.compile(r'[A-Za-z0-9_./:\-\[\]()"~<>=,;@#$%&*+|\\{}\'`^?!‘’“”›»‹«·]+|[ᄀ-ᇿ぀-ヿ㐀-䶿一-鿿가-힯＀-￯]|[^\s]')


def fake_ocr(units, extra=()):
    """One block per unit (and one per text of `extra`): text, words [start, end, x, y, w, h, word]."""
    blocks = []
    units = [{'text': t} for t in extra] + list(units)
    for k, u in enumerate(units):
        t = u['text']
        words = [[m.start(), m.end(), 10.0 + m.start() * 8, 20.0 + k * 30, 8.0 * (m.end() - m.start()), 18.0, m.group(0)] for m in WORD.finditer(t)]
        blocks.append({'r': [10.0, 20.0 + k * 30, 8.0 * len(t), 18.0], 'n': 1, 't': t, 'w': words})
    return {'image': 'fake', 'size': [100, 100], 'vn': blocks, 'doc': blocks}


def main():
    d = sys.argv[1]
    mutate = '--mutate' in sys.argv
    tmp = tempfile.mkdtemp()
    names = ['chat-ko.chat-dark', 'swift-ko.ide-light', 'gitdiff-ja.ide-light']
    extras = {'swift-ko.ide-light': ['3', '999'], 'gitdiff-ja.ide-light': ['+', '-', '4000']}
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
    subprocess.run([sys.executable, '-B', '-I', f'{HERE}/h2_labels.py', tmp, f'{tmp}/h2.jsonl'], check=True, capture_output=True)
    recs = [json.loads(l) for l in open(f'{tmp}/h2.jsonl')]
    blocks = [r for r in recs if r['kind'] == 'block' and r['read'] == 'doc']
    word = {}                                                # (screen, word text) -> list of (keep, reason, uncertain)
    for b in blocks:
        for k, w in enumerate(b['words']):
            word.setdefault((b['paper'], w[5]), []).append((w[2], w[3], k in b['unc']))
    fails = 0

    def check(what, ok, note=''):
        nonlocal fails
        print(f'test_h2_labels: {"PASS" if ok else "FAIL"} {what}' + ('' if ok else f' [{note}]'))
        fails += 0 if ok else 1

    def first(screen, w): return word.get((screen, w), [('', '', False)])[0]
    s = names[0]
    check('a word of an inline path / command is keep with the author\'s reason', first(s, 'Mwoyeo')[:2] == ('keep', 'cmd') and first(s, 'settings.json')[:2] == ('keep', 'path'),
          f'{first(s, "Mwoyeo")} {first(s, "settings.json")}')
    check('a word of the prose around it is translate', first(s, '직')[:2] == ('translate', 'prose') and first(s, '줄')[:2] == ('translate', 'prose'), f'{first(s, "직")}')
    check('a name and a time are either', first(s, 'dana')[0] == 'either' and first(s, '9:12')[0] == 'either', f'{first(s, "dana")} {first(s, "9:12")}')
    check('a code line of a message is keep with its reason', first(s, 'ignored;')[:2] == ('keep', 'log') or first(s, 'ignored')[:2] == ('keep', 'log'), f'{first(s, "ignored;")}')
    check('a bare path in a sentence is keep and uncertain', first(s, 'docs/settings-for-agents.md에')[0] == 'keep' or first(s, 'docs/settings-for-agents.md')[2],
          f'{first(s, "docs/settings-for-agents.md")}')
    t = names[1]
    check('a comment line of a listing is keep and uncertain', first(t, '단')[:2] == ('keep', 'code') and first(t, '단')[2], f'{first(t, "단")}')
    check('a code word is keep, not uncertain', first(t, 'public')[:2] == ('keep', 'code') and not first(t, 'public')[2], f'{first(t, "public")}')
    check('the gutter is keep lineno', any(v[:2] == ('keep', 'lineno') for vs in word.values() for v in vs), 'no lineno word')
    u = names[2]
    gl = [b for b in blocks if b['paper'] == t and b['text'] in ('3', '999')]
    check('a lone gutter number is keep lineno, a number outside 1..n is not labelled', [b['words'][0][2:4] for b in gl] == [['keep', 'lineno'], ['', '']], f'{[b["words"][0][2:4] for b in gl]}')
    dl = [b for b in blocks if b['paper'] == u and b['text'] in ('+', '-', '4000')]
    check('a lone + / - block of a diff screen is keep diffmark, a number is not', [b['words'][0][2:4] for b in dl] == [['keep', 'diffmark'], ['keep', 'diffmark'], ['', '']],
          f'{[b["words"][0][2:4] for b in dl]}')
    check('a file name of the sidebar is keep path', first(t, 'Deadline.swift')[:2] == ('keep', 'path'), f'{first(t, "Deadline.swift")}')
    check('the status bar is translate or either, never keep', first(t, '열')[0] in ('translate', 'either') and first(t, 'UTF-8')[0] == 'either', f'{first(t, "열")} {first(t, "UTF-8")}')
    bad = [(k, v) for k, vs in word.items() for v in vs if (v[0] == 'translate' and not any(ch.isalpha() for ch in k[1]))]
    check('no translate word without a letter', not bad, f'{bad[:3]}')
    check('every keep word names a reason of the taxonomy', all(v[1] in ('code', 'cmd', 'log', 'config', 'path', 'id', 'flag', 'url', 'hash', 'hotkey', 'lineno', 'diffmark')
                                                              for vs in word.values() for v in vs if v[0] == 'keep'),
          str({v[1] for vs in word.values() for v in vs if v[0] == 'keep'}))
    print(f'test_h2_labels: {"ALL PASS" if not fails else str(fails) + " FAIL"}{" (mutated units)" if mutate else ""}')
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main()
