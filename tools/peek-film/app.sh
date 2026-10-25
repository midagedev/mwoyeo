#!/bin/bash
# film4: the only way this round starts a Mwoyeo build. Refuses unless the run is scoped to scratch state, so a launch can never read or
# write the user's settings (~/Library/Application Support/Mwoyeo), defaults (dev.midagedev.mwoyeo) or keys.
# FAILURE MODE IT BLOCKS: 2026-10-22 09:33 a bare `Mwoyeo --help` on a snapshot started the GUI on the default settings path and rewrote the
# user's settings.schema.json. Usage: MWOYEO_SETTINGS_FILE=/tmp/film4/... MWOYEO_DEFAULTS_SUITE=film4.<x> MWOYEO_MEMORY_SECRETS=1 app.sh <Mwoyeo binary> [args...]
set -u
bin=${1:?app.sh <binary> [args]}; shift
case ${MWOYEO_SETTINGS_FILE:-} in /tmp/film4/*) ;; *) echo "app.sh: MWOYEO_SETTINGS_FILE must be under /tmp/film4 (is '${MWOYEO_SETTINGS_FILE:-}')" >&2; exit 64 ;; esac
case ${MWOYEO_DEFAULTS_SUITE:-} in film4.*) ;; *) echo "app.sh: MWOYEO_DEFAULTS_SUITE must start with film4. (is '${MWOYEO_DEFAULTS_SUITE:-}')" >&2; exit 64 ;; esac
[ "${MWOYEO_MEMORY_SECRETS:-}" = 1 ] || { echo "app.sh: MWOYEO_MEMORY_SECRETS=1 is required" >&2; exit 64; }
case $bin in /tmp/film4/builds/*/Mwoyeo.app/Contents/MacOS/Mwoyeo|/tmp/r117/fit117-try/Mwoyeo.app/Contents/MacOS/Mwoyeo) ;;
    *) echo "app.sh: $bin is not a film4 snapshot or the fit117 try build" >&2; exit 64 ;; esac
id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${bin%/MacOS/Mwoyeo}/Info.plist")
[ "$id" != dev.midagedev.mwoyeo ] || { echo "app.sh: $bin carries the user's bundle id" >&2; exit 64; }
exec "$bin" "$@"
