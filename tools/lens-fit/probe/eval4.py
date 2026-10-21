"""fit117 measurement 5: what the estimator claims on scenes that have no text column (chat, games, UI, code) and on the ones that do (documents, paper pages).
tools/usecase-bench scenes (52), the app's own pipeline output (uc-d14, auto reader), blocks of each scene -> columns(). `claims` = any column found."""
import sys, glob, os, collections; sys.path.insert(0, '/tmp/r117/fit117/probe')
from common import *
from columns import columns
OUT = '/tmp/r117/fit117/data/uc-d14'
cat = {'c': 'chat', 'd': 'document/UI', 'g': 'game', 'k': 'code/terminal/docs', 'p': 'paper', 'w': 'web', 's': 'slides', 'm': 'manga'}
rows = collections.defaultdict(list)
for f in sorted(glob.glob(f'{OUT}/*-auto.out')):
    name = os.path.basename(f)[:-9]
    bl = blocks(f); cols = columns(bl)
    rows[cat.get(name[0], name[0])].append((name, len(bl), cols))
for k, v in rows.items():
    print('== %s: %d scenes, %d claim a column' % (k, len(v), sum(1 for _, _, c in v if c)))
    for name, n, cols in v:
        print('   %-28s blocks %3d  columns %s' % (name, n, [(round(c['left']), round(c['right']), c['blocks'], c['lines']) for c in cols]))
