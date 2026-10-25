#!/bin/bash
# film: a Release build -> a film snapshot under /tmp/film4/builds (pool4 ids, no NSServices, ad-hoc re-signed with its own entitlements).
# usage: mkbuild.sh <Mwoyeo.app> <name>   -> prints the MacOS binary
app=${1%/}; D=/tmp/film4/builds/$2; A=$D/Mwoyeo.app
rm -rf "$D"; mkdir -p "$D" && ditto "$app" "$A" || exit 1
codesign -d --entitlements :- "$app" > "$D/ent.plist" 2>/dev/null
for p in "$A"/Contents/XPCServices/*.xpc/Contents/Info.plist "$A/Contents/Info.plist"; do
  x=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$p")
  case $x in dev.midagedev.mwoyeo.pool4*) ;; dev.midagedev.mwoyeo*) /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.midagedev.mwoyeo.pool4${x#dev.midagedev.mwoyeo}" "$p" ;; esac
done
/usr/libexec/PlistBuddy -c "Delete :NSServices" "$A/Contents/Info.plist" 2>/dev/null
for x in "$A"/Contents/XPCServices/*.xpc; do codesign -d --entitlements :- "$x" > "$D/xent.plist" 2>/dev/null; codesign --force --sign - --entitlements "$D/xent.plist" "$x" >/dev/null 2>&1; done
codesign --force --sign - --entitlements "$D/ent.plist" "$A" > "$D/codesign.log" 2>&1
codesign --verify --deep --strict "$A" || { echo verify failed; exit 1; }
echo "$A/Contents/MacOS/Mwoyeo"
