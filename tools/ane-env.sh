#!/bin/bash
# The one place that knows how a dev run meets the system's Neural Engine compiler: the lease, the id pool and the disk floor. Round
# ane-dev, 2026-10-20 (reports: round ane-root).
#
# WHY. ANECompilerService compiles ONE network at a time (~28 s each). A run on a bundle id that has no e5rt cache yet needs 2-3 of
# them (~100 s); parallel rounds each starting such runs queue up in that one lane, and every OCR read on the Mac, the user's app
# included, waits behind them (2026-10-17 4.5 h, 2026-10-19 22:01-22:20). A compile also preallocates ~2.4 GB; on a full disk it
# fails, caches nothing and retries.
# THE CACHE BELONGS TO ITS ID (E4, 2026-10-20): the three cache dirs of a warm id cloned by `cp -cR` into a fresh id's before its first
# launch removed no compile (seeded 102 s, 5 compiles; unseeded 102 s, 5 compiles, same build), while the same id on its third run
# read in 3 s with 0 compiles. So nothing here seeds: a round builds ONE pool id and keeps it (`ane-env.sh id pool`).
#
# USAGE. Executed, not sourced, so that it can sit in front of any launch (a pipe, a `&`, a zsh script): the command it starts
# REPLACES it (exec), so `$!` of `ane-env.sh run ... &` is that command's pid, or the lease's, which forwards TERM/INT/HUP to it.
#   ane-env.sh run <kind> -- <cmd ...>   start <cmd> the way <kind> says (below). The first word of <cmd> under */Contents/MacOS/ is
#                                        the app: its Info.plist gives the bundle id, which says whether the run may compile.
#   ane-env.sh id <kind>                 print the bundle id a build for that kind takes (MWOYEO_APP_ID=$(ane-env.sh id pool))
# THE POLICY is the table below, read by one function; a script says only which kind it is:
#   pool  a pool id (dev.midagedev.mwoyeo.pool<N>, one per worktree, kept across runs); the lease is taken only while the id's three
#         caches (the app's, .reader.lines, .reader.docs) hold no compiled bundle at all. Not "while one is missing": a warm id has
#         no app cache (the services compile; E4's id A had 4 + 6 bundles and no app dir) and a lines-only id never gets a docs cache
#   cold  a fresh id with an empty cache on purpose (a cold-path gate): the lease always
# THE LEASE is an flock on $ANE_LOCK held by a small python parent for as long as the command lives (the kernel queues the waiters
# and lets go when the holder dies, a SIGKILL included; no pid files, no polling). It prints `ane-lease: wait <s> s` and
# `ane-lease: held <s> s` to stderr. FAILURE MODE IT BLOCKS: two cold starts at once. Nothing waits on the clock or for a quiet
# machine: a run waits for the one holder in front of it. A command started inside a leased one (ANE_HELD set) does not take it again.
# ENV: ANE_LEASE=off  no lease (the mutation of tools/ane-lease/check.sh)      FREE_KB=<n>  free disk, injected for the gate
#      ANE_CACHE_ROOT (default ~/Library/Caches; only read)   ANE_LOCK (default ~/.cache/mwoyeo-gates/ane.lock)   ANE_SLOT (the pool
#      slot, default a hash of this worktree)
set -u

ANE_ID_BASE=dev.midagedev.mwoyeo
ANE_CACHE_ROOT=${ANE_CACHE_ROOT:-$HOME/Library/Caches}          # read here and nowhere else
ANE_LOCK=${ANE_LOCK:-$HOME/.cache/mwoyeo-gates/ane.lock}
ANE_POOL=4
# [provisional — backlog] 8 GiB = 2 service instances x 2.41 GB (the preallocation of one compile, measured 2026-10-19 23:51) = 4.8 GB,
# plus ~3 GB of build and render headroom. Re-pin when a run on a nearly full disk shows the real floor.
ANE_FLOOR_KB=8388608
CACHE=com.apple.e5rt.e5bundlecache
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

# kind  lease   id prefix  id suffix (a function below)
POLICY='pool cached pool slot
cold always cold fresh'

policy() {   # the row of a kind: sets KIND_ROW, or exits
    KIND_ROW=$(echo "$POLICY" | awk -v k="$1" '$1 == k')
    [ -n "$KIND_ROW" ] || { echo "ane-env: unknown kind '$1' (pool or cold)" >&2; exit 2; }
}
slot() { echo "${ANE_SLOT:-$(( $(printf %s "$ROOT" | cksum | cut -d' ' -f1) % ANE_POOL + 1 ))}"; }
fresh() { echo "$(date +%s)$(uuidgen | cut -c1-4 | tr A-Z a-z)"; }

cmd_id() {
    local prefix suffix
    policy "$1"; read -r _ _ prefix suffix <<< "$KIND_ROW"
    echo "$ANE_ID_BASE.$prefix$($suffix)"
}

bundle_id() {   # the id of the app the command starts; empty when it starts none
    local a
    for a in "$@"; do
        case $a in */Contents/MacOS/*) plutil -extract CFBundleIdentifier raw -o - "${a%/MacOS/*}/Info.plist" 2>/dev/null; return ;; esac
    done
}

cached() {   # 0 when the id has a compiled bundle in one of its three caches (an aborted `.tmp.` one does not count)
    [ -n "$1" ] && find "$ANE_CACHE_ROOT/$1"{,.reader.lines,.reader.docs}/"$CACHE" -name '*.bundle' ! -name '*.tmp.*' -print -quit 2>/dev/null | grep -q .
}

disk_ok() {   # one check at the top of every run
    local free=${FREE_KB:-$(df -k /System/Volumes/Data | awk 'NR == 2 {print $4}')}
    [ "$free" -ge "$ANE_FLOOR_KB" ] && return 0
    echo "ane-env: $((free / 1048576)) GiB free on /System/Volumes/Data, the floor is $((ANE_FLOOR_KB / 1048576)) GiB (a compile preallocates 2.4 GB, two service instances); free disk first" >&2
    return 1
}

LEASE_PY='
import fcntl, os, signal, subprocess, sys, time
lock, cmd = sys.argv[1], sys.argv[2:]
os.makedirs(os.path.dirname(lock), exist_ok=True)
fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o644)
child = None
def forward(n, _frame):
    if child: child.send_signal(n)
    else: sys.exit(128 + n)
for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(s, forward)
t0 = time.monotonic()
fcntl.flock(fd, fcntl.LOCK_EX)
t1 = time.monotonic()
os.ftruncate(fd, 0); os.write(fd, ("%d %d %s\n" % (os.getpid(), time.time(), " ".join(cmd)[:200])).encode())
print("ane-lease: wait %.1f s" % (t1 - t0), file=sys.stderr, flush=True)
child = subprocess.Popen(cmd, pass_fds=(fd,), env=dict(os.environ, ANE_HELD="1"))
rc = child.wait()
print("ane-lease: held %.1f s" % (time.monotonic() - t1), file=sys.stderr, flush=True)
sys.exit(rc if rc >= 0 else 128 - rc)
'

cmd_run() {   # run <kind> -- <cmd ...>
    local kind=${1:-} lease
    [ "${2:-}" = -- ] || { echo "usage: ane-env.sh run <pool|cold> -- <cmd ...>" >&2; exit 2; }
    policy "$kind"; read -r _ lease _ _ <<< "$KIND_ROW"
    shift 2
    disk_ok || exit 75
    if [ "${ANE_LEASE:-on}" != off ] && [ -z "${ANE_HELD:-}" ] && { [ "$lease" = always ] || ! cached "$(bundle_id "$@")"; }; then
        exec python3 -I -c "$LEASE_PY" "$ANE_LOCK" "$@"
    fi
    exec "$@"
}

case ${1:-} in
    run) shift; cmd_run "$@" ;;
    id) cmd_id "${2:?usage: ane-env.sh id <pool|cold>}" ;;
    *) echo "usage: ane-env.sh run <pool|cold> -- <cmd ...> | id <pool|cold>" >&2; exit 2 ;;
esac
