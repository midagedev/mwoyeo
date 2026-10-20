#!/usr/bin/env python3
"""Loads the labelled blocks of every set with what the judges need: the label record, the OCR block (rect, word boxes), the picture's
block background (regionfeed) and the word backgrounds read off the picture, and today's rules record (keeprules).

Sets (the split is binding, round m-bench 2026-10-20):
  train / cross-validation   h2 (46 screens, labels-h2/h2.jsonl), x:code (the 12 cases), x:2401.10066 and x:2310.06142 (the two CC BY papers)
  test only                  h3 (labels-h3/h3.jsonl; never fitted on, never used to pick a feature, a threshold or an early stop)
Pictures and Vision reads are fixed (no new Vision): H2 KEEP_WORK/h2, H3 H3_WORK, the code cases and papers X_WORK; the feeds (regionfeed) and the rules
records (keeprules) are made by run.sh from those with the build of this tree (MB_SCRATCH/build).

Cache: MB_SCRATCH/cache/<set>.pkl (the loaded blocks with word backgrounds); delete it to rebuild."""
import collections, json, os, pickle, sys

HERE = os.path.dirname(os.path.abspath(__file__))
KL = os.path.dirname(HERE)
sys.path.insert(0, KL)
import numpy as np
from PIL import Image

SCRATCH = os.environ.get('MB_SCRATCH', '/tmp/m-bench')
WORK = {
    'h2': os.environ.get('KEEP_WORK', '/tmp/k3a/wb') + '/h2',
    'h3': os.environ.get('H3_WORK', '/tmp/h3/legA') + '/h3',
    'x': os.environ.get('X_WORK', '/tmp/l0/g4b-work'),
}
# set name -> (labels file, work kind, feed, rules file)
SETS = {
    'h2': ('labels-h2/h2.jsonl', 'h2', 'h2'),
    'h3': ('labels-h3/h3.jsonl', 'h3', 'h3'),
    'code': ('labels/code.jsonl', 'code', 'x'),
    'p2401': ('labels/2401.10066.jsonl', '2401.10066', 'x'),
    'p2310': ('labels/2310.06142.jsonl', '2310.06142', 'x'),
}
TRAIN_SETS = ('h2', 'code', 'p2401', 'p2310')
TEST_SETS = ('h3',)


def _ocr_and_png(setname, b, cache):
    """-> (the OCR read dict of the block's picture, picture path)."""
    kind = SETS[setname][1]
    if kind in ('h2', 'h3'):
        base = f'{WORK[kind]}/{b["paper"]}'
        key = base
        if key not in cache: cache[key] = json.loads(open(base + '.ocr.jsonl').read())
        return cache[key], base + '.png'
    if kind == 'code':
        base = f'{WORK["x"]}/code/{b["paper"]}'
        if base not in cache: cache[base] = json.loads(open(base + '.ocr.jsonl').read())
        return cache[base], base + '.png'
    key = (kind, 'all')
    if key not in cache: cache[key] = open(f'{WORK["x"]}/{kind}/ocr.jsonl').read().splitlines()
    page = b['page']
    if (kind, page) not in cache: cache[(kind, page)] = json.loads(cache[key][page - 1])
    return cache[(kind, page)], f'{WORK["x"]}/{kind}/pages/p{page}.png'


def word_backgrounds(img, words):
    """The most common colour (5 bits a channel) of each word box: the background behind a word, a chip or the plain page. Returns an (n, 3) array."""
    H, W, _ = img.shape
    out = np.zeros((len(words), 3), dtype=np.float32)
    for i, w in enumerate(words):
        x0, y0 = int(max(0, w[2] + 1)), int(max(0, w[3] + 1))
        x1, y1 = int(min(W, w[2] + w[4] - 1)), int(min(H, w[3] + w[5] - 1))
        if x1 <= x0 or y1 <= y0:
            continue
        q = img[y0:y1, x0:x1].reshape(-1, 3) >> 3
        code = (q[:, 0].astype(np.int32) << 10) | (q[:, 1].astype(np.int32) << 5) | q[:, 2].astype(np.int32)
        k = int(np.bincount(code).argmax())
        out[i] = ((k >> 10) << 3 | 4, ((k >> 5) & 31) << 3 | 4, (k & 31) << 3 | 4)
    return out


def load_set(setname, labels_root=None):
    """-> list of block dicts (the label record + 'set', 'ocr' {r, w}, 'feed' {bg, frame, lines, r}, 'img' (W, H), 'wbg' (n, 3), 'rules' {...})."""
    root = labels_root or KL
    lab, kind, feed = SETS[setname]
    recs = [json.loads(l) for l in open(os.path.join(root, lab))]
    head = recs[0]
    feeds = {}
    for l in open(f'{SCRATCH}/feed-{feed}.jsonl'):
        r = json.loads(l); feeds[r['id']] = r
    rules = {}
    rpath = f'{SCRATCH}/rules-{feed}.jsonl'
    if os.path.exists(rpath):
        for l in open(rpath):
            r = json.loads(l); rules[r['id']] = r
    cases = {c['case']: c for c in head.get('cases', [])}
    blocks = []
    ocr_cache, img_cache = {}, {}
    for r in recs[1:]:
        if r['kind'] != 'block': continue
        o, png = _ocr_and_png(setname, r, ocr_cache)
        ob = o[r['read']][int(r['id'].rsplit('-', 1)[1])]
        assert ob['t'] == r['text'], r['id']
        if png not in img_cache:
            img_cache.clear()
            im = Image.open(png).convert('RGB')
            img_cache[png] = np.asarray(im)
        arr = img_cache[png]
        c = cases.get(r['paper'], {})
        r['set'] = setname
        r.setdefault('lang', c.get('lang', 'en'))
        r.setdefault('scene', c.get('scene', r['paper']))
        r.setdefault('look', c.get('look', ''))
        r['ocr'] = {'r': ob['r'], 'w': ob['w']}
        r['feed'] = feeds.get(r['id'])
        r['img'] = (arr.shape[1], arr.shape[0])
        r['png'] = png
        r['wbg'] = word_backgrounds(arr, ob['w'])
        r['rules'] = rules.get(r['id'])
        blocks.append(r)
    return blocks


def load_all(sets=None, rebuild=False):
    out = {}
    os.makedirs(f'{SCRATCH}/cache', exist_ok=True)
    for s in sets or (TRAIN_SETS + TEST_SETS):
        p = f'{SCRATCH}/cache/{s}.pkl'
        if os.path.exists(p) and not rebuild:
            out[s] = pickle.load(open(p, 'rb'))
        else:
            out[s] = load_set(s)
            pickle.dump(out[s], open(p, 'wb'))
    return out


if __name__ == '__main__':
    d = load_all(rebuild='--rebuild' in sys.argv)
    for s, bl in d.items():
        c = collections.Counter((b['read'], b['keep']) for b in bl)
        print(s, len(bl), 'blocks; no feed', sum(1 for b in bl if b['feed'] is None), '; no rules', sum(1 for b in bl if b['rules'] is None), dict(sorted(c.items())))
