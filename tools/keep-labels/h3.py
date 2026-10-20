#!/usr/bin/env python3
"""H3: the generator of h2.py with the scenes of h3_scenes.py (round h3, 2026-10-20).
usage: h3.py <out dir>        writes the same files as h2.py: <name>.html, <name>.units.json, index.tsv, MANIFEST.tsv (compare with h3/MANIFEST.tsv)"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h2
import h3_scenes                                      # sets h2.PIN / h2.SRC and registers the looks before h2.main runs

if __name__ == '__main__':
    h2.main('h3_scenes')
