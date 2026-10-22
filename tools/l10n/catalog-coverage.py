#!/usr/bin/env python3
"""Every string the compiler extracts from the app is in the catalog, translated into every language the catalog carries.

usage: catalog-coverage.py <derived data dir> [<Localizable.xcstrings>]
Reads the .stringsdata files the Swift compiler writes on a build (the same extraction Xcode uses), so a key in a
LocalizedStringKey, Text or String(localized:) is found however it is written. Blocks a key that ships in English to every
language because it never reached the catalog (vision-final FIX-2, 2026-10-21: three AppMemorySheet captions).
Exit 0 when complete, 1 with one line per missing key or language.
"""
import glob, json, os, sys

dd = sys.argv[1]
catalog = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "../../App/Resources/Localizable.xcstrings")
doc = json.load(open(catalog))
strings = doc["strings"]
langs = sorted({l for v in strings.values() for l in v.get("localizations", {})} - {doc.get("sourceLanguage", "en")})

used = {}
files = glob.glob(os.path.join(dd, "Build/Intermediates.noindex/Mwoyeo.build/**/*.stringsdata"), recursive=True)
if not files:
    sys.exit(f"no .stringsdata under {dd}: build the app first")
for f in files:
    d = json.load(open(f))
    for e in d.get("tables", {}).get("Localizable", []):
        # The App Intents extractor writes a summary string ("Translate ${text}") with no location.
        used.setdefault(e["key"], f"{os.path.basename(d['source'])}:{e.get('location', {}).get('startingLine', 0)}")

problems = []
for key, where in sorted(used.items(), key=lambda kv: kv[1]):
    entry = strings.get(key)
    if entry is None:
        problems.append(f"{where}: not in the catalog: {key!r}")
        continue
    if entry.get("shouldTranslate") is False:
        continue
    have = entry.get("localizations", {})
    missing = [l for l in langs if have.get(l, {}).get("stringUnit", {}).get("state") != "translated"
               and "variations" not in have.get(l, {})]
    if missing:
        problems.append(f"{where}: {key!r} missing {', '.join(missing)}")

print(f"catalog-coverage: {len(used)} keys from {len(files)} files, {len(langs)} languages, {len(problems)} problems")
for p in problems:
    print("  " + p)
sys.exit(1 if problems else 0)
