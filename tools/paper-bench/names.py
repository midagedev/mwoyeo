#!/usr/bin/env python3
"""Names inside translated sentences, and what became of them (round read117, item 3).
Usage: names.py <bench out dir> [--list]      (python3 -I; exit 1 when a name came back in another case)

The sources of the render (`<scene>.out`: the lines with two spaces in front, the translation on the line after it, after "→") are read for
tokens that are names of code: a capital after a lowercase letter, a digit, an underscore, or a dot or slash inside ("fitFontSize",
"TextFitter.fitFontSize", "step_duration", "gemma3", "src/app"; not "NASA", "SUPER QUEST" or "Wi-Fi", which are words, and narrower than
`isNameShaped` in Core/Sources/MwoyeoCore/Text.swift, which also takes the acronyms). For every one of them in a source that was translated,
the translation holds it
  exact   as written,
  recased the same letters in another case ("fitfontsize": `TranslationCleanup.restoreSourceTokens` should have given it back),
  lost    not at all (the engine translated or split it: "ledgerline" -> "원장 라인"; the OCR split it: "FrameDiff. swift").
`recased` is the gate (it must be 0); `lost` is counted and listed."""
import glob
import os
import re
import sys

TOKEN = re.compile(r"[A-Za-z][A-Za-z0-9_/.\-]*")


def shaped(name):
    return re.search(r"[a-z][A-Z]", name) is not None or any(c.isdigit() or c in "_./" for c in name[1:])


def names(source):
    for m in TOKEN.finditer(source):
        t = m.group(0).rstrip("./-")
        if len(t) >= 3 and shaped(t):
            yield t


def pairs(path):
    lines = open(path, errors="replace").read().split("\n")
    for i, line in enumerate(lines):
        if line.startswith("  ") and not line.startswith("   ") and not line.startswith("  →") and i + 1 < len(lines) \
                and lines[i + 1].startswith("    → "):
            yield line[2:], lines[i + 1][6:]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    count = {"exact": 0, "recased": 0, "lost": 0}
    rows = []
    for out in sorted(glob.glob(os.path.join(args[0], "*.out"))):
        scene = os.path.basename(out)[:-4]
        for source, translation in pairs(out):
            if translation == source:
                continue   # kept as written: nothing to give back
            for name in names(source):
                if name in translation:
                    count["exact"] += 1
                elif name.lower() in translation.lower():
                    count["recased"] += 1
                    rows.append((scene, "recased", name, translation))
                else:
                    count["lost"] += 1
                    rows.append((scene, "lost", name, source))
    print("names: exact %(exact)d, recased %(recased)d, lost %(lost)d" % count)
    if "--list" in sys.argv:
        for scene, what, name, text in rows:
            print(f"  {scene} {what}: {name}   {text[:70]!r}")
    sys.exit(1 if count["recased"] else 0)


if __name__ == "__main__":
    main()
