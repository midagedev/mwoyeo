== /Users/hckim/.claude/projects/-Users-hckim-repo-mwoyeo/ff63668f-512b-4dfe-84da-f8969db15ac2/subagents/agent-aflow-contention-77c7669ec579550f.jsonl ==
## 요약 (15줄)

1. **1위, 1.1.2 차단.** 한 프로세스 안의 Vision/e5rt 직렬화입니다. 처음 보는 입력 shape의 ANE 컴파일 중에는 그 프로세스의 모든 VN·Swift 요청이 막힙니다.
   - 제 Release 빌드에서 재현했습니다. 같은 이미지를 처음 스크롤한 run(m2a)이 35.9 s 동안 렌즈가 비었고(`lens at end: 0 blocks`, `settled at end: 35909 ms`), ANECompilerService CPU 시간이 +35.5 s 늘었습니다. 같은 페이지를 다시 돌린 run(m2b)은 +0.01 s였습니다.
   - 한 패스가 `fast: OCR failed Timeout() 32373 ms`로 끝났습니다. rung마다 8 s deadline을 쓰고 8 s 안에도 응답이 없는 요청은 계속 막혀 있습니다.
   - Timeout 뒤에는 backoff 없이 바로 재시도합니다(`RegionPipeline.swift:798`, `:873`).
   - 고칠 곳은 `TextRecognizer.swift:101-183`, `:293-336`입니다. 싼 완화책은 약 40줄입니다. 구조 해법은 `SwiftVisionChild.swift`에 `RecognizeDocumentsRequest`를 상주 child로 옮기는 것으로 약 300줄입니다.
2. **2위, 1.1.2에 싸게 넣을 것.** transient e5rt 실패의 backoff가 1 s 고정이라 스스로 ANE를 두드립니다(`RetryBackoff.swift:104-107`).
   - RC 프로세스 pid 11524가 15:49-16:21에 분당 56건씩 32분간 실패를 냈습니다. 로그로 센 합계는 약 1,800건입니다.
   - 1, 2, 4 … 30 s로 늘리고 힌트를 띄우면 됩니다. 약 10줄과 단위 테스트입니다.
3. **3위, 차단 아님.** translationd는 직렬 서버입니다. 두 배치를 동시에 넣으면 각각 1.74배 걸리고, 취소해도 풀리지 않습니다(+123 ms).
   - 처리량은 약 12줄/s이고 모든 렌즈가 나눠 씁니다. 고칠 곳은 `RegionPipeline.swift:1340-1377`(취소 조건)과 `TranslationService.swift:303`이며 작은 변경입니다.
4. **4위, 낮음.** adaptive 모드가 정지 화면을 두 번 읽습니다(m2c: 352 ms, 527 ms). 약 15줄로 고칠 수 있습니다.
5. **5위, 낮음.** 파이프라인 actor의 동기 CPU(erase 등)는 스크롤에서 패스 시간의 10 %이고 frame이 actor를 기다리는 시간은 4 ms 이하입니다. 밀집 논문 페이지의 seamless 패스는 0.3-0.4 s입니다.
6. **사용자 가설 반증.** OCR(ANE)과 번역(translationd, CPU)은 하드웨어를 나누지 않습니다. 동시 실행 시 번역 1.02배, OCR 1.04배이고, 67 s 컴파일 중 번역 269회의 중앙값은 247 ms였습니다(번역 단독 246 ms).
7. **기각 항목:** session 재생성 +1 ms, MI-GAN 12-13 ms/tile, 스레드풀 고갈(`kern.wq_max_constrained_threads=64`, 스레드 수는 미측정), 메인스레드 CGWindowList 중앙값 1 ms 미만(최대 9 ms).
8. 1.1.2 차단은 1위와 2위입니다. 1위는 최소한 완화책으로 넣어야 합니다.
9. 측정은 Release로 했습니다. Debug는 erase가 약 14배 느려서 actor 차단 수치가 왜곡됩니다(p7: Debug 4203 ms/8블록, Release 293 ms/18블록).
10. 하네스 `--mode`에 adaptive가 없어서 scratch 복사본에만 한 줄 패치했습니다(`SelfTest.swift:133`). repo는 건드리지 않았습니다.
11. 예측과 실측 대조표는 `/tmp/flow-contention/predictions.md`에 있고 아래에도 있습니다. 틀린 예측은 M2의 actor 점유율과 RGBA 비용입니다.
12. 모델: Sonnet 5.5 (`claude-sonnet-5-5`).

DONE-flow-contention

---

## 상세 노트

### 1. 자원 타임라인 (단위 작업별)

**정지 페이지 한 번 읽기** (Release RC, `/tmp/ocr-stall/r112/q1/rc-p7-en.err`, 1634×2114 px)

| 자원 | 바쁜 시간 | 근거 |
|---|---|---|
| ANE | 0.72 s | VN rev3 0.39 s + 문서 읽기 약 0.33 s |
| 호스트 CPU (RegionPipeline actor, 동기) | 약 0.4 s | erase 293 ms/18블록(블록당 약 16 ms) + RGBA 100 ms |
| translationd (CPU 1코어, 직렬) | 1.76 s | 3줄 배치 6개: 587, 317, 71, 318, 331, 137 ms |
| GPU, PCIe, NVMe | 0 | flat 배경은 MI-GAN을 쓰지 않음 |

- 전체 시간은 단일 자원의 최댓값이 아니라 합(약 2.9 s)입니다. OCR → erase → 번역이 데이터 의존으로 이어집니다.
- RGBA 100 ms는 PNG 디코딩 비용입니다. 실제 BGRA 프레임 변환은 훨씬 쌉니다(아래 conv 실측: 8.3 MP에서 8 ms).
- 여기서 쓸 수 있는 flow 레버는 erase를 첫 번역 배치 뒤로 겹치는 것뿐이고, 최대 0.4 s(13 %)입니다.
- 배치를 병렬로 돌려도 이득이 없습니다(C2가 직렬임을 보였습니다).

**adaptive 정지 화면** (m2c, chat.png)
- 전체 2047 ms입니다. fast 패스 OCR 352 ms, 이어서 settle 뒤 seamless 문서 OCR 527 ms, erase 31 ms, 번역 9배치 971 ms가 번역과 겹쳐 돕니다.
- ANE가 같은 화면을 두 번 읽습니다(합 0.88 s).

**스크롤** (m2b, forum-tall, 400 ms/step, Release)
- fast 패스 34회. 패스 전체 중앙값은 155 ms이고 그중 OCR 대기가 136 ms입니다.
- erase 합계는 570 ms/34패스(패스당 평균 17 ms)입니다.
- actor 동기 비중은 10 %입니다. 한 번 읽는 데 번역 배치 중앙값은 38 ms입니다.
- 이 스크롤에서는 OCR 체인이 한계입니다. 밀집 텍스트에서는 translationd가 한계입니다(줄당 약 80 ms 직렬).

**캡처 큐** (conv 마이크로벤치, 로드 평균 18 상태에서 측정)

| 프레임 | 복사 | gray 스캔 | BGRA→RGBA |
|---|---|---|---|
| 8.3 MP (3280×2520) | 1.1 ms | 6.7 ms | 8.0 ms |
| 14.7 MP | 1.8 ms | 11.3 ms | 17.2 ms |

- 8 fps에서 캡처 큐 부하는 코어 하나의 약 6 %입니다.

### 2. 공유 지점과 판정

| 지점 | executor / 대기 | 판정 |
|---|---|---|
| Vision/e5rt 프로세스 내 직렬화 + ANECompilerService (시스템 전체 직렬 컴파일 서비스) | 모든 `VNImageRequestHandler.perform`과 Swift 요청이 같은 프로세스 안에서 대기 | **1위.** 재현됨 |
| deadline 래더 `TextRecognizer.accurate` | rung별 8 s를 직렬로 쓰고, 막혀 있으면 전부 같이 막힘 | 1위의 증폭기 |
| 패스 루프 `RegionPipeline.run` | Timeout 후 backoff 없이 즉시 재시도(`:798`, `:873`). 포기한 요청은 취소되지 않음 | 스레드와 요청 누적 가능. 스레드 수는 미측정 |
| `ReadBackoff` transient | 1 s 고정 | 2위. 실 사용자 로그에 32분 루프가 있음 |
| `TranslationService` actor와 translationd | actor는 재진입 가능, translationd는 직렬 | 3위 |
| RegionPipeline actor 동기 구간 | erase(`:1140`), RGBA(`:896`, `:813`), `renderMissing`이 await 없이 실행 | 낮음 |
| MI-GAN `Inpainter` | `lock`을 prediction 동안 보유. 렌즈 간 직렬화는 타일당 12-13 ms 수준 | 무시 가능 |
| 메인스레드 | `trackWindow` 5 Hz에 CGWindowList 두 번, 스냅샷 적용, display link | 측정상 무시 가능 |
| 캡처→ingest `RegionSession.swift:126` | 프레임당 `Task { await pipeline.ingest }`로 unbounded | actor가 1초 이상 막혀야 문제(프레임당 33 MB). Release에서는 안 막힘 |
| translationd와 ANE | translationd는 Espresso offline engine(`com.apple.espresso`)이고 ANE/e5rt 로그가 없음 | 하드웨어 공유 없음 |
| 고충실도 번역(Apple Intelligence)·Foundation Models | ANE/GPU를 쓸 가능성이 높음 | **미측정.** 이 Mac은 `Observer not eligible for LLM translation` |

### 3. 측정 (예측 → 실측)

기준 상태: M1 Pro 10코어, 로드 9-18(다른 라운드 동시 작업). 사실상 자연 부하입니다.

| 항 | 예측 | 실측 | 판정 |
|---|---|---|---|
| T0 번역 3줄 배치 단독 | 330 ms (220-650) | 중앙 246, p90 298, 첫 결과 87 ms | 범위 안 |
| O0 VN rev3 p7 전체 | 380 ms | 339 ms (p90 384) | 범위 안 |
| X1 번역/T0, OCR/O0 | 1.10, 1.10 | 250/246 = 1.02, 352/339 = 1.04 | 범위 안 |
| cold 중 번역 | 1.0배 | 컴파일 67.5 s 동안 269배치, 중앙 247, 최대 420 ms | 일치 |
| translationd CPU/배치 | 0.25 s | 0.23-0.24 s (64.6 s/269) | 일치 |
| GPU 사용률 | 기준선 +10포인트 이내 | 기준선 수준 (평균 약 9 %) | 일치 |
| C2 동시 2배치 | 각 1.8배 | 같은 session 454 ms = 1.74배, 두 session 456 ms = 1.75배 | 일치(직렬) |
| K 취소 직후 다음 배치 | +200 ms (0-500) | 354 vs 231 = +123 ms, fresh session 366 | 범위 안 |
| S fresh session | +40 ms (0-250) | 86 vs 85 ms = +1 ms | 범위 안, 도출치 틀림(생성 비용 0) |
| M2 actor 동기 비중 | 35 % (20-55) | 10 % (m2b), frame 대기 중앙 2 ms/최대 4 ms | **틀림**: 범위 아래 |
| M2 RGBA | 58 ms | 하네스 0-1 ms | **틀림**: 하네스는 RGBA 네이티브 프레임. 실제 BGRA는 8 ms@8.3 MP |
| M4 CGWindowList | id 0.4, above 2, onScreen 3 ms | 중앙 1 ms 미만, id p90 4 ms, 최대 8-9 ms (창 31개) | 낮음 |

- 사전 예측에서 못 도출한 항은 translationd 직렬성 하나였고, C2가 닫았습니다.
- 계획에 없던 m2a 정지 재현은 실측 전에 예측하지 못한 결과입니다.
- 번역 줄당 비용은 약 80 ms(3줄 246 ms, 첫 결과 87 ms)입니다. 배치 고정 비용이 없어서 배치 크기는 처리량과 무관합니다.

### 4. 고칠 곳 (single owner)

- **R1 완화 (약 40줄):** `TextRecognizer`에 '포기됐지만 완료되지 않은 요청이 있고 60 s가 안 지남' 상태를 둡니다.
  - 이 상태면 `accurate`의 나머지 rung을 건너뛰고 "preparing" 힌트를 내며, 그 요청의 완료를 한 번만 기다립니다.
  - 이렇게 하면 rung마다 8 s를 쓰는 일과 즉시 재시도 루프가 사라집니다.
  - Timeout 경로는 `RegionPipeline.swift:798`, `:873`에서 backoff를 소비합니다.
- **R1 구조 (약 300줄):** `Swift RecognizeDocumentsRequest`를 `--warm-vision` child를 상주 worker로 확장해 항상 child에서 읽습니다.
  - 컴파일은 child에서만 막히고 앱 프로세스의 VN은 계속 0.3 s로 읽습니다.
  - `lineGrouping`(`ParagraphGrouper`) 경로로 렌즈가 살아 있다가 문서 레이아웃으로 올라갑니다.
- **R2 (약 10줄):** `ReadBackoff.failure(transient:)`가 transient 연속 실패 수에 따라 1, 2, 4 … 30 s로 늘리게 합니다.
- **3층 노트 (R1, R2 공통):**
  - 구조적 owner는 TextRecognizer와 ReadBackoff입니다.
  - 수치 게이트는 Core에 FAIL-first 순수 테스트(abandoned in flight이면 plan이 `.run`이 아님, transient 연속 N회 후 wait ≥ N s)를 둡니다.
  - 디버그 노출은 `ocr.abandoned_inflight` 카운터와 `stats()`입니다.
  - 재현 레시피(새 shape 페이지 첫 스크롤 + ANECompilerService CPU 델타)는 `tools/ocr-probe`로 올릴 만합니다.
- **R3 (작음):** 취소는 남은 시간이 새 배치 대기보다 짧을 때만 합니다. 이 Mac의 Apple 엔진에서는 stale 꼬리가 0.25 s 이하라 아직 급하지 않습니다. 고충실도 엔진은 줄당 약 1 s로 알려져 있어 꼬리가 몇 초 갈 수 있는데, 이는 미측정입니다.

### 5. 실행한 검증 명령 (실제 출력)

- `xprobe cold`: `cold: VN rev3 first read in this process took 67453 ms; translation during it: n=269 med=247 p90=297 min=194 max=420 ms` / `translationd cputime before=49:04.03 after=50:08.62`
- `xprobe t0`: `T0 alone: total n=20 med=246 p90=298 ... | first n=20 med=87 ...`
- `xprobe o0`: `O0 alone: n=20 med=339 p90=384 min=326 max=392 ms`
- `xprobe x1`:
  - `X1 translation while OCR loops: total n=20 med=250 ... wall 4838 ms`
  - `X1 OCR while translation loops: n=14 med=352 p90=365`
- `xprobe c2`:
  - `C2 one batch: med=261`
  - `C2 two at once, same session: n=20 med=454`
  - `C2 two at once, two sessions: n=20 med=456`
- `xprobe k`:
  - `K B alone, reused session: med=231`
  - `K B alone, fresh session each: med=239`
  - `K ... after cancelling A, same session: med=354`
  - `K ... after cancelling A, fresh session: med=366`
- `xprobe s`: reused 85, fresh 86 ms.
- `xprobe win`: `on-screen windows listed=31`, id/above/onScreen의 중앙값은 모두 1 ms 미만, 최대 8-9 ms.
- m2a: `fast: OCR failed Timeout() 32373 ms`, `seamless: document OCR timed out, reading lines 8129 ms`, `settled at end: 35909 ms`, `ocr.stalled.vn3=1`, ANECompilerService cputime `400:11.07 → 400:46.58`.
- m2b: `settled at end: 0 ms`, ANECompilerService `400:46.58 → 400:46.59`, 요약은 `/tmp/flow-contention/m2parse.py` 출력(sync 비중 10 %, frame age 중앙 2 ms/최대 4 ms).
- m2c: `pipeline: 2047 ms`, `fast: OCR 352`, `seamless: document OCR 527`, `translate batch wall n=9 sum=971 ms`.
- 정지 후 `git status --short`: `?? tools/paper-bench/__pycache__/`만 남았고(스냅샷 때부터 있던 것), HEAD는 `feb7a12`입니다.

### 6. 설명 보강 (R2 로그 증거)

- 로그 소스는 `/private/tmp/mwoyeo-rc/dd/.../Mwoyeo` RC 프로세스(pid 11524)입니다. 요청 후 12 ms 만에 `e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed (Code: 13)`이 반복되고, 주기는 약 1.07 s입니다.
- 같은 시간대 ANECompilerService 로그는 분당 0-119줄뿐이라 다른 프로세스의 컴파일 때문이 아닙니다. 프로세스 자체 상태입니다.
- 로그 시각만 보면 이 32분 내내 렌즈가 비었을 것입니다. 사용자 화면은 확인하지 못했습니다.

### 7. 범위 밖 개선 지점 (보고만)

- `App/Support/SelfTest.swift:133`: `--mode adaptive`가 없어 기본 모드를 하네스로 못 돌립니다. 한 줄입니다.
- `App/Pipeline/RegionPipeline.swift:486-489`, `:480-484`: adaptive가 정지 후 fast 패스가 읽은 화면을 seamless로 한 번 더 읽습니다. ANE 약 0.5 s/settle이며 약 15줄입니다.
- `App/Model/AppModel.swift:176`: `await translator.prewarm()`이 `warmUpVision`과 세션 시작 전에 직렬로 최대 7 s 걸립니다. 작은 변경입니다.
- `App/UI/MenuPanel.swift:101`: `.id(model.sessionTick)`이 메뉴가 열려 있을 때 OCR 패스 경계마다 패널 전체를 다시 만듭니다. 작은 변경입니다.
- `App/Overlay/OverlayPanel.swift:153`: 디스플레이 크기 레이어에 mask가 걸려 있어 WindowServer가 오프스크린 패스를 돌 수 있습니다. 미측정이며, `ioreg -r -d 1 -w0 -c AGXAccelerator`의 Device Utilization을 스크롤 중 샘플하면 root 없이 확인할 수 있습니다.
- `xprobe.swift`와 `conv.swift`를 `tools/ocr-probe`로 올리면 같은 측정을 반복할 수 있습니다(약 150줄).
- 머신 상태 메모: ANECompilerService(pid 29145)는 32 h 동안 CPU 6.5 h를 썼습니다. 다른 라운드의 cold render가 겹치면 1위가 사용자 몫으로 번질 수 있습니다.

### 8. 파일

- 예측: `/tmp/flow-contention/predictions.md`
- 실측 원본: `/tmp/flow-contention/out/*.out`, `*.err`
- 러너: `/tmp/flow-contention/run-stage.sh`
- 트레이스 요약: `/tmp/flow-contention/m2parse.py`
- 프로브 소스: `/tmp/flow-contention/probe/xprobe.swift`, `/tmp/flow-contention/probe/conv.swift`
- 빌드: `/tmp/flow-contention/dd/Build/Products/Release/Mwoyeo.app`. scratch 복사본 `/tmp/flow-contention/src`에는 하네스 `--mode adaptive`와 fastPass 마크 2개만 패치했습니다.
- 앱 로그 발췌: `/tmp/flow-contention/applog.txt`
- 디스크는 25.6 GiB 여유입니다. 지운 것은 없습니다.

DONE-flow-contention
