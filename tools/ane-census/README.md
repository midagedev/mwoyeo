# ane-census

What the system's Neural Engine compiler (`ANECompilerService`, a root service, one compile at a time) did, and what the e5rt caches hold. It reads logs and directories; it never compiles, so it is safe to run while anything else is compiling.

```
python3 -I census.py window '2026-10-19 22:00:00' ['2026-10-19 22:30:00'] [--out svc.log]   # one log show, then net
python3 -I census.py net svc.log [more.log]       # the same on logs saved earlier
python3 -I census.py tmp [~/Library/Caches]       # *.tmp.<pid>_<n>.bundle leftovers of aborted compiles
python3 -I census.py caches [~/Library/Caches]    # bundles per cache id, ids created per day
python3 -I census.py diag [file-or-dir ...]       # cpu_resource / .diag reports of ANECompilerService
```

`window` runs `/usr/bin/log show --predicate 'process == "ANECompilerService"' --info --debug` once. A call costs 10 s or more: take one after a run (tools/paper-bench/run.sh and ocr-probe/relaunch-cold.sh do), never one per snapshot. In zsh call `/usr/bin/log`: the builtin `log` fails silently.

## Reading it

- **`pid N: <n> networks, busy <s> s`** is the service instance's compile time. Divide by the instance's life before you call it spinning: the `etime` of `ps` is the age of the process, not CPU time (2026-10-19: pid 95258, 6 h old, was busy 5 %).
- **Bursts** (a gap over 60 s starts a new one) with `n` networks and a few seconds between them are a queue of clients, not a loop: 34 networks in 11 minutes at gaps of 3 s or less was the 22:09-22:20 saturation. Each network is ~28 s and the lane takes one at a time.
- **`unfinished`** is a Start without an End: the compile a `kill -9` of the service cut, or one still running when the log was taken.
- **Signatures** count the same network compiled again (procedures + the three smallest Dram sizes). The e5rt cache is content addressed, so the same 2-3 signatures reappear for every new bundle id: that is what `tools/ane-env.sh` seeding avoids.
- **`tmp`** lists the aborted compiles by the pid of the process that started them (the client, not the service). **`caches`** counts the dirs a round made: each new id is about 100 s of serial compile.
- **`diag`** gives when the OS reported the service over its CPU limit (`cpu_resource.diag`), for whom the samples were taken (`On Behalf Of`), and the CPU line. Reports sit in `/Library/Logs/DiagnosticReports` and are readable by an admin user.

`tools/ane-lease/check.sh` runs these on synthetic input (the numbers above are pinned there).
