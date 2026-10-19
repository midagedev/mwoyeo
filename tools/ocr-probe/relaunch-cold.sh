#!/bin/bash
# Does killing the app during the cold revision 3 compile restart it? (first-run audit, finding 10.) Two copies of a built
# Mwoyeo.app get a fresh bundle identifier each (`ane-env.sh id cold`; the system's compile cache is keyed by it; a copy at a new path
# with the same identifier stays warm), then:
#   B  baseline: a cold run to the end, so that the cold compile time on this machine, today, is known;
#   A1 a cold run killed KILL_AT seconds in, A2 the same binary started at once: its textModel time against B's says whether
#      the compile restarted (A2 ~ B) or went on (A2 ~ B - KILL_AT).
# Needs the Bash sandbox off and one run at a time. Every launch is `ane-env.sh run cold` (no seeding, the Neural Engine lease), so no
# other leased cold start compiles meanwhile; the compiler service's networks of the whole run are printed once at the end
# (tools/ane-census). Reads the times from `--capture-ui vision-reads` ("textModel=done(64.3s)").
#   APP=<built Mwoyeo.app> [OUT=/tmp/relaunch-cold] [KILL_AT=30] bash relaunch-cold.sh
# 2026-10-18 (first-run, macOS 27, other rounds rendering meanwhile): B 64.3 s, A2 62.0 s after a kill at 30 s; this script, again: 64.0 s and
# 62.8 s (the ANE service was at 97 % CPU when the first copy was killed and still is when the second starts). The compile restarts.
APP=${APP:?set APP to a built Mwoyeo.app}
OUT=${OUT:-/tmp/relaunch-cold}
KILL_AT=${KILL_AT:-30}
TOOLS=$(cd "$(dirname "$0")/.." && pwd); ANE=$TOOLS/ane-env.sh
T0=$(date '+%Y-%m-%d %H:%M:%S')
export MWOYEO_MEMORY_SECRETS=1 MWOYEO_SETTINGS_FILE=$OUT/settings.json MWOYEO_DEFAULTS_SUITE=relaunch.cold.$$
rm -rf "$OUT"; mkdir -p "$OUT/A" "$OUT/B"
snap() { echo "[$(date +%H:%M:%S)] $1"; }
for X in A B; do
  ID=$("$ANE" id cold)
  cp -R "$APP" "$OUT/$X/Mwoyeo.app"
  plutil -replace CFBundleIdentifier -string "$ID" "$OUT/$X/Mwoyeo.app/Contents/Info.plist"
  codesign --force --deep --sign - --identifier "$ID" --preserve-metadata=entitlements "$OUT/$X/Mwoyeo.app" 2>&1 | tail -1
done
# run <name> <app>: the pid goes to $OUT/<name>.pid (waited on, signalled, only by that pid)
run() {
  "$ANE" run cold -- "$2/Contents/MacOS/Mwoyeo" --capture-ui "$OUT/out-$1" vision-reads --src ja --for 400 > "$OUT/$1.log" 2>&1 &
  echo $! > "$OUT/$1.pid"
}
guarded_wait() { ( sleep 450; kill -0 "$1" 2>/dev/null && kill "$1" ) & local g=$!; wait "$1"; kill $g 2>/dev/null; }
snap "B start"
run B "$OUT/B/Mwoyeo.app"; guarded_wait "$(cat "$OUT/B.pid")"; snap "B end"
sleep 5
snap "A1 start"
run A1 "$OUT/A/Mwoyeo.app"; PA=$(cat "$OUT/A1.pid"); sleep "$KILL_AT"
snap "A1 kill"; kill "$PA"; wait "$PA" 2>/dev/null
snap "A2 start"
run A2 "$OUT/A/Mwoyeo.app"; guarded_wait "$(cat "$OUT/A2.pid")"; snap "A2 end"
for n in B A2; do echo "$n: $(grep -o 'textModel=done([0-9.]*s)' "$OUT/$n.log" | head -1)"; done
python3 -I "$TOOLS/ane-census/census.py" window "$T0"
