# ocr-probe
Times one Vision text request, to tell a stalled recognizer from a slow one. Build `swiftc -O probe.swift -o probe`; run `./probe chat.png accurate [revision] [ja] [seconds]` (or `fast`, `accurate-cpu`: every stage on the CPU).
It prints the system's revisions and languages, then `lines=<n> <seconds>` or `no answer in <n> s` (default 40 s, exit 1).
Healthy Mac: revision 3 (the default, the only one that reads ja/ko) answers in ~30 s the first time (the models compile) and ~0.3 s after; revision 2 and `.fast` in under 0.3 s.
Stalled (2026-10-17): revision 3 never answers and `ANECompilerService` (root) spins at 60-99 % CPU, while revision 2 and `.fast` still answer.
Never kill `ANECompilerService` or a probe that is still loading: a client that goes away restarts the compile.
