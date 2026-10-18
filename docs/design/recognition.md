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
  - the "Language reader" step title;
  - the stale notes listed in G25 (the memory note ane-ocr-stall is the lead's).

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
