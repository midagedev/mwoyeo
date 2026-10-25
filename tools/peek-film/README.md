# peek-film: takes of the whole screen while held (1.1.8, `Peek`)
Rebuilt 2026-10-26 after a restart emptied /tmp, where film4/film5's tools lived. The scripts still run from /tmp: copy them there first
(`/tmp/film4/tools/{post,webwin,app.sh}` built with `swiftc -O`, `/tmp/film5/tools/{peek.py,mkbuild.sh}`, `/tmp/film5/stage/*.html`).

| path | what |
|---|---|
| `mkbuild.sh <Mwoyeo.app> <name>` | a Release build as a film snapshot under /tmp/film4/builds: pool4 bundle ids (never the user's), no NSServices, ad-hoc signed with its own entitlements |
| `app.sh` | the only way a take starts a build: refuses unless settings, defaults suite and secrets are scratch |
| `webwin.swift` | the stage: a backdrop over the desktop and one WKWebView window per page (`url\|x\|y\|w\|h\|title`, top-left points) |
| `post.swift` | posted input on the uptime clock (`path`, `click`, `key`, `keydown`/`keyup` with `ctrl,opt`…) |
| `peek.py <shot.json> <out>` | one take: stage, app, ffmpeg capture of the main display at 60 fps, the shot's steps; `events.jsonl` and `app.err` share the uptime clock. Run it under `lockf /tmp/r117/screen.lock` |
| `gates.sh <tag> <check>...` | `--capture-ui` gates one at a time under the screen lock (`BIN=<Mwoyeo>`); a line per check in /tmp/film5/gates/summary.txt |
| `stage/`, `shots/` | the pages (an article, a Japanese chat, an API doc) and the 1.1.8 take (`p9b-bounds`: three holds of ⌃⌥P) |
