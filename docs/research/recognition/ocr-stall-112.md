== /Users/hckim/.claude/projects/-Users-hckim-repo-mwoyeo/ff63668f-512b-4dfe-84da-f8969db15ac2/subagents/agent-aocr-stall-112-5f62144d7b8d2537.jsonl ==
## ocr-stall-112 보고

**공백 두 구간의 원인은 ANE 컴파일입니다. 1.1.1 대비 회귀가 아니고, 공개 릴리스 v1.1.0 대비로는 새로 생긴 위험입니다.**
- 스펙이 요구한 `/tmp/ocr-stall/report.md`는 쓰지 못했습니다. 하네스가 report 파일 쓰기를 거부해서, 전체 내용을 이 메시지에 담았습니다.
- 증거 파일(로그, 스크립트, probe)은 `/tmp/ocr-stall/r112/`에 있습니다. 저장소는 변경하지 않았고 `git status`는 기존 `__pycache__`만 보입니다.
- 실행 모델: Sonnet 5.5 (`claude-sonnet-5-5`).

### 원인
- **컴파일 로그**: lens가 figure 쪽을 처음 읽는 순간 `RecognizeDocumentsRequest`가 캐시에 없는 ANE 네트워크 두 개를 컴파일했습니다. 컴파일 구간은 17:14:17.9–17:14:52.2(34.3 s)와 17:15:34.3–17:16:00.2(25.9 s)입니다. 사용자 로그(`gui-proc.log`)와 시스템 로그(`ane-svc.log`)가 같은 구간을 가리킵니다.
- **앱의 ANE 사용**: 컴파일 중 앱의 ANE open/map은 0이었습니다.
- **타임아웃 로그**: 17:14:22(문서 8 s), 17:14:30(rev3 8 s), 17:14:38(rev2 8 s, "fast OCR failed")과 17:15:39(문서 8 s), 17:15:47(rev3 8 s)이 모두 이 구간 안입니다.
- **컴파일 직후**: 컴파일이 끝나자 적체된 요청 37개(VN)와 8개(문서)가 38 s 동안 몰려서 처리됐습니다. 이때의 125 % CPU와 `TextEraser.fill`(샘플 244개, 코어의 8 %)은 이 적체 처리입니다.
- **같은 프로세스의 모든 VN 요청이 막힙니다**: `docprobe mixvn`에서 rev3, rev2, `.fast` 모두 컴파일 동안 33.9 s와 27.0 s씩 막혔습니다. 컴파일이 끝나면 0.3 s로 돌아왔습니다.
- **다른 프로세스는 막히지 않습니다**: GUI 로그에서 자식 프로세스(pid 39128)가 컴파일 한가운데에서 0.6 s에 로드를 끝냈습니다.
- **기존 노트와 어긋납니다**: rev2/`.fast`는 막히지 않는다는 `SwiftVisionGate.swift:6-8`, `TextRecognizer.swift:302-304`, memory `ane-ocr-stall`의 설명은 이 컴파일에는 틀렸습니다.

### 오늘 이 Mac에서 터진 이유
- `~/Library/Caches/dev.midagedev.mwoyeo/com.apple.e5rt.e5bundlecache/26A428`의 두 엔트리(`16968053`, `4FE2FC5F`)에 중단된 `.tmp` 컴파일이 14개와 35개 남아 있었습니다.
- 그중 45개는 paper-bench 렌더 시각(렌더 시작 2–24 s 뒤)과 일치합니다.
- 렌더는 10–20 s에 끝나는데 컴파일은 27–36 s가 필요합니다. 클라이언트가 끝나면 컴파일이 처음부터 다시 시작되므로, 하루 종일 캐시가 완성되지 못했습니다.
- GUI가 처음으로 끝까지 살아 있던 프로세스였고, 두 엔트리는 17:14:52와 17:16:00에 완성됐습니다. 이 Mac에서는 이제 재발하지 않습니다.

### 증명한 측정
| 실험 | 결과 |
|---|---|
| 새 bundle id, warm-up 끝난 RC, p13 렌더(`auto`) | 컴파일 35.8 s + 26.9 s, `ocr.swift.missed=1`, pipeline 9560 ms |
| 같은 조건, 1.1.1 빌드 | 35.3 s + 27.1 s, pipeline 9592 ms |
| 같은 조건, 산문 쪽 p7 | 컴파일 0, pipeline 3.7 s |
| 같은 조건, VN만 읽는 경로(v1.1.0 방식) p13 | 1.5 s, 캐시 엔트리 증가 없음 |
| 동일 렌더 ANE open/map (1.1.1 대 RC) | en 16/36 대 16/36, auto 18/37 대 18/37 |

- **Q1 (open/map 비율)**: 새 비율이 아닙니다. VN 요청 하나는 프로세스에서 첫 번째가 4 open(map 3), 이후는 1 open입니다. 사용자가 본 9분간 243 open은 쪽 렌더 약 15번 분량입니다.
- **문서 경로의 출처**: 문서 경로(`0d348da`, 10-18 08:37)는 마지막 태그 v1.1.0(10-17 19:52) 이후에 들어왔습니다. 그래서 공개 사용자에게는 새 위험입니다.
- **트리거 내용 (미확정)**: 확정하지 못했습니다.
  - 1634×1000 합성 그림(표, 목록, 회전 단어, 도식, 2단)은 모두 컴파일을 일으키지 않았습니다.
  - p13 crop(1100×600 이하)도 일으키지 않았습니다.
  - 같은 figure를 1634×2114 캔버스에 붙이자 약 27 s 컴파일이 한 번 생겼습니다.
  - `barcodeDetectionOptions.enabled=false`도 소용없었습니다(p13 문서 요청 67 s, 컴파일 2개 그대로).
  - 그림 크기와 내용이 같이 작용하는 것으로 보이며, 작은 합성 그림으로 warm-up을 대신하기는 어렵습니다.

### Q3 (1.1.2에서 ANE/Vision 큐를 더 오래 잡는 것이 있는가)
- **Inpainter**: ANE를 쓰지 않습니다. fill 3회와 load 1회가 있어도 ANE open이 켬/끔 모두 16으로 같습니다.
- **CaptureRecovery**: 재시작이 없었습니다. lens 시작이 한 번이고 `stream stopped` 로그도 없습니다.
- **ReadingGate**: 로그로 확인할 수 없습니다. 6분간 `updateConfiguration` 38회의 상한만 보입니다.
- **TextErase.frames**: 쪽당 비용 차이가 없습니다. 18블록 erase가 284 ms에서 293 ms로 +3 %입니다.

### 고칠 곳 (단일 owner 기준)
1. **UX 신호** — `TextRecognizer.swift:129-133`, `:166-170`의 문서 `Timeout`에서 `raise(preparing(languages))`를 부르고, 성공 경로(`:128`, `:163`)에서 `raise(nil)`을 부릅니다. 약 6줄이며 기존 문구와 `LensHint.preparingRecognition`을 그대로 씁니다.
2. **`SwiftVisionGate.swift` `missed(_:)`** — 두 번째 miss가 `.failed`로 가서 relaunch나 retry까지 문서 경로가 꺼집니다. 로그상 miss가 17:14:22와 17:15:39로 두 번이고 이후 자식 프로세스가 없었으므로, 사용자의 실행 중 RC는 `documentModel=failed` 상태일 가능성이 큽니다(앱은 건드리지 않았습니다). 늦게 끝난 abandoned 요청이 `gate`를 복구하게 하면 되고, 약 8줄입니다.
3. **in-process VN 차단** — 문서 요청이 미해결인 동안 in-process VN을 시작하지 않습니다(어차피 막힙니다). `TextRecognizer.swift:178-182`와 `accurate`(`:293`)에서 바로 `Stalled`를 던지면 약 15줄입니다.
4. **즉시 재시도** — `RegionPipeline.swift:793-799`에서 `Timeout`이 `noteReadFailure`를 거치지 않아 backoff 없이 곧바로 재시도합니다. 약 2줄입니다.
5. **예방** — 문서 `documentModel` step(`TextRecognizer.swift:437-446`)이 쓰는 그림에 쪽 크기의 figure를 넣어 자식 프로세스에서 미리 컴파일시키는 방법입니다. 위 트리거 미확정 때문에 별도 라운드로 검증해야 합니다.

### 1.1.2 대기 여부
공개 사용자는 OS 빌드당 Mac마다 컨텐츠 종류별로 한 번, 63 s 이상 신호 없는 공백을 겪습니다. 이후 문서 경로가 꺼진 채로 남을 수 있습니다. 문서 경로를 그대로 싣지 않는 편이 낫고, 선택지는 둘입니다.
- **(a)** 1번과 2번만 넣어 출하하기. 두 편집 합쳐 약 15줄이고 다음 1라운드면 됩니다.
- **(b)** 1.1.2는 VN+grouper 경로(v1.1.0 동작)로 두기. p13이 1.5 s에 읽혔습니다.

### 종이 분해와 자원 타임라인
- **분해**: 예측 105 s는 3.3(컴파일 시작까지) + 34.3 + 38.8(적체) + 2.8 + 25.9이고, 실측은 106 s였습니다. 박스 실행이 필요했던 항은 "warm-up 뒤에도 figure 쪽이 컴파일을 일으키는가"뿐이며, 예측대로 일으켰습니다.
- **타임라인**: 쪽당 호스트 CPU는 약 0.4 s(RGBA 변환 0.1 s + erase 0.29 s)입니다. ANE는 컴파일 구간에 0이고, ANECompilerService는 34.3 s + 25.9 s로 직렬입니다. PCIe와 NVMe는 해당 없습니다. 벽시계는 합입니다(같은 프로세스 전체가 막혀 max가 아닙니다).
- **흐름 레버**: 유일하게 의미 있는 것은 비동기(컴파일 밑에서 다른 프로세스가 읽기)입니다.

### 세 겹 노트
- **구조 owner**: `TextRecognizer`의 문서 경로와 gate입니다.
- **수치 gate**: `docprobe mixvn`을 FAIL-first로 승격하는 안입니다(VN 요청이 컴파일 시간만큼 막히는지 측정).
- **디버깅**: `ocr.swift.missed`와 `lens.resumed.occluded`는 Trace 카운터로만 있고 unified log에 남지 않습니다.

### 스펙 밖 개선 후보 (보고만, 손대지 않음)
- `tools/paper-bench/run.sh:21` — 렌더가 컴파일 중에 끝나 중단 시도를 남기고 게이트 측정을 오염시킵니다. 새 id마다 `--then wait60000` 한 번을 넣으면 됩니다(약 2줄).
- `SwiftVisionGate.swift:6-8`, `TextRecognizer.swift:302-304`, `tools/ocr-probe/README.md`, memory `ane-ocr-stall` — "rev2/fast는 컴파일 중에도 답한다"는 설명을 정정합니다(약 4줄).
- `RegionSession.swift:845`, `TextRecognizer.swift:130` — `log.notice` 한 줄씩이면 다음 사고가 로그로 읽힙니다(약 4줄).
- Vision 자식 프로세스가 17:14:22에 `(Metal) mdb_txn_commit error: MDB_MAP_FULL`을 냈습니다. `com.apple.metal` 캐시가 가득 찬 것일 수 있어 조사가 필요합니다(코드 변경 없음).

DONE-ocr-stall-112
