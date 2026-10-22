#!/bin/bash
# fast117: the one way the first-paint tools start a Mwoyeo dev binary. Refuses unless the run is scoped to scratch state.
# FAILURE MODE IT BLOCKS (2026-10-22): a bare launch of a dev build rewrote the user's ~/Library/Application Support/Mwoyeo/settings.schema.json.
# usage: MWOYEO_SETTINGS_FILE=/tmp/... MWOYEO_DEFAULTS_SUITE=fast117.<x> MWOYEO_MEMORY_SECRETS=1 app.sh <Mwoyeo binary> [args...]
set -u
bin=${1:?app.sh <binary> [args]}; shift
case ${MWOYEO_SETTINGS_FILE:-} in /tmp/*) ;; *) echo "app.sh: MWOYEO_SETTINGS_FILE must be under /tmp (is '${MWOYEO_SETTINGS_FILE:-}')" >&2; exit 64 ;; esac
case ${MWOYEO_DEFAULTS_SUITE:-} in fast117.*) ;; *) echo "app.sh: MWOYEO_DEFAULTS_SUITE must start with fast117. (is '${MWOYEO_DEFAULTS_SUITE:-}')" >&2; exit 64 ;; esac
[ "${MWOYEO_MEMORY_SECRETS:-}" = 1 ] || { echo "app.sh: MWOYEO_MEMORY_SECRETS=1 is required" >&2; exit 64; }
case $bin in */Contents/MacOS/Mwoyeo) ;; *) echo "app.sh: $bin is not an app binary" >&2; exit 64 ;; esac
id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${bin%/MacOS/Mwoyeo}/Info.plist")
[ "$id" != dev.midagedev.mwoyeo ] || { echo "app.sh: $bin carries the user's bundle id" >&2; exit 64; }
exec "$(cd "$(dirname "$0")/.." && pwd)/ane-env.sh" run pool -- "$bin" "$@"
