# Recognition architecture: read → recognise → translate → draw

Status: design, 2026-10-18, against main `feb7a12`. It replaces the stacked fixes around `TextRecognizer` with one design.
Implementation follows the rounds in §6.

## 0. Decisions in one page

- **No Vision request ever runs in the GUI process.** Vision runs in two XPC services bundled in the app:
  - `Lines` hosts `VNRecognizeTextRequest` rev3, rev2 and `.fast`.
  - `Docs` hosts `RecognizeDocumentsRequest`, plus `.fast` as an ANE-free stand-in.
- **One owner in the app.** `RecognitionHost` (actor) owns routing, scheduling, worker health, warm-up and stats. `TextRecognizer` becomes a thin facade with the same call sites.
- **No request is cancelled, abandoned or timed out by our side.**
  - The lens has a *patience* S. When S runs out, the router reroutes the read to the other worker or raises a hint.
  - The worker always runs the request to completion. A compile is never aborted by our side.
- **One request in flight per worker.** Latest frame wins per lens. Nothing piles up inside Vision's per-process lock.
- **Never silent.**
  - A lens either shows a translation, or says "Preparing text recognition" within S of its last candidate reader going quiet.
  - After 180 s it says "isn't responding". N = 8 s is the longest silent interval.
- **One backoff type.** All retry waits in the read and translate paths use it. No path retries immediately.
- **Headless tools use the same hosting** and drain before exit, so they measure the shipped shape and stop aborting compiles.
- **Dead code.** The `swiftTextModel` warm-up step, `SwiftVisionChild`, `SwiftVisionGate`, rev3 probing and the in-process deadline ladder all go.

## 1. What we know (inputs to the design)

| # | Fact | Number | Source |
|---|---|---|---|
| F1 | An ANE compile blocks every Vision request of the same process. Another process answers. | doc p13: 34.3 s + 25.9 s, serial. Other process 0.3–0.6 s. | ocr-stall-112 |
| F1a | rev3 compiles one program per text-line width class. A program serves every narrower line. | 32–65 s per class. Aspect-82 warm line covers screens seen so far. | memory ane-ocr-stall |
| F1b | ANECompilerService is system-wide and serial. | compile windows never overlap (doc-warm e1–e3) | /tmp/doc-warm/runs |
| F1c | All VN performs in one process are serialized. Two processes do not slow each other. | 3.7–4.0 reads/s from 1 to 16 threads. 3.27 vs 3.58 reads/s per process. | research-vision-stall §2 |
| F2 | `setComputeDevice(.cpu/.gpu)` is accepted and ignored. `.fast` is the only ANE-free path (Latin only). | cpu-first 89 s, gpu-first 64 s. `.fast` 0.06 s. | research §2 |
| F3 | The compile cache is per bundle id and OS build. A client that exits throws its compile away. | 14 + 35 aborted `.tmp` from bench renders | ocr-stall-112 |
| F4 | Small drawn pictures and crops miss the doc networks. The trigger set is open. | Drawn figure pages B_wordstop and F_graphic compiled both networks, then p13 read in 0.44 s. | doc-warm e2/e3 |
| F4a | In one cache, doc reads of prose reuse rev3's programs. | p7 doc 0.34 s after rev3 warm, entries unchanged (3) | doc-warm e2 |
| F5 | Failure handling amplifies a stall. | 8 s per rung serially. Immediate retry after Timeout. RC: 56 Code-13 errors a minute for 32 min. One pid: 13,361 in 2 h 57 min, cured only by restart. | flow-contention, research |
| F5a | `VNRequest.cancel()` works on warm queued and running requests. On a cold compile it is unmeasured and risky. | 5 queued reads returned ERR at 0.61 s | research §2 |
| F6 | The lens was silent ~90 s. The hint exists but the stall never raised it. | — | ocr-stall-112 |
| F7 | translationd is a serial CPU server shared by all lenses. A cancel does not free it. | ~12 lines/s. 3-line batch 246 ms, first result 87 ms. Two at once 1.74× each. Cancel +123 ms. | flow-contention |
| F7a | OCR and translation do not contend. | 1.02× and 1.04× together | flow-contention |
| F8 | Adaptive mode reads a still screen twice. | 352 + 527 ms | flow-contention m2c |
| F8a | Other per-pass costs are small. | Actor sync CPU 10 % of a pass. Main thread < 1 ms median. MI-GAN 12–13 ms per tile. Debug erase 14× slower than Release. | flow-contention |
| F9 | v1.1.0 read with VN + `ParagraphGrouper`. The doc path came back in 0d348da, after the last tag. | VN path p13 1.5 s. Use-case vn 123/251 vs auto 161/251 (b2). | ocr-stall-112, /tmp/reader/b2.log |

Product constraints:
- Menu-bar app people love, zero setup, detail only when sought.
- Mac App Store target, so sandbox-safe.
- No new telemetry.
- The lens is never silent.
- Gates run under natural load.
- ~600 MB with a lens today.

The repo has no AGENTS.md or CLAUDE.md at `feb7a12`. The constraints come from the memory notes and `docs/app-store/audit-2026-10-17.md`.

## 2. Paper decomposition and resource timeline

### 2.1 Silence on a still page (lens on p13, cache cold for the doc networks)

| Term | Today (code path) | Today (s) | Target (s) |
|---|---|---|---|
| Doc read waits for a doc-network compile | `TextRecognizer.swift:162` in-process | 34.3 | 0 for the lens: Docs is rerouted at S_docs = 2 |
| VN rungs after the doc Timeout, each blocked in-process | `:180` → `:293-336`, 8 s each | 8 + 8 + 8 | 0: Lines is another process and answers |
| Immediate re-run of the pass, same blocked process | `RegionPipeline.swift:481-484`, `:798` | repeats until the compile ends | 0: no Timeout errors exist |
| Backlog after the compile (37 VN + 8 doc) | abandoned requests drain | 38.8 | 0: one in flight per worker |
| Second network | same | 25.9 | 0 for the lens |
| Read on the other worker | — | — | ≤ 1.5 (VN path p13 1.5 s) |
| Erase + first translation batch | `:1140`, translationd | 0.29 + 0.59 | 0.29 + 0.59 |
| **Silent interval** | measured 106 s (predicted 105) | **~90–106** | **≤ 2 + 1.5 + 0.88 ≈ 4.4** |

The only design term arithmetic cannot fix is listed in §8 with its expected value. Nothing else needs a run.

### 2.2 Resource timeline per still page (p7/p13, Release, M1 Pro, warm)

| Resource | Today | Target | Notes |
|---|---|---|---|
| GUI host CPU | Vision CPU 0.3–0.4 (VN) + 0.33 (doc), erase 0.29, render | erase 0.29, render. Vision CPU leaves the GUI. | Erase stays on the pipeline actor (10 % of a pass) |
| Worker CPU | — | Lines 0.3–0.4, Docs 0.33, in parallel processes | A Vision read is host-CPU-bound behind a per-process lock (research §1) |
| ANE | ~18 executions per read, below the wall | same | Not the bound |
| ANECompilerService | 0 warm. 27–36 s per new network, serial. | same | Only harm today: it blocks a whole process |
| translationd | 1.76 s per page, serial for all lenses | same; one app-wide dispatcher later | Busiest resource on a still page |
| XPC | — | IOSurface handoff ≈ 0 copy. Reply a few kB. | < 1 ms |
| Wall | sum: 0.39 + 0.33 + 0.29 + 1.76 ≈ 2.8 s | doc-only or max(lines, docs) + erase + translation ≈ 2.4 s | During a compile: today ~90 s silent. Target ~3.3 s to the first translation. |

- **Bound.** The healthy median is bound by translationd, not by recognition. This design is about the tail (compiles and stuck requests).
- **Flow levers.**
  - *Asynchrony*: reading in one process while another compiles. This is the only lever that changes the tail.
  - *Bulk*: one surface per frame, one reply per read.
  - SIMD and SIMT do not apply.
- **Erase overlap.** Overlapping erase with the first translation batch is worth ≤ 0.4 s (13 %). It is not in scope.

## 3. Current architecture (main `feb7a12`)

### 3.1 One read, still page, adaptive (the default, `Settings.swift:197`)

1. **Capture.** A frame arrives (`RegionCapturer.swift:119-130`).
2. **Admission.** `RegionSession.swift:126` starts `Task { await pipeline.ingest }` for each frame.
3. **Diff.** `RegionPipeline.ingest` (`:338-391`) runs FrameDiff, then `kick` (`:465`) and the `run` loop (`:471`).
4. **Fast pass.** The screen is not settled, so `fastPass` runs with dirty = the whole capture (`:774`).
   - In erasing modes it calls `TextRecognizer.blocks(plan:)` (`:787`).
   - Automatic and not held: VN lines (`:143`), then `plan.decide`, then the doc read (`:162`).
   - Automatic and held: doc read only (`:120`).
5. **Fast-pass output.** filters → erase (`:1140`) → `fillTranslations` (`:1245`) → per-lens `translateQueue` (`:1268`) → `TranslationService.translate` (`TranslationService.swift:303`) → translationd → `emit` (`:1517`) → MainActor `OverlayPanel.apply`.
6. **Second read.** 0.5 s later (`settleDelay`), `seamlessPass(frame)` (`:854`) calls `blocks()` again on the same frame. Translations come from the cache, erase runs again, then `emit(animated:)`.

### 3.2 Scroll

1. Frames come every 125 ms (8 fps).
2. `FrameDiff.scrollRegions` → `followScroll` shifts blocks.
3. The dirty band goes to `fastPass(roi:)`, which calls `blocks(roi, plan)` or `lines(fast:)` for a known Latin source.
4. Erase or box, then translation under the dwell rules (`TranslationScheduling`), then `emit`.
5. On stop: one seamless pass.

### 3.3 Components today

| Component | Where | Executor | Failure handling |
|---|---|---|---|
| Capture | `RegionCapturer.swift:31,106-107,145-151` | SCStream, serial queue `capture` (userInitiated), ≤ 8 fps, queueDepth 4 | `CaptureRecovery` with its own backoff (`RegionSession.swift:287-380`) |
| Admission | `RegionSession.swift:120-127` | capture queue → one unbounded `Task` per frame | `ReadingGate` drops frames when covered |
| Diff and scheduling | `RegionPipeline.swift:338-510` | pipeline actor; one pass at a time per lens; latest frame | `ReadBackoff` 1→5 s, transient fixed 1 s (`RetryBackoff.swift:104-107`). A Timeout skips it and re-runs at once (`:798`, `:481-484` with `:873`). |
| Paragraph read | `TextRecognizer.blocks` `:101-183` | static enum; `perform` blocking inside unstructured Tasks on the cooperative pool (`:238-244`) | Doc 8 s (`:186`) → VN. `gate.missed` ×2 → `.failed` until relaunch (`SwiftVisionGate.swift:132-137`). |
| Line read and ladder | `:33-51`, `:293-336` | same | rev3 8 s → rev2 → fast, each blocked in-process (F1). Abandoned requests never cancelled (`:225-229`). |
| rev3 health | `OCRHealth.swift`, `:340-394` | static lock | lateAfter 8, giveUpAfter 180, probe every 120 s, notReady 5 s fixed |
| Doc model | `swiftBlocks` `:188-214` | **GUI process** | as above |
| Warm-up | `AppModel.swift:184` → `TextRecognizer.warmUp` `:401-448` | detached Task. `textModel` rev3 compiles **in the GUI**. `documentModel` and `swiftTextModel` compile in a child (`SwiftVisionChild.swift:26-49`), then load again in the GUI. | A failed step waits for "Try Again". `swiftTextModel` is never read (`:477-481`). |
| Filters and layout | `RegionPipeline.swift:806, :891-895` | actor | — |
| Erase | `:1140`, `Inpainter` (`.cpuAndGPU`, NSLock) | actor, ~0.3 s a page | flat-fill fallback |
| Translation | `:1245-1377` per lens → `TranslationService` actor → translationd | each lens has its own queue into one serial server | `RetryBackoff` 2→30 s, strikes, preemption by cancel (`:1340-1377`) |
| Render and overlay | `:1487-1538` → `OverlayPanel.apply` | actor → MainActor | — |
| Health → hint | `TextRecognizer.raise` `:602-621` → `AppModel.recognitionNotice` `:470` → `LensSignals.recognitionPreparing` (`AppModel.swift:286-290`, `RegionSession.swift:405-426`) → `LensHint.preparingRecognition` | MainActor | Raised only for the *last* rung after 8 s with the cold allowance (`:343-346`). A doc Timeout raises nothing (`:129-133`, `:166-170`). |
| Headless | `SelfTest.swift:45-57, :178-197, :255-276`; `UICapture` `vision-reads`; `tools/paper-bench/run.sh:21`; `tools/usecase-bench/bench.sh:28` | a fresh process per render; same warm-up and child | Exits at once at the end and aborts compiles (F3). Still renders run seamless, not adaptive (`SelfTest.swift:133`). |

## 4. Target architecture

### 4.1 Invariants (each has a gate in §6)

| ID | Invariant | Gate |
|---|---|---|
| I1 | No Vision request runs in the GUI process. The GUI binary does not link Vision. | `nm`/`otool` and the GUI e5rt cache entry count (R5). In 1.1.2: no doc networks in the GUI cache. |
| I2 | A worker has at most one request in flight. The host dispatches only to an idle worker. | `ReaderHealthTests`, stats `inflight.max=1` |
| I3 | Our side never cancels, abandons or times out a request. Every completion is observed and updates health. | unit test, trace `reader.dropped.*` only for results |
| I4 | No worker exits while a request is in flight, except one bounded "stuck" recycle at 180 s per incident. | unit test |
| I5 | A lens never waits past its patience without a reroute or a hint. Longest silent interval ≤ N = 8 s. | e2e silence metric |
| I6 | No failure causes an immediate retry. Every retry wait comes from `Backoff`. | `BackoffTests`, trace |
| I7 | Every process that hosts workers drains them before a scripted exit (render, bench, probe). | `drain: in-flight=0`, `.tmp=0` |
| I8 | Every read records who read it (lines/doc/fast, worker, rerouted). Worker state changes are in the unified log. | stats and log lines |

### 4.2 Process boundaries and hosting

| Process | Bundle id | Models | Compiles it can trigger |
|---|---|---|---|
| GUI `Mwoyeo` | `dev.midagedev.mwoyeo` | none from Vision. MI-GAN Core ML (`.cpuAndGPU`), NaturalLanguage, Translation client. | none on the ANE |
| `Lines` XPC service | `<app id>.reader.lines` | VN rev3, rev2, `.fast` | rev3/rev2 width classes, per-language loads |
| `Docs` XPC service | `<app id>.reader.docs` | `RecognizeDocumentsRequest`; VN `.fast` as stand-in | doc networks (open set), its own copy of the text programs (F4a), per-language loads |

**Why XPC and not the current child process.**

| | Bundled XPC service | Child of the app's own executable (`--warm-vision` today) |
|---|---|---|
| Sandbox (MAS) | The sanctioned shape. Each service has its own minimal entitlements (`app-sandbox` only). | Unverified. Apple's inherit rule wants a helper with exactly `app-sandbox` + `inherit`. Re-executing the main binary with the app's entitlements may abort. Never probed (the MAS audit only probed external binaries). |
| Supervision | launchd starts it on the first message and restarts it after a crash. We get interruption and invalidation handlers. No pid signals in normal operation. | We manage pids, pipes and exits ourselves. |
| Lifetime | Bound to the client app process (ServiceType Application: one instance per app instance; R1 verifies). Dies with the app. | Same, plus orphan risk. |
| Image transfer | IOSurface over XPC, zero copy | Pipe bytes or temp files |
| Compile cache | Its own bundle id, so its own cache. One cold compile per service after the update. | Shares the app's cache. |

- **The XPC cost is paid in the background.**
  - Lines: rev3 ~64–96 s.
  - Docs: text programs ~56 s plus two doc networks ~75 s.
  - The other worker serves meanwhile: Docs' `.fast` reads Latin while Lines compiles, and Lines reads while Docs compiles.
  - CJK users see "Preparing text recognition" once for ~1.5 min after the update.
- **Two workers is the minimum** that keeps a lens readable through a compile (F1, F1c). One worker would just move the stall.
- **Service names derive from the app id** (`Bundle.main.bundleIdentifier! + ".reader.lines"`). A re-identified copy (fresh-cache gates) then talks to its own re-identified services.

### 4.3 Components and owners

| Component | Owner (file, type) | Process | Responsibility |
|---|---|---|---|
| Wire types | `Core/Sources/MwoyeoCore/ReaderWire.swift` (`ReadJob`, `ReadReply`, `ReaderEvent`, `@objc ReaderXPC`) | both | Job: surface, format, roi, languages, customWords, kind. Reply: lines/paragraphs in image pixels, ms, footprint, typed error. |
| Worker | `Reader/ReaderWorker.swift` (`ReaderWorker`) + `Shared/VisionExec.swift` | services | Runs exactly one job on a dedicated serial queue to completion. Draws warm-up pictures. Reports `phys_footprint`. Interprets `MWOYEO_FAKE_READER`. Exits on request when idle, or at once on a stuck recycle. |
| Vision execution | `Shared/VisionExec.swift` (moved from `TextRecognizer.swift:55-93, :188-214, :508-529, :690-706` and doc-warm's `WarmPictures`) | services (and the GUI until R5) | Pure Vision calls with identical parameters to today |
| Transport | `App/Reader/ReaderConnection.swift` (`ReaderConnection`: `.xpc(role)`; `.local` only in 1.1.2 for Lines) | GUI | NSXPCConnection, IOSurface packing, interruption → event |
| Host | `App/Reader/RecognitionHost.swift` (actor `RecognitionHost`) | GUI | Per-worker queue, dispatch, router, health, warm-up, drain, stats, log |
| Worker health | `Core/.../ReaderHealth.swift` (`WorkerHealth`, pure) | — | State machine §4.4 |
| Router | `Core/.../ReadRouter.swift` (`ReadRouter`, pure) | — | Rules §4.5; owns the rung table (today's `OCRFallback.ladder`) |
| Lens wait | `Core/.../ReadWait.swift` (`ReadWait`, pure) | — | Lens patience → `RecognitionWait` for the hint (§4.7) |
| Backoff | `Core/.../Backoff.swift` (`Backoff`, pure; policy table) | — | §4.8; `RetryBackoff`, `ReadBackoff`, `HealthyBackoff` and `notReadyRetryEvery` become configurations of it |
| Warm-up plan | `Core/.../ReaderWarmup.swift` (`ReaderWarmup`, pure) | — | Steps per worker and key, order §4.10 |
| Facade | `App/Pipeline/TextRecognizer.swift` | GUI | `lines` and `blocks` keep their signatures and call the host. `verdict`, `tally`, `makeBlock` and `isCJK` stay. |
| Pipeline | `App/Pipeline/RegionPipeline.swift` | GUI actor | Unchanged one pass at a time. Handles `.unavailable`. Kicks on `readerReady`. |
| Hint | `Core/.../LensHint.swift` (`LensSignals.recognition`) → `RegionSession.refreshHint` | GUI MainActor | Single line on the pill |

### 4.4 Worker health state machine (`WorkerHealth`)

| State | Meaning | Router sees |
|---|---|---|
| `cold` | Not started, or exited idle. The cache may be warm. | usable (start on first job) |
| `warming(job, since)` | A warm-up job is in flight (expected cold compile) | unavailable |
| `idle(warm: Set<Kind@Key>)` | Answered before, nothing in flight | usable for warm kinds |
| `busy(job, since)` | In flight, age < S(kind) | queue behind (≤ S) |
| `suspect(job, since)` | In flight, age ≥ S(kind): likely compiling | unavailable; reroute |
| `stuck(job, since)` | In flight ≥ 180 s (`OCRHealth.giveUpAfter`, kept) | unavailable; "not responding" |
| `restarting(until)` | After a crash or recycle, in backoff | unavailable |
| `disabled` | ≥ 5 crashes in 10 min, or stuck twice in a row | unavailable; "restart" hint |

| Transition | Trigger | Effect |
|---|---|---|
| idle → busy | dispatch | — |
| busy/suspect/warming → idle | reply | Add kind@key to warm. A suspect or warming end broadcasts `readerReady(worker)` and logs `recovered after N s`. |
| busy → suspect | age ≥ S(kind) | Reroute queued and current lens jobs. Log notice. |
| suspect → stuck | age ≥ 180 s | Hint "not responding" where no reader is left. One recycle (exit now). |
| busy → idle + rung backoff | fast error `programsNotReady` (Code 13) or `nilError` | rev3 rung waits on `Backoff(1, cap 30)`; rev2/fast serve meanwhile |
| idle → recycle | Code-13 streak ≥ 20 over ≥ 60 s after rev3 had answered, or footprint > budget | Exit when idle; max 3 per 30 min |
| any → restarting | XPC interruption (crash) | `Backoff(1, cap 30)`; ≥ 5 in 10 min → disabled |
| idle → cold | idle ≥ 10 min and no client wants this worker | exits; next job relaunches (~0.6 s warm load) |

S(kind), derived from warm latency with a load margin:

| Kind | Warm latency | S |
|---|---|---|
| doc | 0.33–0.48 s; p13 0.44 s | 2 s |
| VN accurate | 28 lines 0.25 s; 175 lines 0.65–0.88 s; ×3 | 3 s |
| `.fast` | 0.06–0.1 s | 1 s |

The rolling p95 per worker is in `stats()` to re-derive them.

### 4.5 Router rules (`ReadRouter`, pure)

1. **Layout wanted, Docs idle and warm for the key** → Docs/doc.
2. **Layout wanted, Docs not usable** (cold for the key, warming, suspect, stuck, restarting, disabled) → the job becomes *lines + `ParagraphGrouper`*. A rerouted read never changes the plan's held reader.
3. **Lines wanted, Lines idle** → Lines with the best healthy rung for the languages: rev3, or rev2 or `.fast` while rev3 is in rung backoff.
4. **Lines busy within S** → queue (FIFO, at most one job per client; a newer job from a client supersedes its queued one).
5. **Lines not usable** →
   - Docs/doc if Docs is idle and warm for the key (doc reads give lines too);
   - else Docs/`.fast` if every language is in `.fast`;
   - else `.unavailable(.preparing)`;
   - or `.unavailable(.notResponding)` when Lines is stuck or disabled.
6. **Never send a kind to a worker that is cold for it, unless the worker is that kind's home.** VN accurate's home is Lines; doc's home is Docs. This prevents a second cold compile in the other cache. `.fast` never compiles, so it may go anywhere.
7. **`MWOYEO_OCR_PATH=vn|swift`** stay as overrides for benches: `vn` never uses Docs; `swift` assumes Docs ready.

### 4.6 Request scheduling

- **Per worker:** one in flight, FIFO, at most one job per client. Clients are each lens's pipeline, the image window and a headless render.
- **Priority:** lens jobs > image-window jobs > warm-up jobs. A warm-up job dispatches only into an idle worker with an empty queue. Lens jobs never queue behind a warm-up job (rule 5).
- **Superseded:** a queued job replaced by a newer one from the same client returns `.superseded` at once.
- **Late results:** a rerouted job's original request runs on. Its reply updates health (and the warm set). The result is dropped and counted (`reader.dropped.rerouted`).
- **Pipeline:** unchanged one pass at a time, latest frame. New outcome `.unavailable(why)`:
  - the pass is not done;
  - it does not count as a failure;
  - the lens reports the wait;
  - the pipeline re-runs on `readerReady`, not on a timer.
- **Recovery re-read:** on `readerReady(.docs)`, lenses whose plan wants a document layout and whose blocks came from a reroute re-read once. That is how a paper page gets its doc layout after a compile ends.
- **No blocking calls in GUI concurrency.** The XPC reply is async. The 1.1.2 `.local` transport runs `perform` on a dedicated serial queue, never on the cooperative pool. Today's blocking `perform` inside Tasks (`TextRecognizer.swift:238-244`) can hold one pool thread per stuck request.

### 4.7 Deadlines vs compiles; lens wait → hint

- **The lens's patience is S per candidate.** It decides routing and hints only.
- **The worker's lifetime is the app's lifetime** (or idle exit). The worker never stops a request.

Lens wait states (`ReadWait`, per client):

| State | Enter when | Pill (`LensSignals.hint`, only while no translation is shown) |
|---|---|---|
| `reading(since)` | job dispatched; reset on reroute | none |
| `waiting(.preparing, since)` | the router returns `.unavailable(.preparing)`, or the last candidate turned suspect | "Preparing text recognition — first time only" (existing `preparingRecognition`), shown at once |
| `waiting(.notResponding)` | candidate stuck (≥ 180 s) and its one recycle also stuck | new `recognitionNotResponding`: "Text recognition isn't responding". Menu banner: existing `.textRecognitionStalled` ("Restarting the Mac usually fixes it"). |
| `waiting(.restartApp)` | worker disabled (crash loop) | "Restart Mwoyeo" (existing `.restart` action) |
| `showing` | a read returned blocks | — |

Priority stays screen > pack, then recognition. Recognition outranks "already in". The menu status line keeps "Preparing text recognition…" with worker states in its tooltip (progressive disclosure: no new card).

**N, the longest silent interval.** Worst case is Docs suspect, then Lines suspect, then a read that lands:

| Term | s |
|---|---|
| S_docs | 2 |
| S_lines | 3 |
| Lines read of p13 (VN path 1.5 s) | 1.5 |
| Erase (Release, 18 blocks) | 0.29 |
| First translation batch (p7 first batch) | 0.59 |
| **Sum** | **7.4** |

N = 8 s. Expected on the p13 fresh-id gate: ~1–2 s (Docs `.fast` reads while Lines compiles).

### 4.8 One backoff policy (`Backoff`)

`Backoff(base, factor 2, cap, healthyWindow?)`. The policy table lives in one file:

| Use | base | cap | Reset |
|---|---|---|---|
| Translation queue after a failed batch | 2 | 30 | success |
| Added-engine cooldown | 2 | 30 | 60 s healthy window |
| Lens read, hard error (same pixels would fail) | 1 | 5 | success, geometry or language change |
| rev3 rung after `programsNotReady` / `nilError` | 1 | 30 | rev3 answer |
| Worker restart after a crash | 1 | 30 | 10 min without a crash |
| Capture restart (`CaptureRecoveryPolicy`) | keeps its policy values, expressed as a `Backoff` | | |

Removed:
- the transient fixed 1 s (`RetryBackoff.swift:104-107`);
- `notReadyRetryEvery` 5 s fixed;
- the 120 s rev3 probe (the in-flight request is the probe);
- every immediate re-run after a Timeout.

### 4.9 Restart policy

| Situation | Action |
|---|---|
| Crash | launchd relaunches on the next job after `Backoff`. Warm set cleared (the cache is on disk, so ~0.6 s). |
| Persistent Code 13 (the 3 h case) | Recycle when idle (requests fail in 12 ms, so the worker is idle between them). rev2/fast serve meanwhile. |
| Stuck ≥ 180 s | One recycle (exit message on the XPC queue; last resort `kill` on the pid recorded at connect). If the successor's first job is stuck too: no more recycles, hint "not responding". 180 s > the longest cold compile seen (138 s under contention). |
| Footprint over budget | Recycle when idle |
| No lens wants it for 10 min | Idle exit |
| App quit | Workers die with the app; a compile in progress is lost (user's choice). |
| App relaunch (first-run grant) | Later (R8): the predecessor drains its warm-up compile before exit, and the successor's router treats Lines as `warming` until the predecessor is gone. Today a relaunch restarts the 64 s compile (`tools/ocr-probe/README.md`, relaunch-cold). |

### 4.10 Warm-up

Once compiles cannot silence a lens, warm-up buys first reads at full quality sooner (rev3 instead of `.fast`, doc layout instead of grouper). It no longer guards correctness.

| Step | Worker | Picture | Cold cost | Warm cost per launch |
|---|---|---|---|---|
| rev3 widest class + CJK | Lines | today's `probePicture` (aspect 82 + CJK line) | 64–96 s | ~0.3 s |
| doc networks | Docs | doc-warm's drawn figure pages (`WarmPictures`) | ~56 s text programs + ~75 s two networks | ~0.4 s |
| per-language key | the same steps per configured source key (ja 34 s, fr 32 s …) | | | |

- **Order.** Lines first. Docs starts after Lines is warm, because the compile service is serial and Docs' `.fast` should stay free during Lines' compile.
- **Placement.** Both steps run in their workers and never in the GUI. They are never cancelled. They run only in idle slots.
- **Deleted.** The `swiftTextModel` step (`RecognizeTextRequest` is never read; it wastes one ~30 s serial compile at first launch).
- **Not pursued.** Chasing the open doc trigger set and CPU forcing (F2).

### 4.11 Keeping paper quality

- **Doc reads are byte-for-byte the same calls,** in the Docs worker. R1's equivalence gate proves the lines are identical for the use-case pictures and the paper pages.
- **When Docs is not ready, cold for the key, or suspect,** the lens reads VN + `ParagraphGrouper` (v1.1.0 quality). It is never silent.
- **When Docs becomes ready,** pages that wanted a document layout re-read once (§4.6) and get the doc layout.
- **Benches keep `--warm`** (wait for both workers warm for the key), so they measure the doc path as today.

### 4.12 Translation scheduling (later; F7)

- **One app-wide dispatcher in `TranslationService`,** pull model: when the engine slot frees, ask each pipeline for its best batch *now* (`nextBatch()` evaluated at send time), so stale batches are dropped before send.
- **Global priority:** lens-visible text of any lens first, then leading overscan, then the rest. Ties go to the lens with the latest user motion.
- **Slots:** Apple 1 (serial server; two at once cost 1.74× each). Added HTTP engines 2 (unmeasured).
- **Cancel only when expected remaining time > 0.25 s,** since a cancel does not free translationd (+123 ms).

### 4.13 The adaptive double read (later; F8)

- **`ReadMemo` per pipeline** holds the last read keyed by frame (time and gray hash), roi = whole capture, reader kind, languages and glossary.
- **A settled seamless pass on an unchanged frame reuses it** and only erases and renders.
- **Saving:** 352 or 527 ms of worker time per settle; one read instead of two.

### 4.14 Headless tools

- `--render`, the image window and `--capture-ui vision-reads` all use `RecognitionHost` and the same services.
- `SelfTest` changes:
  - `drain` before exit: wait until no worker has a request in flight, bounded by 180 s; print `drain: <ms> in-flight=0`;
  - `--mode adaptive`;
  - `--then reader-ready` (wait until both workers are warm for the key);
  - a silence timeline sampled every 100 ms: `silence: longest=<ms>`;
  - `reader:` stats lines.
- Probes in `tools/ocr-probe/*.swift` stay raw-Vision research tools, labelled as such.
- `tools/ocr-probe/reader-cold.sh` is the fresh-cache gate. It re-identifies the app and both services and re-signs inside-out.

### 4.15 Debuggability

- **`RecognitionHost.stats()`.** Per worker:
  - role, pid, state and since, warm set;
  - answered and failed by kind, suspects (count, max ms), recycles, crashes;
  - rev3 Code-13 streak, footprint MB, p50/p95 ms.
  - Printed by SelfTest and `vision-reads`. The tooltip shows a one-line form.
- **Debug ring.** The last 64 `ReaderEvent`s (t, client, worker, kind, rung, image size, ms, outcome), dumped under `MWOYEO_TRACE`.
- **Unified log** (`dev.midagedev.mwoyeo`, category `reader`).
  - Notice level: worker transitions (suspected, recovered after N s, stuck, recycled, crashed, disabled) and reroutes.
  - The worker logs its own pid with `kind=doc ms=34012 (slow)` when ms > S.
  - Numbers and enums public; never text content.
  - Read with `/usr/bin/log show --predicate 'subsystem == "dev.midagedev.mwoyeo" AND category == "reader"'`. Today's `ocr.swift.missed` exists only as a Trace counter.
- **Trace counters for benches:** `reader.dispatch.<worker>.<kind>`, `reader.reroute.<from>.<to>`, `reader.suspect.<worker>`, `reader.unavailable.<why>`, `reader.dropped.<why>`.
- **All local.** No new telemetry.

### 4.16 Memory budget

- **Today:**
  - GUI footprint with a lens: 504–554 MB (vmmap peak 792; IOAccelerator 239 MB, mostly MI-GAN's GPU set, now released after 60 s idle).
  - A Debug render with MI-GAN off: 197 MB.
  - A process with the inpainter not loaded: 123–133 MB (`Inpainter.swift:11-15`).
  - So Vision plus pipeline buffers are ≈ 65–75 MB of a render.
- **Estimate.**
  - Lines: 30–60 MB steady (Foundation + Vision, no AppKit; model weights are clean mapped pages).
  - Docs: 50–90 MB steady.
  - Each read adds 15–25 MB of transient tensors. The IOSurface is counted once, in the GUI.
  - The GUI loses its Vision share. Net ≈ +40–90 MB.
- **Budget.**
  - Lines ≤ 80 MB and Docs ≤ 120 MB steady; recycle when idle above 2× their post-warm-up footprint.
  - Total (GUI + workers) ≤ 650 MB with one lens.
  - With no lens for 10 min, workers exit: 0 MB for Vision at rest.
- **Leak guard.** Forum 815812 reports 3–15 MB of permanent growth per `VNRecognizeTextRequest` on 26.2. A long-lived worker makes that visible, and the recycle bounds it.
- The deciding measurement is in §8.

## 5. Gap table

`[1.1.2]` = needed so that 1.1.2 is never silent and never piles up. `[later]` = 1.1.3 or after.

| # | Where | Current | Target | Size | Risk | When |
|---|---|---|---|---|---|---|
| G1 | `TextRecognizer.swift:188-214` | `RecognizeDocumentsRequest` in the GUI | Docs XPC worker | L | M | [1.1.2] |
| G2 | `TextRecognizer.swift:55-76, :580-586` | VN in the GUI | Lines XPC worker (1.1.2: `.local` transport with one in flight on a dedicated queue) | M | M | [later] (local part [1.1.2]) |
| G3 | `TextRecognizer.swift:225-247` | `deadline` abandons the request; next pass sends more into the blocked process | one in flight per worker, no abandonment, suspect → reroute | M | M | [1.1.2] |
| G4 | `TextRecognizer.swift:293-336` | ladder spends 8 s per rung in a blocked process | ladder only on fast errors; slowness reroutes across processes | M | L | [1.1.2] |
| G5 | `RegionPipeline.swift:481-484, :793-799, :860-877` | Timeout → immediate re-run, no backoff | no Timeout errors; `.unavailable` waits for `readerReady` | S | L | [1.1.2] |
| G6 | `RegionPipeline.swift:787-792` | `blocks()` (`try?`), then `lines()` again: a second ladder after a failure | one read per pass from the host | S | L | [1.1.2] |
| G7 | `SwiftVisionGate.swift:132-137` | second miss → `.failed` until relaunch | slow ≠ failed; recovers on answer | S | L | [1.1.2] |
| G8 | `RetryBackoff.swift:104-107`; `OCRHealth.swift:18` | transient fixed 1 s; notReady fixed 5 s | `Backoff` 1→30 s; Code-13 streak → recycle | S | L | [1.1.2] (recycle [later]) |
| G9 | `TextRecognizer.swift:129-133, :166-170, :340-347` | doc Timeout raises nothing; preparing only on the last rung after 8 s | `ReadWait` per lens → hint at S | S | L | [1.1.2] |
| G10 | `SwiftVisionChild.swift` (all); `TextRecognizer.swift:437-447` | child compiles, then the GUI loads the model again | warm-up inside the workers; child deleted | M | L | [1.1.2] |
| G11 | `TextRecognizer.swift:477-481`; `SwiftVisionGate.swift:25`; `SetupStatus.swift:45` | `swiftTextModel` warmed, never read | delete (−1 serial compile ≈ 30 s at first launch) | S | L | [1.1.2] |
| G12 | `TextRecognizer.swift:428-436` | rev3 warm-up compiles in the GUI (64–96 s) | Lines worker | S | L | [later] |
| G13 | `SelfTest.swift:45-57` | render exits at once, aborting compiles | drain; `--mode adaptive`; `--then reader-ready`; silence metric; stats lines | S | L | [1.1.2] |
| G14 | `tools/paper-bench/run.sh:21`, `tools/usecase-bench/bench.sh:28`; mkcold (in /tmp only) | renders abort compiles; fresh-id script re-ids only the app | drain fixes the renders; `reader-cold.sh` re-ids the app and services | S | L | [1.1.2] |
| G15 | `LensHint.swift:87, :112`; `AppModel.swift:286-290`; `RegionSession.swift:405-417` | one global bool from setup progress or issue | per-lens `RecognitionWait`; new `recognitionNotResponding` | S | L | [1.1.2] |
| G16 | `AppModel.swift:176` | `translator.prewarm()` awaited before the reader warm-up (≤ 7 s) | reader warm-up first or concurrent | S | L | [1.1.2] (trivial) |
| G17 | `RegionPipeline.swift:478-489` | adaptive reads a still screen twice | `ReadMemo` | S–M | L | [later] |
| G18 | `RegionPipeline.swift:1258-1314`; `TranslationService.swift:303` | each lens queues into one serial translationd | app-wide pull dispatcher | M | M | [later] |
| G19 | `RegionSession.swift:126` | an unbounded Task per frame | latest-wins mailbox | S | L | [later] |
| G20 | `TextRecognizer.swift:382-394`; `OCRHealth.swift:115-133` | rev3 probe every 120 s | deleted; the in-flight request is the probe | S | L | [later] |
| G21 | `TextRecognizer.swift:130-131` | stall facts mostly in Trace counters | `reader` log category, `stats()`, ring | S | L | [1.1.2] |
| G22 | — | no per-process budget or recycle | worker footprint in replies; recycle; idle exit | S | L | [later] |
| G23 | `project.yml`; `scripts/release.sh:41` | one target | two XPC service targets (one source dir, role in Info.plist), embedded and signed by xcodebuild; `--deep` verify already present | S–M | M (notarization of a nested bundle) | [1.1.2] |
| G24 | `SwiftVisionChild.swift:9-10` | assumes a child of the main executable inherits the sandbox | XPC with minimal entitlements, proven by a sandboxed render | S | M | [1.1.2] (Docs) |
| G25 | `SwiftVisionGate.swift:4-9`; `TextRecognizer.swift:302-304`; `OCRFallback.swift:3-5`; `tools/ocr-probe/README.md:7` | say rev2/`.fast` answer during a compile, or that no Swift request is used | deleted or corrected with the moves | S | L | [1.1.2] |
| G26 | `Relaunch.swift:15-41` | a relaunch restarts the first-run compile | predecessor drains, successor waits | M | M | [later] |
| G27 | `TextRecognizer.swift:238-244` | blocking `perform` on the cooperative pool, one thread per stuck request | async XPC reply; the `.local` transport uses a dedicated queue | S | L | [1.1.2] |
| G28 | `UICapture.swift:180-183, :201-215` | fake setup steps and probe read `SwiftVisionGate` | host stats and fakes | S | L | [1.1.2] |

## 6. Migration plan

Two rounds never share a file at once.

### R1 `reader-service` (1.1.2), parallel with R2

- **Files:**
  - new `Reader/` (service `main.swift`, `ReaderWorker.swift`, `Info.plist` per role, `Reader.entitlements` with `app-sandbox` only for the MAS flavour);
  - new `Shared/VisionExec.swift` (moved from `TextRecognizer.swift:55-93, :188-214, :508-529, :690-706` plus doc-warm's `WarmPictures`), compiled into both targets;
  - new `Core/Sources/MwoyeoCore/ReaderWire.swift`;
  - new `App/Reader/ReaderConnection.swift`;
  - `project.yml`;
  - `App/Pipeline/TextRecognizer.swift` (only the extraction: calls go to `VisionExec`);
  - new `tools/ocr-probe/same-lines.py`.
- **Gates:**
  - **Equivalence, FAIL-first.** Run the 40 use-case pictures and p1–p18 with `MWOYEO_OCR_PATH=swift MWOYEO_TRACE_LINES=1` through `MWOYEO_READER=inprocess` vs `xpc`, then `python3 -I tools/ocr-probe/same-lines.py A B`.
    - Expect `same: 58/58 pictures, max rect delta 0 px`.
    - Mutation `MWOYEO_FAKE_READER=shift1` must print `same: 0/58`.
  - **Process shape.** The render prints `reader: docs pid=<p> gui pid=<q>` with p ≠ q. Two concurrent renders give two distinct docs pids, which verifies ServiceType Application.
  - **Sandbox.** A build signed with `docs/app-store/probe/sbx-net.entitlements` on the app and the service entitlements: `--render chat.png` gives `blocks > 0` through the service.
  - Standard gates (`swift test`, xcodebuild, check-logic).

### R2 `reader-core` (1.1.2), parallel with R1

- **Files:**
  - new `Core/Sources/MwoyeoCore/{ReaderHealth,ReadRouter,ReadWait,Backoff,ReaderWarmup}.swift`;
  - `RetryBackoff.swift` (its types become `Backoff` configurations);
  - `LensHint.swift`;
  - new tests `{ReaderHealthTests,ReadRouterTests,ReadWaitTests,BackoffTests}.swift`;
  - `LensHintTests.swift`.
- **FAIL-first unit tests** (paste the failing line on the stub that encodes today's rule):
  - `testSlowDocReadIsNotFailure`: two late answers → still usable. Today's rule gives `.failed`.
  - `testTransientWaitsDouble`: waits `[1,2,4,8,16,30,30]`. Today: `[1,1,1,…]`.
  - `testDocsSuspectRoutesToLines`.
  - `testLinesWarmingLatinGoesToDocsFast`.
  - `testLinesWarmingJapaneseIsPreparing`.
  - `testNeverSendsRev3ToDocs`.
  - `testStuckTwiceStopsRecycling`.
  - `testSilenceBound`: simulated clock, worst case reroute chain, hint at ≤ S after the last candidate, no hint flash while a reroute target exists.
- **Expect:** `cd Core && swift test` → `Executed N tests, with 0 failures`.

### R3 `reader-host` (1.1.2), after R1 and R2

- **Files:**
  - new `App/Reader/RecognitionHost.swift`;
  - `App/Pipeline/TextRecognizer.swift`;
  - `App/Pipeline/RegionPipeline.swift`;
  - `App/Model/RegionSession.swift`;
  - `App/Model/AppModel.swift`;
  - `App/Pipeline/VisionSetup.swift`;
  - `App/UI/SetupStatus.swift`;
  - `App/UI/LensHintText.swift`;
  - `App/Resources/Localizable.xcstrings` (English plus ko/ja `needs_review`);
  - `App/MwoyeoApp.swift`;
  - `App/Support/UICapture.swift`;
  - delete `App/Pipeline/SwiftVisionChild.swift`, `Core/Sources/MwoyeoCore/SwiftVisionGate.swift`, `Core/Tests/MwoyeoCoreTests/SwiftVisionGateTests.swift`.
- **Lines** stays `.local` in 1.1.2 (one in flight, dedicated queue).
- **Gates** (fakes run inside the worker, so they exercise the real IPC and host):
  - `MWOYEO_FAKE_READER=docs-slow:40000 --render p13.png … --mode adaptive`:
    - expect `silence: longest ≤ 8000`, `reader.reroute.docs.lines=1`, final `reader: docs state=idle`;
    - FAIL-first mutation `MWOYEO_READER_REROUTE=off` gives `silence: longest ≥ 38000`.
  - `MWOYEO_FAKE_READER=lines-slow:40000 --src ja` → `hint: preparing at ≤ 3500 ms`.
  - `MWOYEO_FAKE_READER=lines-e5rt:40` → logged rung waits `1,2,4,8,16,30`, lens filled by rev2/fast, Code-13 errors ≤ 6 per minute (today 56).
  - Use-case bench ≥ 160/251 with categories equal to `/tmp/lead-final/bench.log`.
  - Paper bench `formula 0, overlaps 0, spill 0, cut 0, clipped ≤ 7`.

### R4 `headless-shape` (1.1.2), after R3

- **Files:**
  - `App/Support/SelfTest.swift`;
  - new `tools/ocr-probe/reader-cold.sh` (promotes `/tmp/ocr-stall/r112/cold/mkcold2.sh`; re-ids the app and both services; header names the failure mode "a read compiles in the GUI process or a lens goes silent behind a compile");
  - `tools/ocr-probe/README.md`;
  - comments in `tools/paper-bench/run.sh` and `tools/usecase-bench/bench.sh`.

**Decisive end-to-end gate (R4, on Release):**

```
SRC_APP=<Release>/Mwoyeo.app bash tools/ocr-probe/reader-cold.sh p13
```

It runs `<copy>/Contents/MacOS/Mwoyeo --render p13.png out.png --src en --tgt ko --scale 2 --mode adaptive --no-inpaint --then reader-ready,again --max-wait 400` with a scratch settings file, and prints:

| Line | Assert (1.1.2, Lines local) | Assert (1.1.3, R5) | Expected |
|---|---|---|---|
| `silence: longest=<ms>` | ≤ 8000 | ≤ 8000 | ~1000–2000 (Docs `.fast` while Lines compiles) |
| `gui-cache: entries=<n>` (`ls ~/Library/Caches/<app id>/com.apple.e5rt.e5bundlecache/*/ \| wc -l`) | ≤ 3 (rev3 only), and `docs-cache ≥ 4` | 0 | 3 / 0 |
| `again: ocr.blocks.swift=<n>` after `reader: docs ready` | ≥ 1 | ≥ 1 | ≥ 1 |
| `drain: in-flight=0`, `.tmp=0` | yes | yes | yes |

- **ja variant** (`--src ja` on a ja use-case picture): `hint: preparing ≤ 3500 ms`, `silence ≤ 8000`.
- **On main this gate fails by construction:** measured ~90 s silent and GUI cache 5 entries.
- **Then:**
  - `OUT=<dir> bash tools/usecase-bench/bench.sh <bin> auto` → `TOTAL auto all n=40 correct ≥160/251`, every category line equal to the baseline;
  - `bash tools/paper-bench/run.sh <bin> <dir>` → `formula 0 … overlaps 0 spill 0 cut 0 clipped ≤7`.

### Later rounds (1.1.3)

| Round | Files | Gate |
|---|---|---|
| R5 `lines-worker` | `RecognitionHost.swift`, `ReaderConnection.swift` (drop `.local`), `TextRecognizer.swift` (drop `import Vision`), `OCRHealth.swift`, `OCRFallback.swift`, new `tools/ocr-probe/no-vision-in-gui.sh` | `nm -u <app>/Contents/MacOS/Mwoyeo \| grep -cE 'VNRecognize\|RecognizeDocuments'` → 0; `otool -L … \| grep -c Vision.framework` → 0; decisive gate with `gui-cache entries=0`; recycle and idle exit unit tests; footprint within §4.16 |
| R6 `translation-dispatch` | `TranslationService.swift`, `RegionPipeline.swift`, `TranslationScheduling.swift` + tests | Two lenses: batch wall per lens ≤ 1.1× single (today 1.74×). `translate.wasted=0` on a scroll run. |
| R7 `read-memo` (serial with R6: both edit `RegionPipeline.swift`) | `RegionPipeline.swift`, new `Core/.../ReadMemo.swift` + test | Adaptive still page: reads per settle 1 (today 2). OCR ms ≤ 527 (today 352 + 527). |
| R8 `relaunch-drain` | `Relaunch.swift`, `AppModel.swift` | relaunch-cold: compile not restarted (today 62 s again) |

- **Parallelism:** R1 ∥ R2, then R3, then R4. R5 after R4. R6 and R7 are serial with each other and come after R3. R8 comes after R5.
- **Deleted after the moves:**
  - `SwiftVisionChild.swift`; `SwiftVisionGate.swift` and its tests; the `--warm-vision` entry (`MwoyeoApp.swift:18-23`);
  - in `TextRecognizer.swift`: `deadline`, `tracked`, `observed`, `startProbing`, `warmUp`/`runSteps`/`perform`/`askingAgainWhileNotReady`/`loadSwiftModel`, gate/publish, `Timeout`/`Stalled` (R3 for doc, R5 for all), the fakes (move to the worker as `MWOYEO_FAKE_READER`);
  - `OCRHealth` probe fields; the `ReadBackoff` transient branch;
  - the "Language reader" step title (removed from the strings 2026-10-19);
  - the stale notes listed in G25 (the memory note ane-ocr-stall is the lead's).

### Status after R3a (2026-10-19)

- `App/Reader/RecognitionHost.swift` owns both services (it replaced `DocsHost`): a `WorkerHealth` per role, `ReadRouter` and `ReadScheduler`, a `ReadWait` per pipeline (`ReaderClients`, the lens's hint), `ReaderWarmup`, a 64-entry debug ring and the `reader` log category.
- Lines are read in the Lines service by default. `MWOYEO_READER=inproc` runs the Lines kinds in the app process for the equal gate and A/B.
- A pass that no reader can take gets `.unavailable(why)` and reads again on `readerReady` or `usableAgain`, never on a timer. `ReadBackoff` stays for hard failures only (R3c).
- Left for R3b: the stuck recycle, the per-role idle exit (Lines 60 s with no lens on), the footprint recycle. `RecognitionHost.recycle` and `wantsWorker` are the seams.
- Left for R3c: delete `SwiftVisionGate`, `OCRHealth`, `OCRFallback` and `ReadBackoff`, tidy the setup UI, rewrite `healthy.sh`.

### Status after 1.1.2 (2026-10-19)

- R0, R1, R2 and R3-lite are on main (`857ce95`). Only document recognition runs in the Docs XPC service.
- Lines are still read in the app process. A fresh install compiles revision 3 there for about 64 s, in the GUI.
- The Lines service measured 138–177 MB warm, against the 80 MB budget of §4.16. The user decided (2026-10-19): it exits after about 60 s idle (full R3).
- `DocsHost` never recycles a stuck Docs service. It logs the `recycle` events of `WorkerHealth` and does not act on them.
- Reader-cold (`tools/ocr-probe/reader-cold.sh`): the longest silence was 3.0 s against the gate of 8 s. On the base `b1f39a5` it was 9 s.
- Bench rule: OCR output depends on the per-bundle-id e5rt cache, so compare benches only at one fixed scratch `MWOYEO_APP_ID`.
- What remains:
  - full R3: move Lines to XPC;
  - the recycle of a stuck Docs service;
  - R6, R7 and R8.

## 7. The 1.1.2 recommendation

| | A: R1–R4 (Docs worker, router, hint, backoff, drain; Lines local) | B: VN + grouper (v1.1.0 behaviour) + hint and backoff fixes |
|---|---|---|
| Work | 4 rounds, ~1,100 lines changed (~450 deleted), wall ~1.5–2 days with benches | 1 round, ~100 lines: no doc model (`ocrPath` default `vn`), drop the doc and swiftText warm-up steps, G5/G8/G9/G13/G27 for VN |
| Risk | Medium: new XPC target, signing and notarization of a nested bundle (dry-run notarize), IPC equivalence (gated) | Low |
| Throwaway | none: every round is a step of the target | the VN-only switch and some fixes are redone in 1.1.3 |
| Never silent | yes: doc compiles reroute to VN; in-process rev3 width-class compiles hint at 3 s and, for Latin, Docs `.fast` reads | yes for VN stalls (hint at 3 s); no doc compiles at all |
| Paragraph quality | auto: use-case 160–161/251; papers 40/69, docs-web 60/89, subtitles 15/19 | vn: 123/251; papers 26/69 (merged 30), docs-web 43/89, subtitles 7/19 (`/tmp/reader/b2.log`) |
| Public-user view | first release with the document reader; doc layout ~3.5 min after a fresh install, VN layout before | same as v1.1.0; release notes must drop what needs the doc reader (measure: paper bench on `MWOYEO_OCR_PATH=vn`) |
| Memory | + Docs worker (est. 50–90 MB) | unchanged |

- **Recommendation: A.** It ships the reader that the 1.1.1 notes already advertise. Its parts are the target's first slice. Its decisive gate fails on main by construction.
- **Take B** only if 1.1.2 must ship today. Then land A in 1.1.3.
- The lead decides with the user.

## 8. Open measurements (named, not run)

| Measurement | Decides | Expected |
|---|---|---|
| `footprint -p` of the GUI and each worker after warm-up and after 300 reads (p13 + chat, Release), Δ per read | idle exit and recycle thresholds; whether two workers fit 650 MB; the forum leak on 27.0 | Lines 30–60 MB, Docs 50–90 MB, Δ ≈ 0 |
| Two concurrent clients → two worker pids (R1 gate) | per-instance drain semantics | two pids |
| In-process vs XPC lines on 58 pictures (R1 gate) | the move does not change OCR | identical |
| Paper bench with `MWOYEO_OCR_PATH=vn` on the RC | option B's cost in the release notes | regressions in columns and merges |
| Thread count during a stall (`sample <pid>`: threads in `perform`) | how much G27 contributed to the 90 s | up to the pool width (10) |
| e5rt cache path of a sandboxed XPC service | where the gate counts entries | the service container's Caches |

## 9. Places outside the assignment where improvement looked possible (report only)

- `App/Support/SelfTest.swift:133`: still renders default to seamless while the app default is adaptive (`Settings.swift:197`), so the benches do not measure the shipped mode. 1 line, plus new baselines.
- `App/Model/RegionSession.swift:405-417`: `hintSignals` maps only `languagePackMissing`. A lens whose reads succeed but whose translation keeps failing or timing out is silent on its pill. ~15 lines.
- `App/Pipeline/RegionPipeline.swift:1582-1600`: `Trace` lives in the pipeline file and is used app-wide. Move to `App/Support/Trace.swift`. Mechanical.
- `Core/Sources/MwoyeoCore/RetryBackoff.swift`: five unrelated types in one file (`RetryBackoff`, `SourceStrikes`, `HealthyBackoff`, `StrikeRule`, `ReadBackoff`). Split with R2. Mechanical.
- `App/Model/RegionSession.swift:287-380` and `CaptureRecovery`: a third backoff with its own constants. Fold into the `Backoff` table. Small.
- `App/UI/MenuPanel.swift:101`: `.id(model.sessionTick)` rebuilds the panel on every pass while it is open (flow-contention). Small.
- `tools/ocr-probe/README.md:7`: says the app asks no Swift Vision request. Stale since 0d348da. Doc fix.
- `/tmp/ocr-stall/r112/cold/mkcold2.sh`: the only fresh-cache method lives in /tmp. Promote in R4. Small.
- `App/Support/Relaunch.swift:36-41`: the successor waits only 5 s for its predecessor. With workers this should become "until its warm-up drained" (R8). Small.

Verification commands run: none (read-only design round; no builds, renders or box runs). Model: Opus 5.5 (`claude-opus-5-5`).


## 10. Amendments after the advisor review (2026-10-18, adopted)

1. **Lines moves to XPC in 1.1.2.** There is no `.local` transport. R1 builds both roles from one source dir, with the role set in Info.plist. R3 wires both roles. R5 is folded in. The Code-13 recycle is in 1.1.2: only a process restart ended the measured 3 h streak.
2. **The harness comes before the host.** A new round, R0 `harness`, runs in parallel with R1 and R2 and owns `App/Support/SelfTest.swift`. It adds `--mode adaptive`, `silence:`, `hint:`, `drain:` and the hooks for `reader:` and `reader-ready`. R4 keeps `reader-cold.sh`, the README and the decisive run.
3. **`warming` never hits the stuck rule.** It has its own bound of 400 s (≥ 2× the longest warm-up), and a warming worker is never recycled. The stuck bound for a lens job is 240 s, not 180 s.
4. **Late results.** For each client, the first result for the newest frame wins and a later one is dropped. Recovery re-reads are symmetric:
   - on `readerReady(.docs)`, lenses whose layout came from a reroute re-read once;
   - on `readerReady(.lines)`, lenses that read through `.fast` re-read once.
5. **A new language key while a lens is on gets no warm-up job.** The lens's own read is the compile.
6. **Signing.**
   - Each service target gets `ENABLE_HARDENED_RUNTIME: YES`.
   - The get-task-allow check in `scripts/release.sh` loops over `Contents/XPCServices/*.xpc`.
   - The notarize dry-run is release.yml `workflow_dispatch`, run by the lead.
   - The Developer ID build is not sandboxed. Isolation (F1c) is the reason for XPC; the sandbox matters only for MAS.
   - Under the MAS sandbox an idle worker can only be recycled by the exit message.
7. **More gates.**
   - Footprint of the GUI and the workers after warm-up and after 300 reads, against §4.16 (R4 assert).
   - Equivalence also on `MWOYEO_OCR_PATH=vn`, and on BGRA frames packed like SCStream frames.
   - A crash gate: `MWOYEO_FAKE_READER=crash` → relaunch after `Backoff`, and the lens continues.
   - N = 8 s holds for a single lens. Each lens queued ahead adds ~0.9 s.
   - The warm-up order Lines → Docs is load-bearing and gets a unit test.
   - `--max-wait 600`.

Order: R0 ∥ R1 ∥ R2 → R3 → R4. Then R6 (translation dispatch), R7 (read memo) and R8 (relaunch drain).

## 11. Blocks are one column, a translation is one paragraph (D1 design, I1 implementation, 2026-10-19)

Appended after §10. Evidence is from main `a53646c`, our own paper (`tools/paper-own`, 13 pages), the use-case set and arXiv 1706.03762; the numbers come from
`tools/paper-bench/RESULTS-own-2026-10-19.txt` and from a replay of `Territory.trim` with the real Core code (now the Core test `territoriesOfTheWholePageStayWhole`, on the recorded blocks of p2).
Status and the results of the implementation round (I1) are in 11.9.

### 11.1 What happens today

On a two-column page the document reader sometimes returns one paragraph whose lines are in two columns: the last lines of column 1 and the first lines of
column 2 (the sentence goes on at the top of the next column). Page 2 of our paper has one, reader paragraph 19: three lines at x 141, y 1867-1960, then four
lines at x 837, y 154-283.

| Step | What | Where |
|---|---|---|
| Reader | `RecognizeDocumentsRequest`, one `Container.paragraphs[i]` per paragraph; its own `boundingRegion` is already one quad (146,152)(1498,156)(1492,1964)(141,1960) | `Shared/VisionExec.swift:126-137` |
| Block | `makeBlock`: rect = union of the lines = 1349 x 1805 px, 71 % of the page | `TextRecognizer.swift:501-511` |
| Territory | `want` of that block holds all 32 others; `trim` cuts each pair at the middle of the overlap of their cores, on the axis with the smaller overlap | `RegionPipeline.swift:1059-1075`, `BlockLayout.swift:128-150` |
| Draw | a patch of 0-1 px has no text area: nothing is drawn, the source stays; a patch cut at x = 470 or x = 1167 holds half of its source | `BlockRenderer.swift:76-78, :120-121` |

There is no container, table, list or figure region in the path: the app reads leaf paragraphs only (`document.paragraphs`), and the big object is an ordinary
paragraph. Vision's flat `paragraphs` list also holds the cells of tables (35 of 36 cell texts on p3) and the page-wide `document.text` container (99 lines on p2) is
never read. The same paragraph shape is the cause on the four crops of the paper bench that show it (p1-c1, p4-c2, p7-c1, p12-s1). Page 2 has no float at all: the cause needs a
column break and nothing else.

Result on p2, 33 blocks drawn, none correct: 16 translations not drawn (patch 1 px high; their 39 source lines stay in English), 15 squeezed (12 cut in width at the middle of their overlap
with the big block, 8 in column 1 and 4 in column 2, the big block's own patch is then x 470-1167; 3 cut in height; the cut-off part of the source stays in English), 1 cut to an ellipsis, and the paragraph itself, drawn at the middle of
the page (ink 475,962 644x151) over 9 source lines of other blocks, while its own 7 lines stay unerased. `score.py`: cross_col 32, clipped 17 on p2; 36 and 27 on the 13
pages; 53 and 55 on the 26+2 crops. 1706.03762 shows 1 and 15 because it is a one-column paper: no paragraph can go on at the top of another column, and no page has a
paragraph larger than 6 % of itself (p2 here: 71 %; every other page of ours: at most 13 %).

### 11.2 Invariants (each has a gate in 11.6)

| ID | Invariant | Gate |
|---|---|---|
| B1 | A drawn block (a *piece*) is one column: its lines never climb (no line whose middle is above the top of the line before it) | `ColumnBreakTests` |
| B2 | A piece's rect holds no other block (half of the smaller one, the `cross_col` test) except a piece that stands beside its last line (G10) | `layout: ... holds=N`, `cross_col` |
| B3 | A paragraph that goes on in the next column has **one** translation, requested once (its text is the source of every piece); each piece draws its share (`FlowSplit`) | `FlowSplitTests`, bench pairs |
| B4 | A cut is made only where the old path was wrong: the block climbs **and** its rect holds half of another block | firings 5/41 own renders, 0/46 on 1706, 1/40 use-case |
| B5 | A territory smaller than half of its core is counted and traced, never silent | `layout.squeezed` stat |

### 11.3 The target flow, one owner

```
document paragraph (lines in reading order)
  → readableLines                         (as today)
  → ColumnBreak.pieces        [new, Core] cut at a climb, only when the rect holds another block
  → joinSplitLines, splitByStyle          (as today, now seeing pieces, not the union)
  → piece i of n: OCRBlock(rect = union of its lines, lines, text = the paragraph's text, part = (i, weights))
  → verdict, layoutPlaces, erase          (as today, per piece)
  → translation of the paragraph (one request, keyed by the paragraph text, as today)
  → renderMissing: FlowSplit.slices(translation, weights)[i]   → BlockRenderer (as today, per piece)
```

- **Owner.** `ColumnBreak` (Core, `ColumnBreak.swift`, beside `BlockMerge` and `Territory` of `BlockLayout.swift`: the files that say "which recognized blocks are one block,
  what area each may paint"), called from one function, `RegionPipeline.readBlocks` (new; it replaces the chain written twice at `RegionPipeline.swift:828` and `:909`:
  `readableLines → ColumnBreak → joinSplitLines → splitByStyle → flowed`; `flowed` hands the paragraph's text to the pieces that came through whole). The cut comes **before** `joinSplitLines` so that the merge rules see pieces, not a union that
  "starts inside the width" of everything (`BlockMerge.endsWithPiece`).
- **A piece goes on, or stands alone.** `ColumnBreak.continues(previousLast:nextFirst:)`: the sentence of the piece before was not ended (`. ! ? 。 ！ ？ … :`) and the
  next piece starts with a lowercase letter, or a letter of a script without case. Otherwise the pieces are paragraphs of their own, each with its own text and
  translation (today's 1.1.0 line-grouping behaviour; p12-s1: a prose line, then a shell command of the next column: `$ cd ...` stands alone and is kept as written by the
  prompt rule). On the six firings the next piece starts with a lowercase letter in five (p2, p1-c1, p4-c2, p7-c1, d03) and with `$` in one (p12-s1); the end of the sentence before is known for p2 and d03 only (both go on).
- **FlowSplit.** One translation, `n` pieces, weights = characters of each piece's source lines (p2: 166 and 177). Cut `k` is the nearest space to the weighted
  position within 12 characters; text without spaces (Han, kana, hangul) is cut at the nearest character that neither starts with a closing mark nor follows an opening
  one. The pieces joined with a space read as the translation. Pure, in Core, no engine call: a column break costs 0 extra requests (two requests would cut a sentence
  in the middle: "Lines" alone at the foot of column 1). The p2 translation comes out cut at "… 라인은 읽기 순서대로 | 최대 세 개의 새로운 라인으로 …".
- **Consumers.** The pieces share the paragraph's `source`, so the cache, the queue, the strikes, `checkPreempt` and the context lines are unchanged (they already
  handle two blocks with one source). Only places that list blocks to a person or a gate need one entry per paragraph: `texts` in `emit` (Copy Text and the lens export would
  repeat the paragraph), `debugState().blocks` (the self-test's source/translation pairs, which the use-case scorer reads), and `capBodySizes` (characters of the paragraph
  against lines of the piece: still body-like).
- **Containers, tables, lists, figures.** Containers are never blocks: only leaf paragraphs are read, `document.text`, `title`, `tables` and `lists` are not (keep it so; a
  reader that starts to read a container would meet B1). Tables are read as cells, one paragraph per cell (a row would join cells across the gutter: B2); lists as the
  paragraphs Vision gives for their items; figures have no object in Vision's document, their text comes as short paragraphs (labels, captions) and the existing
  `LabelRule`, `LabelSize`, `VerticalText` keep them. The rule is geometric and has no case for any of these.

### 11.4 Resource timeline (one seamless pass of p2, warm, from `p2.err`)

| Resource | ms | What |
|---|---|---|
| ANE | 1027 | line read 460 + document read 566, one after the other (the decider needs the lines first) |
| Host CPU | ~310 | erase 178, frame to RGBA 124, layout and `trim` < 1, `ColumnBreak` < 0.1 (a climb test per line, ~1200 rect tests among 35 blocks) |
| GPU, PCIe, NVMe | ~0 | MI-GAN only on textured backgrounds; unified memory; no disk in the pass |

The wall is the sum, led by the ANE read; the fix is under its shadow (0 ms either way). It is a correctness change, not a speed one, and no async, bulk, SIMD or SIMT lever
applies. The one flow decision is the translation request: one per paragraph (B3), not one per piece.

### 11.5 Gap table (main `a53646c`; line numbers in `RegionPipeline.swift` as of the design, before R3a)

| # | Where | Today | Target | Size |
|---|---|---|---|---|
| G1 | new `ColumnBreak.swift` (Core) | nothing cuts a block that climbs | `ColumnBreak.climbs/pieces/holds/continues/chains`, pure, with tests | S |
| G2 | `RegionPipeline.swift:828`, `:909` | the chain `readableLines → joinSplitLines → splitByStyle` is written twice | one `readBlocks` with `ColumnBreak` before `joinSplitLines`; counter `ocr.column_break`, trace line `column break: block i → pieces [3, 4]` | S |
| G3 | `TextRecognizer.swift:9-13` `OCRBlock`; `RegionPipeline.swift:105-126` `Block` | a block is a union of lines with its own text | `part: FlowPart?` (index, weights); `text` = the paragraph's for every piece; verdict on the paragraph | M |
| G4 | new `FlowSplit.swift` (Core: `FlowPart`, `slices`, `share`, `resolve`); `RegionPipeline.swift:1524-1545` `renderMissing` | the whole translation is laid out in the block | the piece's slice (`FlowSplit.share(of:part:)`) | S |
| G5 | `RegionPipeline.swift:350-357` `debugState`, `:1558-1561` `emit`; `SelfTest.swift:306` | one entry per block | one entry per paragraph (the piece with index 0) | S |
| G6 | `BlockLayout.swift:~330-374` `LayoutCheck`; `SelfTest.swift:318-335` | counts overlaps, spill, cut, clipped | `holds` pairs, `layout: ... holds=N` appended (the `score.py` regex ignores a suffix) | S |
| G7 | `RegionPipeline.swift:1059-1075` `layoutPlaces` | `trim` may return a 0-high territory without a trace | `Trace.count("layout.squeezed")` and a line for each territory under half of its core; no behaviour change | S |
| G8 | `BlockRenderer.swift:50` `eraseMargin` | the ring formula is in the App, so a Core test cannot share it | `Territory.ring(lineHeight:)` in Core, `eraseMargin` calls it | S |
| G9 | `tools/ocr-probe/`, `tools/paper-bench/score.py` | the probe and the replay are in `/tmp/d1` | `structure.swift` (document dump), `column-break-census.py` (firings from the traces), `score.py` prints `colbreak` and `squeezed`; the replay became a Core test | S |
| G10 | `RegionPipeline.swift:1082-1110` `splitByStyle` | a piece beside the short last line of a paragraph is split off again by style and lies inside the paragraph's rect (p5, p6, p8, p9: 4 pairs) | design needed: carve the paragraph's want around the piece, or keep it in the block; not in this fix | M, [later] |

In scope: 1 M + 8 S (about 300 lines of code, 250 of tests); one round. G10 is the residual B2 class and keeps the paper-bench bound at 4, not 0.

### 11.6 Gates for the implementation round

1. **Core unit tests, FAIL-first** (fixtures recorded from p2, the 1706 figure, the d03 picture: `Core/Tests/MwoyeoCoreTests/ColumnBreak*Fixture.swift`). On the code as it is on main
   (`ColumnBreak.pieces` stubbed to return one run per block): `territoriesOfTheWholePageStayWhole` fails with `whole=0 squeezed=16 dropped=17 of 33`, `theParagraphThatGoesOnInTheNextColumnIsCutAtTheClimb` and
   `theMagazineParagraphThatGoesOnInTheNextColumnIsCutToo` fail; with `ColumnBreak`: 10 tests pass, whole = 34 of 34. Also: a climbing block that holds nothing is left alone
   (1706 p14), `continues` on six recorded pairs, `FlowSplit` joins back to the translation for 1 to 6 pieces and never cuts before a closing mark.
2. **Paper bench, our paper** (`tools/paper-bench/run.sh`, same binary build, `--warm`): `ocr.column_break` fires on exactly 5 of the 41 renders (p2, p1-c1, p4-c2, p7-c1, p12-s1);
   the `block:` lines of the other 36 are byte-identical to a render of main at the same bundle id. Pages: **cross_col 36 → ≤ 4** (32 are the pairs of the one block of p2; the 4 left
   are G10: p5, p6, p8, p9), **clipped 27 → ≤ 12** (10 on the pages other than p2, which G1-G4 do not touch, plus at most 2 for p2; the spec's 15 is the safe line),
   `overlaps/spill/cut` stay 0. Crops: **cross_col 53 → 0** (all 53 pairs involve the one block of a firing crop), **clipped 55 → ≤ 15** (11 outside the four crops, plus 4).
   p2 alone: `layout: blocks=34 overlaps=0 spill=0 cut=0 clipped≤1 holds=0`.
3. **1706 pages and crops** (a render of main at the same bundle id; the b113 run `/tmp/lead-final/b113/main-paper` gives the same census): the counter fires 0 times (its 9 climbing blocks are rotated figure words that hold nothing), so
   the `block:` lines of all 46 renders are byte-identical and the totals are the b113 ones: pages blocks 343, clipped 15, cross 1; crops blocks 265, clipped 7, cross 1.
4. **Use-case bench** (`tools/usecase-bench/bench.sh`, 40 pictures, auto): the counter fires on d03 only; the segmentation scores of chat, docs-web, games, papers and subtitles
   equal main (d03's unit "Hikers have noticed..." stays *correct*: one pair per paragraph, G5), code not worse (its 8 pictures never fire). Any other firing is a finding.
5. `cd Core && swift test` rc=0, `xcodegen generate && xcodebuild ... build` rc=0, `--capture-ui ... check-logic` all PASS.

### 11.7 Order and overlap with R3a

R3a landed first (7f8d1af). It rewrites `TextRecognizer.swift` (`makeBlock` moves from :501 to :232 and is not edited by this design), deletes `DocsHost.swift` (the reader trace above then reads
`RecognitionHost.swift`), and edits in `RegionPipeline.swift` only `:172-178`, `:253-264`, `:496-511`, `:813-820` and `:886-893` (the `lines(...)` read calls) and `noteReadFailure`. This design
edits `Block` (:105), `splitByStyle`'s neighbours (:974-1110), `renderMissing`, `emit`, `debugState`: none of R3a's hunks. The two places that touch the same file regions are the `OCRBlock`
struct (R3a adds three doc lines under it; G3 adds one field) and `docs/design/recognition.md` (R3a adds a status block at :542; this section goes at the end).

### 11.8 Not done here

- The residual class G10, and list items that Vision cuts into several paragraphs around inline mathematics (p2 item 1 comes as three blocks, `ocr-block 10-12`): the inline-math rounds own them.
- Reading the climb from Vision's own region: it has none (the paragraph's `boundingRegion` is one quad), so the rule has to be ours.
- A multi-frame CoreText flow instead of `FlowSplit` (the text is laid out through the pieces in one pass and the font size is fitted to all of them): better fit, L; only if the slices look wrong.

### 11.9 Status after I1 (2026-10-19, main 7f8d1af + the round)

Rows G1-G9 are in; G10 is not. Evidence: `tools/paper-bench/RESULTS-own-column-break-2026-10-19.txt`; base and candidate are Release builds of one bundle id.

| Gate | Design | Measured |
|---|---|---|
| Core | FAIL-first on the recorded p2, `cd Core && swift test` rc=0 | unfixed: `whole=0 squeezed=16 dropped=17 of 33` (7 issues in 5 tests); fixed: 760 tests, 17 new, rc=0 |
| Own paper pages | cross_col 36 → ≤ 4, clipped 27 → ≤ 12 | 36 → 4 (p5 p6 p8 p9: G10), 27 → 10; overlaps/spill/cut 0 |
| Own paper crops | cross_col 53 → 0, clipped 55 → ≤ 15 | 53 → 0, 55 → 11 |
| Firings | 5 of 41 | p2, p1-c1, p4-c2, p7-c1, p12-s1 (p12-s1: `shared [0, 1]`, the prompt stands alone) |
| 1706 | 0 of 46 | 0 of 46; `core/lines/chars/source` of every block equal to a render of main |
| Use-case | the five old categories equal, code not worse, d03 only | chat, docs-web, games, papers, subtitles 160/251 as main; code 0/142 both; d03 only |
| Builds | check-logic, check-instruments, MAS ad-hoc | all passed; 20 PASS; rc=0 |

Not byte-identical, and not a regression: the engine is not deterministic ("조건 A" / "조건 a"), so the `text=` and `size=` of a `block:` line move by a few pixels between two renders of the **same** binary. The fields
the pipeline decides (core, lines, chars, source) are equal. A render of main also changes its reader path under load (`reader.docs.suspect` → VN lines on 1706 p13), so compare the `work[...]` line before a count.

Decisions made while implementing:

- `ColumnBreak.chains` carries the "goes on / stands alone" rule per pair of pieces (a block of three pieces may share the first two and leave the third alone); `FlowSplit.resolve` (Core, pure) is what `RegionPipeline.flowed` asks after
  the chain: a paragraph whose pieces did not all come through `joinSplitLines` and `splitByStyle` whole, in order, is a set of paragraphs of their own (each with its own text and translation: today's behaviour for that piece).
- `ocr.column_break` counts blocks cut (summed over the passes of a render); the trace line is `column break: block i '<first 24 characters>' → pieces [n, m], shared [chain ids]` (`i` is the index after `readableLines`, not the `ocr-block` number).
- `MWOYEO_LAYOUT=off` also switches the column break off (it is a layout rule).
- `Copy Text` and the self-test list a paragraph once, at its first piece's frame; a lens that covers only the second column does not list that paragraph, although its second piece is drawn (an edge of the choice, not measured).
- `layout.squeezed` found two blocks of our own paper cut to under half of their core (p6 'Size.': 57x22 px beside a larger block; p8 'They are not re-': the piece of G10) and one on 1706 p11 ('Bowen'); it counts, it changes no pixel. `Size.` and `Bowen` are one-word lines whose territory a neighbour takes: the next candidates for the stat's trace.

Left open: **G10**, the four pairs on p5, p6, p8 and p9 (a piece that stands beside the short last line of a paragraph is split off again by style and lies inside the paragraph's rect: design needed), the list items that Vision cuts around inline mathematics
(p2 item 1 comes as three blocks), and the translation's cut points (`FlowSplit` cuts at a space by the share of source characters; only a vision verdict on the p2 and d03 pieces can say whether the slices read well: no vision round was run here).


### 11.10 A row of a display inside a paragraph (D14, round d14, 2026-10-21)

The reader sometimes puts the row of a displayed equation into the paragraph beside it (page 6 of the method paper, eq (10): glued to the sentence above in film3's take, to the paragraph
below in 2 of 12 captures one point apart, a block of its own in the other ten). The rules that keep a row as written judge blocks, so a glued row was translated with its paragraph
and drawn as text over the typeset equation. The chain gets one more step, before the column break (a cut row is a block of its own, not a piece of a flow) and before the joins (pieces
half a line height apart share no text row and do not interlock, so `BlockMerge` does not take them back):

```
readableLines → DisplayRow.pieces [new, Core] → ColumnBreak.pieces → joinSplitLines → splitByStyle → flowed
```

| Stage | Before | After |
|---|---|---|
| Docs paragraph / `ParagraphGrouper` | glue a display to a paragraph (the Docs model by a pixel of the capture; the grouper at a gap of 0.6 heights) | unchanged, the step after them does not care which |
| `readBlocks` | no step that looks at the rows of a block | `RegionPipeline.displayRows` cuts each block with `DisplayRow.pieces` (the one caller) |
| `TextRecognizer.verdict`, `CodeKeep` | judge the glued block as prose | judge the row alone: `isLiteral`, then `Reason.equation` (D8) |
| `flowed` / `FlowSplit` | pieces without a `FlowPart` pass through | the cut pieces are blocks of their own, no `FlowPart` |

`MWOYEO_LAYOUT=off` switches the step off with the other layout rules; the counter is `ocr.display_row` and the trace line `display row: block '<first 24 characters>' → pieces [n, m]`.
The rule, the numbers and every guard: docs/design/keep-boundary.md section 10.1.


## 12. A bad program cache leaves lines out of every answer (D4, round d4root, 2026-10-21)

**What was seen.** A lens over "Controls and noise." of the method paper (film3) dropped the fourth line of the paragraph: in no log entry, English on the screen between two Korean blocks. The trace listed 22 lines of a frame that holds 26. The four it lacked were the four widest boxes of the frame (aspect 25.0 to 32.4; every line it kept was at most 24.8). Nothing in that run's log named an error, a retry or a low confidence; the Lines service answered rev3 in 507 ms and 229 ms.

**Cause.** Vision's programs are compiled once into the service's e5rt bundle cache (`~/Library/Caches/<id>/com.apple.e5rt.e5bundlecache/<system build>/…`). A cold compile can end in a cache that is wrong without any error: one of about fifteen cold compiles here (the eight natural compiles after it were all good) (a standalone tool with the same binary and the same frame) read the frame as 22 lines, process after process, and the same binary after a fresh compile read 26 (15+ runs each way, `tools/ocr-probe/lines.swift`). A page of single lines at 3 sizes and 11 widths shows the shape: the good caches read all 33 lines (7 caches, 14 reads), the bad one 25, the missing ones in a band of widths (about 920 to 1250 px wide at 31 px type; 0 to 6 of 10 such lines came back). The detector is shared, so revision 2 and `.fast` lack the same lines, and a strip of one line that is read alone is read. The grouper, Docs, `automatic`'s decision, the ROI, the frame diff and the translation split were each ruled out by a read that kept the lines (list and numbers in the round's report).

**Owner and fix.** The Lines service is the process that owns the cache, so it reads the check page (`VisionExec.checkPicture`, 33 drawn lines) once after its programs exist (`ReaderWorker.verifyPrograms`). The verdict is `ProgramCheck.verdict` (Core: more than 3 missing is bad). A bad cache is dropped (`E5Programs.reset`, counted in a mark beside it) and the service exits; the host sees a lost service, restarts it and reads again, and the next process compiles fresh. After 2 resets it serves what it has and logs it. A cache that read well is marked beside it (`<Caches>/<id>/programs-verified`: the system clears what it did not write from its own cache directory, measured 2026-10-21), naming the compiled programs by name and birth and the system and service builds, so the page is drawn once per cache, not once per launch; a cache compiled again, or one that got a program, is another list. `check-logic` draws the same page through the host (`program-checks`), so a bad cache of a gate's id is a FAIL there.

**What is not done.** The Docs service has a cache of its own that may fail the same way; its answer has no drawn page to compare with. A lens that starts before the warm-up never gets Docs for the process (`ReaderWarmup.want`); not changed here. The read-again of a hole between two lines of a column (a strip read) was built and dropped: the failure is in the detector, so a second read of the strip gets the same answer from a bad cache, and it costs 60 to 120 ms per false hole on a good one.


## 13. A word the typesetter broke at the end of a line (item 1, round read117, 2026-10-22)

**What was seen.** Film3's take of page 6 of the method paper showed "noth-ing": the reader gives the lines of a paragraph, `TextRecognizer.makeBlock` joined them with a space, none after a hyphen ("noth-" + "ing" → "noth-ing"), and the engine got the word in two pieces. The paper bench's sources carried 98 of them (`tools/paper-bench/hyphens.py`: a token `stem-rest` whose joined form is an English word of `/usr/share/dict/words`, over the 41 renders of `paper-115`), among them "con-text", "ma-chine", "lo-cal", "Sec-tion", "mini-mum".

**Owner.** `TextRecognizer.makeBlock` is the one place that joins lines (both reader paths, `joinSplitLines`, `columnBreak`, `flowed` and `splitByStyle` all remake blocks through it), so the rule is there, in Core as `LineJoin` (pure; the caller says which characters are CJK and which strings are words). Not a pass of its own: a pass after `readBlocks` would see the text of a block, not its lines.

**The rule.** The hyphen at the end of a line is dropped when all of these hold, else it stays as before (the join of 1.1.6, bit for bit):

| Table row | Reason it is a row |
|---|---|
| the stem is two or more ASCII letters, the first may be a capital, the rest lowercase, and it starts at a space, a bracket or the start of the text | `readNoth-` (camelCase), `foo_bar-`, `--no-`, `src/some-`, `a.b-` and `state-of-the-` are code or names, not stems |
| the first word of the next line is two or more lowercase letters and ends at a space or at marks of a clause (`, . ; : ) ] ! ? " ” ’`), after a possessive `'s` if there is one | a continuation that is capitalised, a digit, `-`, `_`, `/`, `@` or `.swift` is a compound or a name ("Berkeley-Parser", "COVID-19", "to-German", "ing.swift") |
| the joined form is an English word (`EnglishWords`: `NSSpellChecker`, the system's local dictionary, language named `en`) | "sequence-aligned", "position-wise", "co-occurrence", "x-ray" and "Ko-ray" are not words once joined, so their hyphen stays; a Mac without the dictionary says no to everything, which is the join of before |

`OCRBlock.text` stays as the lines read (the keep rules, `CodeRegion`, `InlineLiteral`, `TranslationFilter` judge it as before: a hyphen that sits in code is never dropped, the stem and continuation rows see to that); `OCRBlock.prose` is what goes to the engine, the cache key and the `BlockMatcher`. So the rules that keep a block as written see no change and the translation sees a whole word. The pipeline counts `ocr.hyphen_join` and traces `hyphen join: <words>` (the first piece of a paragraph that goes on in the next column stands for the group).

**Gap table.**

| Piece | Before | After |
|---|---|---|
| `TextRecognizer.makeBlock` | text = lines + " ", none after "-" | `text` as before; `joined` = the words whose hyphen was dropped, `prose` = the text of them |
| `RegionPipeline` (source of `Block`, `BlockMatcher` input, cache identity) | `ocr.text` | `ocr.prose` (`readBlocks` result, both passes) |
| `flowed` (a paragraph's pieces share one text) | `makeBlock(all lines).text` | also `joined` |
| `TranslationFilter`, `CodeKeep`, `InlineLiteral`, `restoreSourceTokens` | judge `text` | judge `text` (unchanged) |
| Gate | none | `LineJoinTests` (16 cases; every row of the table is a guard that fails when removed, see the report); `tools/paper-bench/hyphens.py` (exit 1 when a broken word is left) |

**Numbers.** `hyphens.py` on the paper bench (41 renders of our own paper): broken words left 98 (`paper-115`) and 94 (`paper-read117base`, main `dd652f0`) → 6 (build with this item), and the six are the paper's own hyphens ("non-linear" twice, "fall-back", "re-set" three times: a real hyphen is a word once joined, and the tool cannot tell it from a break); 122 words joined by the reader. `tools/paper-bench/attribute.py` (blocks paired by source text): 88 of 937 matched blocks differ, every one by a hyphen taken out of a word, none in another way (`other 0`); the 86 blocks that cannot be matched are the reader cutting the text another way, which a render of the same build does as well (`paper-115` against `paper-read117base`, the same code: 81 such blocks).

**Not done.** The dictionary is English: a German or French page keeps its hyphens as before (the checker could take the page's language). A word broken at a hyphen of its own ("self-" "attention") is a compound and stays by design.


## 14. The last line of a wrapped message (item 2, round read117, 2026-10-22)

**What was seen.** A chat render read the message "マジでここが今までで一番いいコミュニテイだわ" as two blocks, "マジでここが今までで一番いいコミュニテ" and "イだわ", and translated the tail alone. The tail is a line of one to three characters under a full line of the same message. The document reader (Vision's document model, `reader auto → documentLayout`, the default path) cuts it off in some captures and keeps it in others; `ParagraphGrouper` (the lines reader) would take it in (a gap of 0.28 heights, left edges 3 px apart). The use-case bench has no scene that shows it: `tailcand.py` over its 156 renders finds three candidate pairs and none under a full line. The case was reproduced on a picture of our own, a Discord-like page in Japanese at three type sizes (14, 15 and 16 px, `/tmp/r117/item2`): the tail is a block of its own at 15 and 16 px, and at 14 px it is inside the paragraph in one pass and a block of its own in the next.

**Owner.** `BlockMerge` (`BlockLayout.swift`), the rule that says which recognised blocks are one block, run by `RegionPipeline.joinSplitLines` for both reader paths and for the lens and the seamless pass alike. The new row is `WrapTail` (Core), the rule for the tail of a wrapped message; `ParagraphGrouper.continuation` stays the one geometry of "the next line" and `WrapTail` calls it, so the two readers cannot disagree about what a next line is.

**The rule.** The block `t` is the tail of the block `h` when all of these hold:

| Row | Guards against |
|---|---|
| `t` is one line of one to three characters, at least one a letter, the others letters or the marks that close a sentence or quotation | a time ("20:21"), a number, a sign ("G＜6": a fragment of a formula that the paper bench has), a list marker, a lone mark |
| the last line `L` of `h` and the tail pass `ParagraphGrouper.continuation` (heights within 1.5, gap from -0.4 to 0.6 heights, left edges within 1.25 heights or centres within 0.5, no list marker) and the tail is no wider than `L` | a message of its own below another (a gap of 0.7 heights and more), an indented line, a heading |
| the text of `L` does not end in a sentence end (`.!?…:;` and the full-width ones) | a short answer under a message that ended |
| `L` is full: the lines of the column (those that overlap `L` by half of the narrower) end at one edge, `L` ends within one height of it, and at least one other line does | a list or a log, where the longest line is not wrapped; the other column of a page |
| one tail for one head | |

**Gap table.**

| Piece | Before | After |
|---|---|---|
| `BlockMerge.groups` | interlock and the lone piece beside a last line | also takes `tails: [WrapTail.Pair]` |
| `RegionPipeline.joinSplitLines` | `BlockMerge.groups(rects)` | `WrapTail.pairs(lines:texts:)` first, then `groups(rects, tails:)`; counter `ocr.wrap_tail`, trace `wrap tail: '<tail>' ends '<12 characters>'` |
| `ParagraphGrouper` | the grouper's own joins | unchanged |
| Gate | none | `WrapTailTests` (11 cases on the real coordinates of the picture; every row is a guard that fails when it is removed, see the report) |

**Numbers.** The use-case bench: `ocr.wrap_tail` fires in none of the 156 renders (no scene has the tail), and no row of the bench moves on its account. On the picture of our own (`/tmp/r117/item2`, 14, 15 and 16 px, the same picture before and after): before, "イだわ" is a block of its own at 15 and 16 px (and inside the paragraph at 14 px in that run); after, it is one block with the line above at all three sizes, `ocr.wrap_tail=1` and the trace `wrap tail: 'イだわ' ends 'までで一番いいコミュニテ'` in each (at 14 px the reader cut it off in this run, which is the variation the rule is for).


## 15. Names inside a sentence (item 3, round read117, 2026-10-22)

**What was seen.** The App Store screenshot renders of 2026-10-19 showed camelCase and code names in running prose coming back in another case ("readme" as "REaDME", "gemma3" as "geMMA3", "Transactions" as "TrAnsActions", paper bench p12). Guards for a whole line existed (`TranslationFilter.isIdentifier`, bf0232b; `isFormula`; `CodeKeep`); nothing guarded a name in the middle of a sentence except one step after the translation, `TranslationCleanup.restoreSourceTokens` (the source's own spelling of every Latin token is put back where the translation holds it in another case).

**Causes found, in the order the data showed them** (`tools/paper-bench/names.py` over the outputs: a name is exact, recased, or lost):

| # | Cause | State |
|---|---|---|
| 1 | `restoreSourceTokens` replaced case-insensitively inside other words: the "A" of "A threshold" turned "Man" into "MAn" | fixed 2026-10-20, 818bc80 (the screenshot renders predate it) |
| 2 | A token took the sentence's full stop: the source token of "…to fitFontSize." is `fitFontSize.`, which the translation never holds ("fitfontsize에"), so a name that ends a sentence was never given back | fixed here: the tokens of a name-shaped word end at a letter, a digit or an underscore (`withoutClosingMark`; a plain word keeps its mark as before) |
| 3 | A one-word token matched the start or end of a name: the word "core" of "The core of ScrollPredictor, Core/Sources/MwoyeoCore/ScrollPredictor" turned the path into `core/Sources/...` (paper p9, p9-c1); the word "i" of a line of code turned `I.asgignnent` into `i.asgignnent` (p5) | fixed here: a range next to `.`, `/` or `-` followed by a letter or digit is part of a name, not a word (`standsAlone`) |
| 4 | The engine translates or splits a name ("ledgerline" → "원장 라인", `Array. prototype. flat ()` cut into two sentences at the OCR's space after a dot, `FrameDiff. swift` → "프레임디프. 스위프트") | not a case, so not fixable after the fact: the name has to be protected in the request |

**Why a name inside a paragraph is not protected on the default path (cause 4).** The one protection in the request is `ProtectedSpans`: a range of the source marked `skipsTranslation` in the attributed string of the request (Apple Translation, macOS 26.4 and later, `TranslationService.protectedSpans`). It is behind `MWOYEO_INLINE_MATH=1` (never in the App Store build), and what it marks is `InlineMath.spans`, which is formulas only: "deliberately narrow", no name, path or flag. `InlineLiteral` (Core: URLs, e-mail addresses, paths, commands, flags, identifiers, hashes, versions, config files, hotkeys; round H3, 2026-10-20: recall 0.89, 2 % false positives, 3.7 µs a word) is called by no app code at all. What it finds in the sentences of the bench that lost a name (a throwaway Core test, 2026-10-22):

| sentence | `InlineLiteral.spans` | `InlineMath.spans` |
|---|---|---|
| "Settings live in ~/.ledgerrc and it reads main.py first." | `~/.ledgerrc`, `main.py` | none |
| "Run it with --month 2026-09 …" | `--month` | none |
| "Call fitFontSize when the stepDuration is set, and kept_ok stays 0." | `fitFontSize`, `stepDuration`, `kept_ok` | `kept_ok` |
| "…ScrollPredictor, Core/Sources/MwoyeoCore/ScrollPredictor.swift, lines 31-68" | `ScrollPredictor`, the path | none |
| "FrameDiff. swift reads the frame and TextErase. swift paints." | `FrameDiff. swift`, `TextErase. swift` (the OCR split is handled) | none |
| "ledgerline reads plain text journals …" | none (a plain word has no shape) | none |
| "you can call Array.prototype.flat()." | none (only `ES2019`) | none |
| "(TextFitter.fitFontSize); when nothing fits" | none | none |

**What the flag changes on the benches** (this round's build, with and without `MWOYEO_INLINE_MATH=1`, paper bench and the `auto` renders of the use-case bench): the flag is live (`translate.marked` counts sources sent with their formulas marked in 30 of 41 paper renders, `translate.span_unresolved` those that did not come back), and the text does not move: of the 1027 blocks matched by source, the translation is equal in all 1027 (`attribute.py`, `other 0`, `case 0`), and the 370 `auto` blocks of the use-case bench are equal too. It protects formulas, not names, and nothing draws what it protects yet, so there is nothing to flip on the strength of these benches.

**Proposal, not done.** No flip of `MWOYEO_INLINE_MATH`. The step that closes cause 4 is its own round: `ProtectedSpans.Kind.literal` fed by `InlineLiteral.spans` behind the same flag (so the Apple default path stays byte-identical until a no-regression gate on both benches says otherwise), with the three misses above as new rows of the table (a dotted call, a name in brackets), and the case of the markers the engine returns first (the order the lead noted after H3). Cases 2 and 3 do not wait for it: they are in the default path now and change only text that came back in another case.

**Gap table.**

| Piece | Before | After |
|---|---|---|
| `restoreSourceTokens` tokens | `[A-Za-z][A-Za-z0-9_/.-]*`, a closing `.`, `-` or `/` part of the token | the same, a closing mark cut off a name-shaped token (`isNameShaped`: a capital after the first letter, a digit, `_`, `.` or `/` inside) |
| `standsAlone` | no letter, digit or `_` touches the range | and no `.`, `/` or `-` that is followed (or preceded) by a letter or a digit |
| Gate | the `restoresSourceTokenCase` cases | `NameCaseTests` (7 cases; every guard fails when removed, see the report); `tools/paper-bench/names.py` (exit 1 when a name comes back recased) with `check-text-tools.sh` for its FAIL-first |


## 16. A paragraph that crosses an edge of the capture or of the lens (item 4 and A5/F1/F2, round read117, 2026-10-22; the capture's side edges done, the lens's four edges design only)

**Two edges.** A lens is shown inside a larger capture (`Overscan.margins`: 80 to 240 pt a side at rest, 30 % of the lens, 40 % while content moves; clipped at the display). The pipeline reads and erases the capture; the overlay shows the lens. Text is cut at both, and the two are different edges with different fixes:

| Edge | What it cuts | Seen as | Owner today |
|---|---|---|---|
| capture, top and bottom | a line is read from its visible half | D3 (1.1.6) | `CaptureEdge.cut`, called by `RegionPipeline.readableLines`: the line is left as it is |
| capture, left and right | the starts or ends of every line of the column the edge runs through are read, and translated word by word | **F2** | none until this round: `CaptureEdge.cutAtSides` |
| lens, top and bottom | the lines of a translation that stand on the edge are cut through their glyphs; a paragraph that starts above the lens is read whole (it starts inside the margin) and drawn at its whole rect | item 4, d14, **F1** (bottom) | the overlay's one mask, the lens rect with a 12 pt corner (`OverlayPanel.swift:143`, `:157`) |
| lens, left and right | a paragraph wider than the lens: every Korean line starts or ends outside, its first and last syllables cut | **F1** | the same mask |

One rule for the four edges of each kind, in the owner of that kind: **a line is read whole or not at all (capture); a line is shown whole or not at all (lens).**

**What was seen** (film4 take `t0r-oldway`, main 5272f82 Release, page 6 of the method paper at ⌘0; `/tmp/film4/defects.md`). F1: a lens [339, 266, 354, 139] pt, 30 pt inside the paragraph's left edge, 50 pt short of its right edge and 30 pt short of its bottom. The paragraph (432 pt wide) lies inside the capture, is read whole, is drawn at 432 pt, and the mask cuts 30 pt at each side; the last Korean line sits on the bottom edge. F2: the lens dragged 95 pt right, to [339, 266, 453, 173]: its right edge stands 22 pt inside the next column. The capture reaches about 90 pt further and ends inside that column, so the column's lines are read from their first 112 pt: `render 'The predict (tk, dk, Ck)' patch 1256,285 224x180`, `render 'application an k that is' patch 1258,493 216x94` (app.err of the take). Each fragment is a block, translated word by word and drawn over the English; the lens shows the first 22 pt of each patch, and the English line goes on beside it, untranslated.

### 16.1 The capture's side edges (done)

**Owner and cause.** `CaptureEdge` (Core) is the rule for lines the capture cuts; it knew the top and bottom only ("the sides are not this rule", `PaperQualityTests`). The top and bottom rule tells a cut line by its height (the visible half is about half as tall as a whole line). A line cut at a side is as tall as a whole one and has no width to compare with (a cut line is as wide as a whole one in a justified column and wider than a short last line). What shows the cut is the edge itself: the lines of the column it runs through all reach it.

**The rule** (`CaptureEdge.cutAtSides`, called by `readableLines` beside `cut`):

| Row | Guards against |
|---|---|
| a line whose box reaches the left or right edge within 4 px (`tolerance`, the one of the top and bottom: a cut line ends 3 px short of the edge as often as at it) | a line that ends 5 px short of the edge is whole (tested at 4.5 and 5) |
| three or more lines reach the same side (`sideColumn`) | a heading, or two, at the edge of a picture cropped to the top left of a page: the use-case bench has five such lines in four pictures (d01, d02, d04, d05), never three |
| at least one line reaches neither side | a picture cropped to its text: every line reaches both sides, and a justified paragraph looks the same |
| a block that holds one cut line is left whole, not the line (`readableLines` returns no block; counter `ocr.cut_side`) | the last line of a cut paragraph, whole and short, translated alone as the fragment of a sentence |

The blocks are left on the picture as the lines of the top and bottom rule are: not translated, not erased. In F2 the English line starts stay as they were and the lens shows them.

**Census** (`/tmp/r117/read117/sidecensus.py`, the line boxes that the 197 renders of the benches trace, `ocr-block N lines:`): lines that reach a side edge within 4 px: paper 59, all in the two side-cut crops (`p7-s1` 41, `p12-s1` 18); use-case bench 5 in 4 pictures. So the rule changes the renders of those two crops and no other: the pages and the other crops have no line that reaches a side, and no picture of the use-case bench has three.

**Numbers.** The side-cut crops of the paper bench (words cut at the left and right edge), build `read117g` against `read117base` (same sources, `tools/paper-bench/score.py`): `side_cut` 20 → 0 (10 and 10); blocks `p7-s1` 14 → 3, `p12-s1` 21 → 6 (12 blocks left as written in each: `ocr.cut_side=12`); `edge_cut` of the two crops 4 → 0 (the blocks that the crop's top or bottom cut stood at a side too). The film's F2, as a crop of page 6 whose right edge stands 300 px (112 pt) inside the right column (`/tmp/r117/read117/f2crop/p6-f2.png`): 13 blocks → 7; the fragments `The predictor keeps the (tk, dk, Ck) with Ck € 1P moving the content dowr path from an event to t`, `1 = 16 ms, and the durat`, `application animates one k that is on screen at tim`, `Figure 2. The two curve equations, not measured: tl`, `(Eq. 11 with 1 = 16 ms, 1`, `A precise delta is a stej`, `time s` are no longer translated. A live lens in the film's geometry needs the screen lock, Preview and a vision verdict: not run here; the crop is the same capture, read by the same pipeline.

**Not done.** A column cut by fewer than three lines at the edge is left as before. A paragraph that the capture's edge cuts only in some of its lines (a ragged paragraph whose short lines end before the edge) is dropped whole only when the document reader put those lines in one block; where it gave each line a block (`p12-s1`), the short whole lines of the paragraph are translated as before. The lens's own left and right edges are 16.2.

### 16.2 The lens's four edges (design only)

**What the person should see.** The lens is a window on the translated page. What stands outside it is not wanted; what stands in it must be whole and be where the English was; the translation of a paragraph must not jump or reflow while the lens moves over it. Four things follow.
1. A line of text is shown whole or not at all: half a line is a glitch, a missing first line is only the window.
2. The translation keeps its place while the lens moves (no reflow per frame of a drag: the overscan was built so that a move is no re-read and no re-render).
3. The Korean line next to an English line that is erased is the paragraph's translation at that place.
4. A lens narrower than its paragraph still shows a translation: a lens 50 pt short of the paragraph's edge that shows nothing would look broken.

**Options for the top and bottom edges** (the 1 above):

| | what the lens shows | cost | against the four |
|---|---|---|---|
| O1 (today) | the whole translation at the whole rect; the mask cuts it | none | 1 fails at the edge line |
| O2 share | only the lines inside: the translation split by the share of lines that are inside (`FlowSplit`) and laid out again in the part inside | a re-split and re-render of the paragraph per lens move | 1 holds; 2 fails; 3 fails at the cut (the split falls on a Korean word, not on the English line break) |
| O3 shift | the translation moved so that its first line starts at the lens edge | none in the pipeline; a block image moved per lens move | 1 holds; 3 fails (the beginning of the translation over the middle of the English) |
| O4 whole lines | O1, with the lines that the edge cuts hidden: the block's layer carries a mask of the lines that stand wholly in the lens | `BlockRenderer.Rendered` returns the translation's line boxes (the `CTFrame` has them); the overlay sets a mask per block from the lens rect and moves it with the lens: no re-read, no re-render | 1, 2, 3 hold; costs a strip under one line high at the edge where the erased background shows |
| O5 soft edge | O1, the mask a gradient one line high at the top and bottom | one `CAGradientLayer` | 1 holds only as a scroll edge effect; the half line is still there, dimmer |

**Pick for the top and bottom: O4.** It makes the unit a lens frame shows what the person reads, a line, with data that exist, and needs no new input and no re-render per frame.

**Options for the left and right edges** (every Korean line of a paragraph wider than the lens crosses the edge, so O4's unit gives nothing here):

| | what the lens shows | against the four |
|---|---|---|
| S1 (today) | the lines at the paragraph's width, the mask cuts them | 1 fails on every line (F1) |
| S2 hide | the paragraph is not drawn while it crosses a side edge; the English shows | 1, 2, 3 hold; 4 fails: a lens a few points short of the paragraph shows nothing |
| S3 visible width | the block is laid out again in the part of its rect that the lens covers; lines whole; the lens's top and bottom edges then work as O4 | 1, 3, 4 hold; 2 holds if the layout waits for the lens to settle (during the move the standing image is clipped as today: F7) and costs a re-render of the blocks that cross a side edge once per settle |
| S4 fit | the lens is fitted to the paragraph: Fit to Column (fit117) | not a rendering rule: the person gets what the film's F4 and F5 are about; no nag, no first-run step |

**Pick for the left and right: S3, with S2 below a floor.** S3 is the only one that holds 1 and 4. A translation laid out in a strip of a few words a line is no reading, so a block whose covered share of its width is below `minShare` (to be measured with the fitter: the width at which `BlockRenderer` returns the smallest size, on the paper bench's blocks) is not drawn (S2). S4 stays what the person does when they want the whole column. F1's lens covers 354 of 432 pt (82 %).

**The one rule, in one owner.** A pure function in Core (`LensWindow`): given a block's rect and the lens rect, the width the translation is laid out in (S3) and the line boxes of the translation that end inside the lens (O4). `RegionPipeline` has the lens (`setVisible`, `RegionPipeline.swift:643`; `lensRect` `:1599`; it is used for the scheduling and the wait stats), and the blocks themselves stay lens-independent while the lens moves inside the capture: the layout at the visible width is a second image of the block, made when `motion stopped` and the lens crosses the block's side edge. A block wholly inside the lens is untouched (byte-identical).

**Gap table (main `dd652f0`).**

| Piece | Today | Needs |
|---|---|---|
| `BlockRenderer.Rendered` (`App/Pipeline/BlockRenderer.swift:37-47`) | `text`: one ink rect for the whole translation | `lines: [CGRect]`, the line boxes in the image (from the `CTFrame`); a render entry that takes a width |
| `RegionPipeline.Block` / `OverlayBlock` (`RegionPipeline.swift:22-27`, `:105-135`) | `frame`, `image`, `seamless` | `lines`, copied through the snapshot; `nil` for a box block (whole or off); the second image for S3 |
| `RegionPipeline` on `setVisible` + `motion stopped` | scheduling and wait stats only | the blocks that cross a side edge of the lens get the layout at the visible width (S3), once per settle |
| `OverlayHostView.updateVisibility` (`OverlayPanel.swift:264-275`) | `opacity` 1 when the frame meets the lens, 0 otherwise | for a block whose frame crosses the top or bottom edge: a `mask` on the block's layer, the union of the lines inside the lens, moved with the lens; none for a block wholly inside |
| Core `LensWindow` (new, pure) | none | cases: a block crossing the top, the bottom, both, a side, a corner; no lines; a line one point out; a lens wider than the block; a share below `minShare` |
| Gate | none | the Core cases; an app check that a block crossing the edge gets a mask and one inside none; one vision verdict (opus: half lines and cut syllables at the four edges, before and after, on the film repro and on a chat) with the screen lock |
| Debuggability | none | `overlay.line_masked` and `layout.visible_width` counters in the panel's stats |

Open: whether the hidden strip should show the English line it stood over (the erased background shows there in the seamless mode, which is the lens's default; the box mode draws a box per block and needs no mask).


## 17. `ParagraphGrouper.maxGap` 0.6, measured (round read117, 2026-10-22; no change)

**Question.** A display that lies 0.60 to 0.63 line heights from the line above flips between "one paragraph" and "two blocks" from capture to capture. Does a different limit separate the lines of a paragraph from lines of separate blocks?

**Measured** (`tools/paper-bench/gap-census.py`: the gap from a line to the nearest line below it in its column, in heights, with the grouper's own tests for height ratio and alignment; a list marker is not tested here):

| gap | paper bench: same block / different blocks (the document reader's own blocks, 13 pages) | use-case bench: same unit / different units (the expected units of the 40 pictures, `auto` renders) |
|---|---|---|
| below 0.40 | 523 / 295 | 39 / 44 |
| 0.40 to 0.50 | 4 / 21 | 3 / 11 |
| 0.50 to 0.60 | 0 / 8 | 2 / 13 |
| 0.60 to 0.65 | 1 / 9 | 0 / 4 |
| 0.65 to 0.70 | 0 / 13 | 1 / 5 |
| 0.70 and more (below 1.5) | 3 / 103 | 0 / 77 |
| largest same gap | 1.38 | 0.67 |

**Reading.** No limit separates them: the gaps of two blocks lie at every value from -0.3 up (tables, lists and navigation rows stand close; the grouper keeps them apart by its other rows, a list marker above all), so the gap alone is a weak test and the limit only decides the band between 0.4 and 0.7. In that band the lines of one paragraph are rare: 11 of 95 pairs on the two benches, 4 of them in 0.50 to 0.70. The bin that holds the flip zone (0.60 to 0.65) has 1 pair of one paragraph and 13 of two blocks. A limit of 0.5 would lose 2 pairs of the 45 of the use-case bench (0.50 to 0.60) and none of the paper reader's 531, and would keep 21 pairs of two blocks apart that 0.6 lets through where the other rows pass. That is a direction, not a result: the number that decides is the use-case bench's `merged` and `split` of the `vn` path at 0.5 (a run with the limit as a parameter). It is not run here, and the default path reads documents with the document reader, whose grouping the grouper does not decide.
