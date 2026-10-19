#!/usr/bin/env python3
"""Which MWOYEO_ environment names a built binary can read, including the short ones `strings` cannot see.
Usage: python3 -I scripts/mas-env-scan.py <binary> [NAME ...]      (no NAME: every MWOYEO_ name found in App/ Core/Sources Shared Reader)

Swift keeps a string literal of up to 15 bytes (MWOYEO_KEEP, MWOYEO_PREDICT, MWOYEO_PLAN, ...) in the instructions as two 64-bit
immediates, not in the string table, so `strings` finds the long names and none of the short ones (measured 2026-10-19: a MAS build
with the `#if MAS` branches of MWOYEO_KEEP and MWOYEO_PREDICT flipped has 0 `strings` hits for them). This reads the disassembly of
every slice (`otool -tV`: arm64 mov/movk runs, x86_64 movabs) and rebuilds the 64-bit constants a small literal becomes.
Prints one line per name: the `strings` hits and the immediate hits per slice; rc 1 when any NAME given on the command line is in the
binary (the gate: `scripts/mas-env-scan.py <MAS binary> MWOYEO_KEEP MWOYEO_PREDICT` must print 0 and 0 and exit 0)."""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))


def small_words(name):
    """The two 64-bit words Swift materialises for a literal of at most 15 UTF-8 bytes (the second one carries 0xE0 | count on top)."""
    b = name.encode()
    if len(b) > 15:
        return None
    b = b.ljust(16, b'\0')
    lo = int.from_bytes(b[:8], 'little')
    hi = int.from_bytes(b[8:15], 'little') | ((0xE0 | len(name.encode())) << 56)
    return lo, hi


def slices(binary):
    out = subprocess.run(['lipo', '-archs', binary], capture_output=True, text=True)
    return out.stdout.split() or [None]


def constants(binary, arch):
    """Every 64-bit constant the instructions of one slice build: arm64 mov/movk runs, x86_64 movabs and 32-bit immediates."""
    cmd = ['otool', '-tV'] + (['-arch', arch] if arch else []) + [binary]
    text = subprocess.run(cmd, capture_output=True, text=True, errors='replace').stdout
    found = set()
    live = {}
    for line in text.split('\n'):
        m = re.search(r'\t(mov|movz|movk)\t([wx]\d+), #(0x[0-9a-f]+)(?:, lsl #(\d+))?', line)
        if m:
            op, reg, imm, shift = m.group(1), m.group(2), int(m.group(3), 16), int(m.group(4) or 0)
            reg = 'x' + reg[1:]
            if op == 'movk':
                live[reg] = (live.get(reg, 0) & ~(0xffff << shift)) | (imm << shift)      # movk replaces 16 bits and keeps the rest
            else:
                live[reg] = imm << shift
            found.add(live[reg])
            continue
        for h in re.findall(r'(?:\$|imm = )(0x[0-9a-fA-F]{8,16})', line):       # a high-bit constant is "$-0x..." with "## imm = 0x..."
            found.add(int(h, 16))
    return found


def names_in_source():
    names = set()
    for d in ('App', 'Core/Sources', 'Shared', 'Reader'):
        for base, _, files in os.walk(os.path.join(ROOT, d)):
            for f in files:
                if f.endswith('.swift'):
                    names |= set(re.findall(r'"(MWOYEO_[A-Z0-9_]+)"', open(os.path.join(base, f), errors='replace').read()))
    return sorted(names)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    binary, wanted = sys.argv[1], sys.argv[2:]
    names = wanted or names_in_source()
    strings = subprocess.run(['strings', '-a', binary], capture_output=True, text=True, errors='replace').stdout
    consts = {a: constants(binary, a) for a in slices(binary)}
    bad = 0
    for name in names:
        s = strings.count(name)
        words = small_words(name)
        imm = {}
        for arch, cs in consts.items():
            if words is None:
                imm[arch or 'native'] = '-'
            else:
                # The first word alone is shared by every name with the same eight leading bytes; the pair is the name.
                imm[arch or 'native'] = int(words[0] in cs and (words[1] in cs or len(name) <= 8))
        print(f'{name:28s} strings {s}  immediates {imm}')
        if wanted and (s or any(v == 1 for v in imm.values())):
            bad = 1
    sys.exit(bad)


main()
