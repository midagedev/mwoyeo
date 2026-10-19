#!/usr/bin/env python3
"""Which pages of a paper PDF are densest in inline mathematics: the pages for the side-cut crops of tools/paper-bench/pages.sh (SIDE).
Usage: python3 -I mathdense.py <pdf> [how many, default 2]       (needs pdftotext and pdfinfo from poppler)
Prints one line per page (words, signs of mathematics, signs per 1000 words) and, last, the SIDE value. The signs are those of
tools/paper-bench/score.py (MATH: = ∈ × ∑ √ ^ _ ... or a call with one-letter arguments) and the Greek letters the paper uses as symbols."""
import re
import subprocess
import sys

MATH = re.compile(r'[=∈×∑√^_∞≈≠≤≥±∂∇∫∏→←ρλσφΔωπ]|[A-Za-z]\w* ?\(\s*[A-Za-z](?:\s*,\s*[A-Za-z])*\s*\)')
pdf = sys.argv[1]
keep = int(sys.argv[2]) if len(sys.argv) > 2 else 2
pages = int(re.search(r'Pages:\s+(\d+)', subprocess.run(['pdfinfo', pdf], capture_output=True, text=True, check=True).stdout).group(1))
rows = []
for p in range(1, pages + 1):
    text = subprocess.run(['pdftotext', '-f', str(p), '-l', str(p), pdf, '-'], capture_output=True, text=True, check=True).stdout
    words, signs = len(text.split()), len(MATH.findall(text))
    rows.append((p, words, signs, round(1000 * signs / max(words, 1))))
    print(f'p{p}: {words} words, {signs} signs, {rows[-1][3]} per 1000 words')
best = sorted(rows, key=lambda r: -r[3])[:keep]
print('SIDE="' + ' '.join(str(r[0]) for r in sorted(best)) + '"')
