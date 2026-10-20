#!/usr/bin/env python3
"""The size of H3 (round h3, 2026-10-20): screens, looks, languages, blocks, words by class, and the keep words per reason with the `thin` flag the verdict
uses (fewer than 40 keep words in blocks that have a letter; a block with no letter is left out of the rule scores, as for every source). No rule is run here.
usage: h3_size.py <labels-h3/h3.jsonl>"""
import collections, json, sys

THIN = 40


def main():
    recs = [json.loads(l) for l in open(sys.argv[1])]
    hdr, blocks = recs[0], [r for r in recs if r['kind'] == 'block']
    cases = hdr['cases']
    print(f'screens {len(cases)} (scenes {len(set(c["scene"] for c in cases))}, looks {len(set(c["look"] for c in cases))}, '
          f'languages {dict(sorted(collections.Counter(c["lang"] for c in cases).items()))}), code regions {len(hdr["regions"])}')
    print('looks: ' + ', '.join(f'{k} {v}' for k, v in sorted(collections.Counter(c['look'] for c in cases).items())))
    for read in ('doc', 'vn'):
        B = [b for b in blocks if b['read'] == read]
        wk, reasons, scored, either = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
        unc = 0
        for b in B:
            for w in b['words']:
                wk[w[2] or 'none'] += 1
                if w[2] == 'keep':
                    reasons[w[3]] += 1
                    if not b['noletter']: scored[w[3]] += 1
                if w[2] == 'either': either[w[3]] += 1
            unc += len(b.get('unc', []))
        cls = collections.Counter(b['keep'] for b in B)
        print(f'read {read}: blocks {len(B)} {dict(sorted(cls.items()))}; words {dict(sorted(wk.items()))}; uncertain words {unc}')
        print(f'  keep words by reason (all blocks) {dict(reasons.most_common())}')
        print(f'  keep words by reason (blocks with a letter, the scored ones) {dict(scored.most_common())}')
        print(f'  either words by reason {dict(either.most_common())}')
        thin = sorted(r for r in ('code', 'cmd', 'log', 'config', 'path', 'id', 'flag', 'url', 'hash', 'hotkey', 'lineno', 'diffmark') if scored[r] < THIN)
        print(f'  reasons under {THIN} scored keep words (thin, no verdict): {thin or "none"}')
        for key in ('lang', 'look'):
            by = collections.Counter()
            for b in B:
                for w in b['words']:
                    if w[2] == 'keep': by[b[key]] += 1
            print(f'  keep words by {key}: {dict(sorted(by.items()))}')


if __name__ == '__main__':
    main()
