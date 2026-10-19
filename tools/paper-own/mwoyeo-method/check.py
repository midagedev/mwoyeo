#!/usr/bin/env python3
"""Checks that the facts of the paper are still true of the code: every row of sources.tsv names a needle and the place it must be.
Usage: python3 -I check.py [--ref REV] [--sources FILE] [--repin]

  path:line   the needle must be on that line of the file (the working tree, or REV with `--ref REV` through `git show`, read only)
  cmd:...     the command runs from the repository root (working tree) and the needle must be in its output; only python3 -I commands
              of this repository run
  listings/   each listing of the paper must equal the lines of the source that build.sh cuts it from
  refs        every key of refs.bib has a line in sources/refs.txt

Exit 0 when every row holds. A row that fails prints where the needle is now (if it is still in the file), so the paper's sentence and the row
can be moved together; rc 1. `--sources FILE` reads another table (the FAIL-first run plants one wrong needle in a copy). `--repin` (working tree) moves a row to the line
where its needle now is when that is the only line of the file that holds it; it never changes a needle, so a changed constant still fails."""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
ref = None
repin = False
sources = os.path.join(HERE, 'sources.tsv')
args = sys.argv[1:]
while args:
    a = args.pop(0)
    if a == '--ref':
        ref = args.pop(0)
    elif a == '--sources':
        sources = args.pop(0)
    elif a == '--repin':
        repin = True
    else:
        sys.exit(__doc__)


def source(path):
    if ref is None:
        return open(os.path.join(ROOT, path), encoding='utf-8').read().split('\n')
    out = subprocess.run(['git', '-C', ROOT, 'show', f'{ref}:{path}'], capture_output=True, text=True, check=True)
    return out.stdout.split('\n')


failures, rows, cmds, moved = [], 0, {}, {}
table = open(sources, encoding='utf-8').read().split('\n')
for n, raw in enumerate(table, 1):
    if not raw or raw.startswith('#'):
        continue
    needle, where, section, claim = raw.split('\t')
    rows += 1
    if where.startswith('cmd:'):
        cmd = where[4:]
        if not re.match(r'^(cd tools/[\w-]+ && )?python3 -I [\w./ -]+$', cmd):
            failures.append(f'row {n}: command not allowed: {cmd}')
            continue
        if cmd not in cmds:
            cmds[cmd] = subprocess.run(['bash', '-c', cmd], cwd=ROOT, capture_output=True, text=True).stdout
        if needle not in cmds[cmd]:
            failures.append(f'row {n} [{section}]: `{needle[:80]}` is not in the output of: {cmd}')
        continue
    path, _, line = where.rpartition(':')
    try:
        lines = source(path)
    except (OSError, subprocess.CalledProcessError):
        failures.append(f'row {n} [{section}]: {path} cannot be read (moved or deleted?)')
        continue
    if int(line) > len(lines) or needle not in lines[int(line) - 1]:
        now = [i + 1 for i, l in enumerate(lines) if needle in l]
        if repin and ref is None and len(now) == 1:
            moved[n] = f'{path}:{now[0]}'
            continue
        failures.append(f'row {n} [{section}]: `{needle[:80]}` is not on {where}' + (f'; it is now on line {now[0]}' if now else '; it is gone')
                        + f'\n      claim: {claim}')

if moved:
    for n, where in moved.items():
        cells = table[n - 1].split('\t')
        cells[1] = where
        table[n - 1] = '\t'.join(cells)
    open(sources, 'w', encoding='utf-8').write('\n'.join(table))
    print(f'check.py: {len(moved)} rows moved to the line where their needle is now')

# the listings are cut from the sources by build.sh: they must equal what the sources say now
build = open(os.path.join(HERE, 'build.sh'), encoding='utf-8').read()
for name, path, a, b in re.findall(r'^listing (\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s*$', build, re.M):
    try:
        cut = '\n'.join(source(path)[int(a) - 1:int(b)]) + '\n'
        have = open(os.path.join(HERE, 'listings', name), encoding='utf-8').read()
    except (OSError, subprocess.CalledProcessError):
        failures.append(f'listing {name}: cannot be read')
        continue
    rows += 1
    if cut != have:
        failures.append(f'listing {name} differs from {path}:{a}-{b}: run build.sh again, and check that the paper still describes these lines')

# every reference has its fetched line
bib = re.findall(r'^@\w+\{(\w+),', open(os.path.join(HERE, 'refs.bib'), encoding='utf-8').read(), re.M)
fetched = {l.split(' | ')[0] for l in open(os.path.join(HERE, 'sources', 'refs.txt'), encoding='utf-8') if l.strip() and not l.startswith('#')}
for key in bib:
    rows += 1
    if key not in fetched:
        failures.append(f'reference {key} has no line in sources/refs.txt')

if failures:
    print(f'check.py: FAIL {len(failures)} of {rows} rows' + (f' (against {ref})' if ref else ''))
    for f in failures:
        print('  ' + f)
    sys.exit(1)
print(f'check.py: PASS {rows} rows' + (f' (against {ref})' if ref else ' (working tree)'))
