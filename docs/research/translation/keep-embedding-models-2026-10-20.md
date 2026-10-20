# Can a small embedding model judge the keep boundary? (round emb-research, 2026-10-20, Korean)

Report kept as written by the round (Sonnet 5.5). Sources are marked F (fetched), S (search summary), E (estimate). Measurements on this Mac: tools/keep-labels/mbench (round m-bench).

# emb-research 보고서 (Sonnet 5.5, 2026-10-20)

하네스가 보고서 파일 쓰기를 거부해서 spec의 대체 규칙대로 전체를 이 메시지에 넣었다. 표기는 F = 가져와서 읽음, S = 검색 요약만, E = 내 추정(측정 아님)이다. 가중치는 받지 않았고, 빌드와 repo 수정, git 상태 변경도 없다. 이 Mac은 M1 Pro(8P+2E)이고 `sysctl`로 FEAT_SME, FEAT_I8MM, FEAT_BF16이 모두 0임을 확인했다. 아래 M5 수치는 이 칩보다 빠르다.

## 0. 결론

- **ack A-EG2: done.** 후보는 EmbeddingGemma 2(`google/embeddinggemma-2`)이고, v1은 부가 행으로만 다뤘다.
- **라이선스는 v2에서 풀린다.** v2는 Apache-2.0이다(카드 `license: apache-2.0`, F). v1은 Gemma Terms of Use라서 앱 EULA에 사용 제한을 넣어야 하고, 증류한 학생 모델도 그 약관을 상속한다.
- **크기와 속도는 "가볍다"가 아니다.** 텍스트 전용은 270M이고 공식 int4 QAT 파일이 165 MB다.
  - 공식 카드의 M5 CPU 수치는 128토큰에 31.3 ms다(F).
  - M1 Pro에는 SME가 없어서 80~210 ms / 128토큰으로 본다(E).
  - keep-boundary §5 예산(블록당 p95 ≤ 1 ms, 가중치 ≤ 5 MB)을 속도로는 20~200배, 크기로는 30~60배 넘는다.
- **탑재 가능하지만 용도가 좁다.** 라이브 렌즈의 블록 단위 판정에는 맞지 않는다.
  - 논문 경로에서 불확실 구간에만 돌리고 텍스트 해시로 캐시하는 쓰임이 맞다.
  - 오프라인 teacher/labeler로는 가치가 있다. Apache-2.0이라 출력과 증류가 자유롭다.
- **적합성 문제가 더 크다.** 풀링 임베딩은 블록당 벡터 하나라서 단어 라벨을 주지 못한다.
  - 규칙이 이미 가까운 구간(code/log/config의 지역 누락)은 규칙 수정(S~M)으로 닫힌다.
  - 모델이 꼭 필요한 구간은 문장 속 id/path/cmd/config(인라인 recall 0.11)이고, 단어 단위 출력이 있어야 닿는다(RESULTS-h2-2026-10-20.txt 결론 3-4, F).
- **Swift 경로는 llama.cpp C 라이브러리(CPU 전용) 1순위, MLX-Swift 2순위, Core ML은 피한다.**
- **m-bench 후보(측정 순서)**
  1. EmbeddingGemma 2 text-only
  2. multilingual-e5-small
  3. potion-multilingual-128M
  - 대조군은 후보 수에 넣지 않는다: 우리 라벨로 학습한 hashed char n-gram 선형 모델.

## 1. EmbeddingGemma

### 1a. EmbeddingGemma 2 (주 후보)

| 항목 | 내용 |
|---|---|
| 배포 | `google/embeddinggemma-2`, 2026-10-06, 게이트 없음(HF API `gated: False`, F) |
| 라이선스 | 카드 front-matter `license: apache-2.0`. 본문의 "License: Apache 2.0"이 ai.google.dev/gemma/docs/gemma_4_license로 링크되고, 그 페이지 본문이 "Apache License Version 2.0, January 2004"(F). 별도 prohibited-use 조항은 본문에 없다 |
| 크기 | 총 740M = 텍스트 270M(backbone 130M + embedder 140M) + 비전 170M + 오디오 300M(F) |
| 구조 | 24층, d_model 512, hidden 2048, 4 heads, 슬라이딩 윈도 1024, vocab 262,144, mean pooling, 투영 512→768(F) |
| 차원 | 768, Matryoshka 512/256/128(잘라서 재정규화, F) |
| 컨텍스트 | 8192 토큰(v1은 2048, F) |
| 언어 | "100+ languages", 학습 데이터 "over 140 languages"(F). ko/ja/zh별 점수는 카드에 없다 |
| 품질 | MTEB multilingual v2 평균 61.36(v1 61.15), code 78.68(v1 68.76)(F) |
| 분류용 접두 | `task: classification \| query: {content}`(F) |

**텍스트 전용 로드: 무엇이 되는지 (직접 로드해 본 것은 아니다)**
- 공식 방법은 sentence-transformers의 `config_kwargs={"vision_config": None, "audio_config": None}`다. 가이드는 "Disabled encoders are never loaded into memory"라고 한다(F).
- MLX-Swift는 `EmbeddingGemma2Configuration.selectingEncoders(vision: false, audio: false)`로 된다(F: `Libraries/MLXLMCommon/Models/EmbeddingGemma2.swift:277`).
- GGUF은 텍스트(`embeddinggemma-2-Q8_0.gguf`)와 `mmproj-*`가 별 파일이다(F).
- ONNX는 `model*.onnx`와 `vision_encoder*`/`audio_encoder*`가 별 파일이다(F).
- mlx-community 4bit/8bit 저장소는 740M 전체(1.10/1.23 GB)를 담고 있다(F).

**텍스트 전용 크기** (모두 HF API, F)

| 출처 | 파일 | 크기 | 비고 |
|---|---|---|---|
| litert-community | `embeddinggemma-2-text-270m.litertlm` | 164.6 MB | int4 per-channel QAT, Apache-2.0 |
| ggml-org | `embeddinggemma-2-Q8_0.gguf` | 309.9 MB | BF16 558 MB |
| onnx-community | `model_q4.onnx_data` | 174.0 MB | q4f16 156.9, int8 313.7, fp16 542, fp32 1084 MB. `tokenizer.json` 32.2 MB 별도 |
| FluidInference(Core ML) | Text `weight.bin` fp16 | 276.8 MB | 토큰 테이블 `embeddings.bf16` 268 MB 별도, 합 약 545 MB |
| google 원본 | `model.safetensors` | 1.49 GB | 전 모달 bf16 |

- 공식 양자화 변종은 카드에 없다(addendum와 일치). 다만 위 litert-community 파일이 int4 QAT의 공식 크기를 보여 준다. 이 조직이 Google 소유인지는 확인하지 못했다. 카드는 Google의 LiteRT-LM을 안내한다.
- 어휘를 ko/ja/zh/en 주변 약 4만으로 줄이면 int4에서 약 75~90 MB가 될 수 있다(E). 임베더가 전체의 절반이라서다. 이 수정은 Apache-2.0 §4(b)의 수정 표시 대상이다(S, 일반 지식).

**공개된 CPU 지연** (F: litert-community/embeddinggemma-2-text-270m-litert-lm, 128토큰 시그니처, 5회 평균)

| 장치 | CPU ms | GPU ms | 피크 RAM CPU/GPU |
|---|---|---|---|
| MacBook Pro M5 | 31.3 | 9.5 | 165 / 233 MB |
| iPhone 18 Pro | 41.8 | 11.6 | 84 / 85 MB |
| S26 Ultra | 27.1 | 25.9 | 334 / 333 MB |
| Raspberry Pi 5 | 161 | - | 282 MB |

- 시그니처는 128/256/512/1024/2048/8192라서 짧은 블록도 최소 128으로 돈다.
- M1 Pro 값은 어디에도 없다(검색 확인, S).
- FluidInference의 ANE 수치(M5 Pro, 128토큰 5.6 ms)는 쓸 수 없는 경로다.

### 1b. EmbeddingGemma v1 (부가 행)

- `google/embeddinggemma-300m`: 308M(100M + 200M embedding), 768d, MRL 512/256/128, 2048 토큰, 100+ 언어, MTEB multi v2 61.15. 카드에 "EmbeddingGemma activations do not support float16"이 있다(F).
- 라이선스는 Gemma Terms of Use(`license: gemma`)다. 구글 원본 저장소는 수동 승인 게이트이고, ggml-org/onnx-community 미러는 게이트가 없지만 `license: gemma`를 단다(HF API, F).
- 크기: GGUF Q8_0 333.6 MB, qat-Q8_0 328.6 MB, qat-Q4_0 277.9 MB, ONNX q4 196.7 MB, q4f16 175.4 MB(F). 임베딩 테이블이 커서 Q4가 Q8보다 많이 작지 않다.
- 공개 CPU 지연: Samsung S25 Ultra CPU 66 ms / 256토큰, 초기화 17.6 ms, 179 MB(F). Google 블로그의 "<15ms (256 tokens) on EdgeTPU"(F)는 Apple CPU 값이 아니다.

**Gemma Terms of Use** (F: ai.google.dev/gemma/terms, "Last modified: April 1, 2026". 페이지에 "documentation is deprecated"와 "Gemma 4 terms는 별도 license" 안내가 있고, Appendix에 EmbeddingGemma가 나열된다)
- §3.1 "You must include the use restrictions referenced in Section 3.2 as an enforceable provision in any agreement (e.g., license agreement, terms of use, etc.) governing the use and/or distribution of Gemma or Model Derivatives"
- §3.1 "You must provide all third party recipients of Gemma or Model Derivatives a copy of this Agreement."
- §3.1 "All Distributions (other than through a Hosted Service) must be accompanied by a "Notice" text file that contains the following notice: "Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms"."
- §3.1 수정 파일에는 "prominent notices stating that you modified the files"를 붙여야 한다.
- §1.1(e)에서 Model Derivatives는 "modifications to Gemma", "works based on Gemma", 그리고 Gemma의 weights나 Output의 패턴을 옮겨 만든 모델("including distillation methods ... or methods based on the generation of synthetic data Outputs")이다. 따라서 양자화, 어휘 축소, Core ML 변환, 증류한 학생 모델 모두 같은 조건을 진다.
- §3.2 "Google reserves the right to restrict (remotely or otherwise) usage". §4.5 "Google may terminate this Agreement if you are in breach", 종료 시 모든 사본을 삭제하고 배포를 중단해야 한다.
- 앱스토어 조항은 없고, 상업 이용 제한도 없다(제한은 Prohibited Use Policy와 법령 위반뿐).
- MAS 영향: 첫 조건 때문에 Apple 표준 EULA만으로는 부족할 수 있다. App Store Connect는 사용자 지정 EULA를 지원한다("Apply a custom EULA to all chosen countries or regions", 플레인 텍스트, F). 길이 제한이나 Apple 약관과의 충돌 규칙은 그 페이지에 없었다. 심사에서 받아들이는지는 확인하지 못했다.
- v2(Apache-2.0)는 이 조건이 모두 필요 없다. LICENSE 사본, NOTICE 유지, 수정 표시 정도다(S).

## 2. macOS Swift 통합 경로 (EG2 text-only)

| 경로 | 성숙도 | 번들 비용 | 콜드 로드 | CPU 지연(공개) | ANE 회피 | 위험 |
|---|---|---|---|---|---|---|
| **llama.cpp C 라이브러리 + GGUF** (MIT, F) | `gemma-embedding2` 아키텍처가 PR #30054로 2026-10-06 머지(F). 최신 태그 b11748(2026-10-20). ggml-org 공식 GGUF | xcframework zip 66.9 MB는 전 플랫폼 합계다. macOS arm64 슬라이스는 그보다 작다(macOS bin tar 16.1 MB 참고, 슬라이스는 E 10~15 MB). 가중치 Q8_0 310 MB | mmap, 토크나이저가 GGUF 안(E 0.1~0.3 s, 미측정) | Apple 값 없음 | `n_gpu_layers=0`이면 CPU 전용. ANE 경로 자체가 없음 | 일일 빌드라 태그 고정 필요. 공식 Swift 래퍼 없음(C API 모듈맵). M1에서 Q8_0은 dotprod만 사용 |
| **MLX-Swift** (`mlx-swift-lm`, MIT, Apple Inc. 저작권, F) | `EmbeddingGemma2` 포트가 2026-10-12 커밋 "Add EmbeddingGemma 2 full support (#684)"(F). MLXEmbedders 레지스트리에 `embeddinggemma2`, `multilingual_e5_small`, `bge_m3`, nomic, MiniLM이 있음 | 코드는 작고 Metal 셰이더 라이브러리가 큼(mlx-metal 휠 45 MB 압축을 규모 참고). 가중치 bf16 또는 4/8bit | swift-transformers(Apache-2.0)로 `tokenizer.json` 32 MB 파싱. 미측정, 위험 지점 | 없음 | Metal(GPU) 기본이라 ANE 안 씀(S). CPU 스트림도 가능하나 CPU 속도 미공개 | 포트가 9일밖에 안 됨. macOS ≥ 14(F). MLX를 넣은 macOS MAS 앱 사례는 확인 못 함 |
| **ONNX Runtime CPU EP** (MIT, F) | SwiftPM `microsoft/onnxruntime-swift-package-manager` 최신 1.24.2(2026-02-25, 정적 라이브러리, macOS ≥ 14). PyPI 본체는 1.31.0이라 패키지가 뒤처짐 | 라이브러리 약 20~30 MB(PyPI macOS 휠 20.9 MB 참고). 가중치 q4 174 MB + 토크나이저 별도 | E 0.2~0.5 s | 없음 | CPU EP만 등록하면 ANE 없음(Core ML EP는 등록 금지) | 1.24.2가 q4 연산(MatMulNBits/GatherBlockQuantized)을 EG2에서 돌리는지 미확인 |
| **LiteRT-LM** (Apache-2.0, F) | Swift API "Early Preview", C++ Stable. EmbeddingGemma 2 공식 지원 문구(F) | 공식 `.litertlm` 165 MB. 런타임 크기는 미확인 | 공개 값 없음(v1: CPU 초기화 17.6 ms, F) | **M5 CPU 31.3 / GPU 9.5 ms @128토큰**(F) | CPU/GPU 델리게이트만, ANE 없음 | Swift가 early preview. 새 의존성 스택 |
| **Core ML** (coremltools 9, BSD-3, F) | 변환본은 전부 커뮤니티. valindotai(INT8 295 MB, seq 256), mihijito(seq 128), visible-cx(309 MB, seq 128, `.cpuAndNeuralEngine`), FluidInference(v2, 텍스트 fp16 277 MB + 테이블 268 MB) | 약 300~545 MB | FluidInference: ANE 첫 로드가 "several minutes once" 컴파일(F). CPU/GPU 컴파일 시간은 미공개 | **CPU/GPU 값은 어디에도 없음.** 전부 ANE 기준 | `.cpuAndGPU`는 ANE 장치를 열지 않음(ane-dev, spec). 그러나 변환본이 ANE용 | fp16 NaN, 정적 shape 필수("Variable-length shapes put the whole graph on the CPU"), 순진한 변환은 조용히 CPU 폴백(erjigit17), 4/6bit 팔레트화는 품질만 깎고 속도 이득 없음. ANE 컴파일 정지와 같은 부류 |
| Apple `NLContextualEmbedding` (macOS 14+, F) | CJK 스크립트 모델 있음(WWDC23: Latin 20 / Cyrillic 4 / CJK 3언어) | 0 | 자산을 "downloaded as needed"(`requestAssets`, F) | 없음 | 연산 장치 선택 불가 | **제외.** 읽는 시점 네트워크 금지와 충돌하고 ANE 사용을 통제할 수 없다 |

**성능 유도 (E, m-bench가 이 Mac에서 측정할 것)**
- EG2 텍스트 backbone 130M은 토큰당 약 0.26 GFLOP이다. 128토큰이면 33 GFLOP이다.
- M5 CPU 31.3 ms는 유효 약 1.06 TFLOP/s다. M5에는 SME가 있다.
- M1 Pro는 NEON 8P 정점이 약 820 GFLOPS fp32이고, 실효 20~50%로 160~410 GFLOP/s로 본다.
  - 128토큰: 80~210 ms
  - 정확 길이 32토큰 블록: 20~52 ms
  - LiteRT처럼 128 시그니처 고정이면 길이와 무관하게 80~210 ms
- 화면당 약 24블록 × 25토큰 = 600토큰(H2 평균, 가정)이면 156 GFLOP이다. M1 Pro CPU로 0.4~1.0 s이고, 불확실 구간 30%만 돌리면 0.12~0.3 s다. 논문 쪽(<1 s/page)은 가능하다. 라이브 렌즈의 블록당 수 ms는 불가능하다.
- GPU는 M5 9.5 ms @128이고, M1 Pro는 10~25 ms로 본다(E). 프레임 배치로 처리하면 CPU보다 유리하다.

## 3. 동급 후보 (짧은 텍스트 분류용)

| 모델 | 라이선스(F, 한 줄) | 크기 | 언어 | CPU 속도 등급(E) | Swift 경로 |
|---|---|---|---|---|---|
| **multilingual-e5-small** | README `license: mit` | 117.7M 파라미터, 384d, 12층. 본체 약 21M, 나머지 약 96M은 250,002×384 테이블(유도). ONNX fp32 470 MB, fp16 235 MB, qint8 118 MB(x86 전용), GGUF Q8_0 132 MB(서드파티), MLX 235 MB | 94개, ja/ko/zh 명시 | EG2의 약 1/6 FLOP, 32토큰 블록 3~10 ms | MLXEmbedders `multilingual_e5_small`(F), llama.cpp GGUF, ORT. 접두 `query: `(비검색은 이것 하나) |
| **gte-multilingual-base** | `license: apache-2.0` | 305.4M, 768d. ONNX int8 340 MB, fp32 1.26 GB | 70+ | 본체 약 113M, EG2급 | `trust_remote_code` 커스텀 `new-impl`(F). MLXEmbedders에 없고 임베딩용 GGUF도 못 찾음. 제외 |
| **bge-m3** | `license: mit` | XLM-R large급(카드에 파라미터 수 없음, S 약 568M). ONNX fp32 2.27 GB, int8 약 570 MB(E) | 100+ | EG2의 약 2.3배 | MLXEmbedders `bge_m3`. 크기로 제외 |
| **potion-multilingual-128M** | `license: mit` | 128.1M fp32 = 512 MB, 출력 256d(F). int8 약 128 MB, 어휘 축소 시 10~30 MB(E) | 101개 | 텍스트당 0.1~0.2 ms. model2vec README "up to 500 times faster on CPU than the original model"(F) | Swift 포트 없음. 추론은 50줄이지만 토크나이저가 bge-m3 XLM-R Unigram(precompiled charsmap)이라 swift-transformers나 sentencepiece 필요. MTEB multi 평균 47.31, Classification 52.36(LaBSE 52.07/54.60) |
| **mmBERT-small** | `license: mit` | 140M 총 / 42M 비임베딩, 22층, hidden 384, vocab 256k, 8192. ONNX int8 143 MB, fp16 282 MB | 1811개(ko/ja 명시 없음) | 본체가 e5-small의 약 2배 | MLM 베이스라서 우리 라벨로 파인튜닝해야 한다. MLXEmbedders에 ModernBERT 없음(Bert, EG2, Gemma3, LFM2Bidirectional, NomicBert, Qwen3). Core ML 커뮤니티 변환 `znaat/mmbert-small-coreml` 있으나 미검증 |
| **char n-gram 선형 (fastText 스타일)** | fastText LICENSE "MIT License / Copyright (c) 2016-present, Facebook, Inc."(저장소는 2024-03-22 아카이브) | 수십 KB~수 MB. fastText.zip 초록: "two orders of magnitude less memory than fastText ... only slightly inferior with respect to accuracy" | 문자 단위라 분절기 불필요 | 0.01~0.05 ms | 순수 Swift 100줄 안팎, 결정적. 학습은 sklearn hashed char 1~4-gram + 로지스틱 후 가중치만 내보내기. 사전학습 의미 지식은 없음 |

## 4. 과제 적합성: 텍스트 전용 임베딩이 보는 것과 못 보는 것

근거는 keep-boundary §9의 표(번역되어 버린 pure-keep 코드 블록 24개 중 포착 수)와 RESULTS-h2다.

| 근거 | §9 포착 수(24중) | 텍스트 임베딩이 보나 | 출처 |
|---|---|---|---|
| 들여쓰기 | 17 | 못 봄. OCR 텍스트에서 공백이 사라진다. 줄 앞에 합성 토큰을 넣으면 약하게 읽을 수는 있다(E) | 단어 상자 x 좌표 |
| 배경 색조 | 12 | 못 봄 | 픽셀 |
| 키워드 밀도 | 10 | **봄, 가장 강한 기여.** 규칙에 없는 언어(Swift/Rust/Kotlin)와 키워드도 "코드다움"으로 일반화한다 | 텍스트 |
| 줄 끝 `; { } )` | 2 | 봄(규칙이 이미 잡아서 추가 이득은 작음) | 텍스트 |
| 모노스페이스 폭 | 1 | 못 봄 | 글자 폭 변동 |
| 인접 블록 맥락 | H2에서 42개 영역 중 39개가 분할됨 | 한 블록만 넣으면 못 봄. 이웃 블록 텍스트를 잇거나 이웃 임베딩을 평균해 헤드에 주면 가능 | 블록 순서/기하 |
| 코드 안의 CJK 주석 | 코드 블록은 주석째 유지(결정 2026-10-19) | 줄 단위로는 산문처럼 보여서 블록 전체나 맥락이 필요 | 맥락 |
| 문장 속 식별자/경로/명령 | H2 인라인 recall 0.11(308개 중 275개 누락) | 아래 설명 | 텍스트 + 인라인 모노스페이스 |
| OCR 오인식 | - | 규칙보다 둔감 | 텍스트 |
| 프레임 간 깜빡임 | §5: 정지 화면 재읽기에서 ≤1% 단어만 뒤집힘 | 글자 하나만 달라도 풀링 벡터가 연속적으로 변해 임계 근처에서 뒤집힘. 정규화 텍스트 해시 캐시와 히스테리시스가 필요 | - |

- **인라인 구간의 이득과 한계.** 임베딩은 npm, kubectl, 설정 키 같은 이름에 대한 세계 지식이 있어서, 규칙이 "텍스트 모양이 없다"고 포기한 구간에서 규칙을 이길 수 있는 거의 유일한 요소다.
  - 풀링 출력은 블록당 벡터 하나라서 단어 라벨을 못 준다.
  - 단어별로 쓰려면 후보마다 ±k 단어 창을 따로 임베딩해야 해서 호출 수가 폭증한다.
  - 아니면 토큰 hidden state 위에 태깅 헤드를 파인튜닝해야 한다(§5 rung 3, 어휘 정렬 필요).

**하이브리드 배선**
1. **위치.** §5대로 `makeBlock`(TextRecognizer.swift:500-510) 이후, `needsTranslation` 이전에 둔다. 규칙이 확정한 블록은 건드리지 않고, 불확실 구간만 모델에 보낸다. 확정 출력은 바이트 동일이다.
2. **입력 문자열.** 공백/줄바꿈을 정규화한 블록 텍스트에 앞뒤 이웃 블록 1개씩을 붙인다. EG2는 접두 `task: classification | query: `를 쓴다(카드 사용법이고 모델별 우회가 아니다).
3. **임베딩.** MRL 256d로 자르고 재정규화한다(카드: "minimal quality impact down to 256d"). 키는 정규화 텍스트 해시, 메모리 캐시다.
4. **특징 벡터.** [임베딩 256d, 또는 프로토타입 코사인 3~6개(code/log/prose/path) ‖ 레이아웃 특징]. 레이아웃 특징은 아래와 같다.
   - 들여쓰기(글자 높이 단위)
   - 글자 폭 변동계수
   - 이웃 대비 배경 색조 ΔE
   - 줄 끝 문자 분포
   - 줄 수와 블록 종횡비
   - 기존 규칙 플래그(isLiteral/isFormula/CodeRegion 점수)
5. **헤드.** 로지스틱 회귀나 부스티드 트리(Create ML, §5 rung 1), 또는 은닉층 1개 MLP(≤50k 파라미터)다. 임베더는 동결하고 헤드만 학습한다(맥에서 분 단위). 라벨이 수백 블록 규모면 256차원을 그대로 넣지 말고 PCA→16 또는 프로토타입 코사인으로 줄인다.
6. **보정과 임계.** 등온 보정(reliability error ≤ 0.05)을 하고, 두 오류 비용에 임계를 따로 둔다.
7. **평가.** 규칙만 / 임베딩만 / 레이아웃만 / 하이브리드 4열 ablation을 이유별로 본다. 기준은 H2/H3 hold-out과 인라인 구간 recall이다.
8. **현실 점검.** H2 결론은 region 누락(670/945 단어)이 규칙 수정으로 닫히고 모델이 필요한 인라인 구간은 recall 4.5~6.5점이라는 것이다. 블록 임베딩 하이브리드의 이득은 규칙 수정이 닫을 구간과 겹친다. 인라인까지 노리려면 단어 단위 출력이 먼저다.

## 5. 판정 표 (M1 Pro CPU, 블록 32토큰 가정, E)

| 후보 | 라이선스 OK (MAS) | 번들 MB | 블록당 ms CPU | ko/ja/zh | Swift 경로 위험 |
|---|---|---|---|---|---|
| **EmbeddingGemma 2 text-only** | OK(Apache-2.0, LICENSE+NOTICE+수정 표시) | 165(LiteRT int4) / 174(ONNX q4) / 310(GGUF Q8). 어휘 축소 시 약 75~90(E) | 20~52. 라이브 렌즈 부적합 | 100+(언어별 점수 미공개) | llama.cpp 낮음~중간, MLX 중간(신규 포트), Core ML 높음 |
| EmbeddingGemma v1 | **조건부**: Gemma ToU(EULA에 사용 제한, Notice, 약관 사본, 증류 모델 상속, 원격 제한권) | 196~334 | 위와 같은 급 | 100+ | v2가 있어서 쓸 이유 없음 |
| **multilingual-e5-small** | OK(MIT) | 132(GGUF Q8) / 어휘 축소 int8 약 35 | 3~10 | 94, ko/ja/zh 명시 | 낮음~중간(MLXEmbedders와 llama.cpp 둘 다 지원) |
| gte-multilingual-base | OK(Apache-2.0) | 340(int8) | EG2급 | 70+ | 높음(커스텀 아키텍처) |
| bge-m3 | OK(MIT) | 약 570(int8) | EG2의 2.3배 | 100+ | 중간. 크기로 탈락 |
| **potion-multilingual-128M** | OK(MIT) | 512 → int8 약 128 → 어휘 축소 10~30 | 0.1~0.2 | 101 | 중간(토크나이저가 관건) |
| mmBERT-small | OK(MIT) | 143(ONNX int8) | 5~20 | 1811(ko/ja 명시 없음) | 높음(파인튜닝 필요, 지원 라이브러리 없음) |
| hashed char n-gram 선형 | OK(직접 학습) | <5 | <0.05 | 문자 단위라 무관 | 낮음(순수 Swift) |

- §5 예산(가중치 ≤ 5 MB, 블록당 p95 ≤ 1 ms)을 만족하는 것은 char n-gram뿐이고, 사전학습 임베더는 모두 초과한다.
- 임베더의 올바른 위치는 세 가지다.
  - 오프라인 teacher/labeler(Apache·MIT라 자유)
  - 논문 경로의 지연 허용 보조 판정(불확실 구간, 캐시, opt-in)
  - 증류 대상(소형 학생 → 정적 표나 작은 CNN)
- **m-bench 후보와 순서**
  1. **EmbeddingGemma 2 text-only.** llama.cpp CPU-only `embeddinggemma-2-Q8_0.gguf`가 기본이다. 같은 라벨에서 MRL 768/256/128을 비교한다. 목적은 상한과 teacher 가치다. CPU 지연은 128 시그니처 고정과 정확 길이 둘 다 기록한다.
  2. **multilingual-e5-small.** GGUF Q8_0 또는 MLXEmbedders로 돌린다. 목적은 가벼운 트랜스포머가 EG2 대비 얼마나 잃는지다.
  3. **potion-multilingual-128M.** 같은 헤드를 붙인다. 목적은 속도 하한과 토크나이저 이식 비용이다.
  - 대조군(후보 수 밖): hashed char 1~4-gram + 로지스틱, 같은 hold-out. 사전학습 의미가 더하는 몫을 가른다.
  - 모든 후보에 같은 헤드와 같은 4열 ablation을 적용할 것.

## 6. 인용 (출처당 한 줄)

- F https://ai.google.dev/gemma/terms: "All Distributions (other than through a Hosted Service) must be accompanied by a "Notice" text file" (§3.1)
- F https://ai.google.dev/gemma/docs/gemma_4_license: 제목 "Apache License 2.0", 본문 "Apache License Version 2.0, January 2004"
- F https://huggingface.co/google/embeddinggemma-2: `license: apache-2.0`; "combining a 270M parameter text model with modular vision (170M) and audio (300M) encoders."
- F https://developers.googleblog.com/embeddinggemma-2-the-developer-guide/: "released under the Apache 2.0 license"; "Disabled encoders are never loaded into memory"
- F https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm: "MacBook Pro M5 | CPU | 128 | ... | 31.3 | 165 MB"
- F https://huggingface.co/FluidInference/embeddinggemma-2-coreml: Variable-length shapes "put the whole graph on the CPU"; ANE "3,862 / 3,862 ops (100%)"
- F https://huggingface.co/ggml-org/embeddinggemma-2-GGUF: "Architecture: gemma-embedding2"; Q8_0 310 MB
- F https://github.com/ggml-org/llama.cpp/pull/30054: "model: support embeddinggemma2 (text+vision+audio)", merged 2026-10-06
- F https://github.com/ml-explore/mlx-swift-lm: `Libraries/MLXLMCommon/Models/EmbeddingGemma2.swift:277` `selectingEncoders`; 커밋 "Add EmbeddingGemma 2 full support (#684)"
- F https://huggingface.co/onnx-community/embeddinggemma-2-ONNX: `model_q4.onnx_data` 174,028,800 B
- F https://huggingface.co/google/embeddinggemma-300m: "Maximum input context length of 2048 tokens"; "EmbeddingGemma activations do not support `float16`"
- F https://huggingface.co/litert-community/embeddinggemma-300m: "CPU | 256 | 17.6 | 66 | 110 | 179"
- F https://github.com/google-ai-edge/LiteRT-LM: Apache-2.0, Swift "Early Preview"
- F https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement: "Apply a custom EULA to all chosen countries or regions"
- F https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding.md: "Requests embedding model assets and downloads them if available."
- F https://wwdcnotes.com/documentation/wwdc23-10042-explore-natural-language-multilingual-models/: 모델이 "rely on assets that are downloaded as needed"
- F https://huggingface.co/intfloat/multilingual-e5-small, https://huggingface.co/BAAI/bge-m3, https://huggingface.co/minishlab/potion-multilingual-128M, https://huggingface.co/jhu-clsp/mmBERT-small: README `license: mit`
- F https://huggingface.co/Alibaba-NLP/gte-multilingual-base: `license: apache-2.0`, `trust_remote_code=True`
- F https://github.com/facebookresearch/fastText: LICENSE "MIT License"; 아카이브됨. https://arxiv.org/abs/1612.03651 초록의 "two orders of magnitude less memory than fastText"
- F https://github.com/MinishLab/model2vec: "up to 500 times faster on CPU than the original model"
- F repo 내부: `tools/keep-labels/RESULTS-h2-2026-10-20.txt` 결론 1-5, `docs/design/keep-boundary.md` §5와 §9
- S: 출시를 보도한 2차 기사(eesel.ai 등)는 1차 출처(HF 카드)와 대조한 뒤에만 썼다.

## 7. 실행한 검증 명령의 실제 출력 줄

- `curl https://ai.google.dev/gemma/terms` → `200 144362`
- HF API `onnx-community/embeddinggemma-2-ONNX` → `license= apache-2.0 gated= False`; `onnx/model_q4.onnx_data 174028800`; `model_q4f16.onnx_data 156862464`; `model_quantized.onnx_data 313724928`; `model.onnx_data 1084170240`
- HF API `ggml-org/embeddinggemma-2-GGUF` → `embeddinggemma-2-Q8_0.gguf 309855456`; `embeddinggemma-2-BF16.gguf 557950176`; `mmproj-embeddinggemma-2-Q8_0.gguf 554821024`
- HF API `litert-community/embeddinggemma-2-text-270m-litert-lm` → `embeddinggemma-2-text-270m.litertlm 164626432`
- HF API `FluidInference/embeddinggemma-2-coreml` → Text `weight.bin 276815424`; `embeddings.bf16 268435456`
- v1: `embeddinggemma-300M-Q8_0.gguf 333590944`; `embeddinggemma-300M-qat-Q4_0.gguf 277852192`; `embeddinggemma-300m-qat-Q8_0.gguf 328577056`; ONNX v1 `model_q4.onnx_data 196725760`, `model_quantized.onnx_data 308890624`; `google/embeddinggemma-300m-qat-q4_0-unquantized` → `gated= manual license= gemma`
- 피어: e5-small `params= 117654272 license= mit`, `onnx/model.onnx 470268510`, `onnx/model_qint8_avx512_vnni.onnx 118346824`; gte `params= 305369089 license= apache-2.0`; bge-m3 `onnx/model.onnx_data 2266820608`; potion `params= 128090368`, `model.safetensors 512361560`; mmBERT-small ONNX `onnx/model_int8.onnx 142665533`
- GitHub API llama.cpp → `b11748 2026-10-20T00:23:31Z`, `llama-b11748-xcframework.zip 66860024`, `llama-b11748-bin-macos-arm64.tar.gz 16103472`; PR 30054 `merged True 2026-10-06T16:20:31Z`
- GitHub API `mlx-swift-lm/.../MLXEmbedders/Models` → `['Bert.swift', 'EmbeddingGemma2.swift', 'Gemma3.swift', 'LFM2Bidirectional.swift', 'NomicBert.swift', 'Qwen3.swift']`
- 패키지 크기: PyPI `onnxruntime-1.31.0-cp312-cp312-macosx_14_0_arm64.whl 20882054`; `mlx_metal-0.32.4-py3-none-macosx_15_0_arm64.whl 44942974`; onnxruntime-swift-package-manager 릴리스 `1.24.2 2026-02-25T19:01:47Z`
- `sysctl -n machdep.cpu.brand_string hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu hw.memsize` → `Apple M1 Pro` / `8` / `2` / `34359738368`; `sysctl -n hw.optional.arm.FEAT_SME hw.optional.arm.FEAT_I8MM hw.optional.arm.FEAT_BF16` → `0 0 0`

## 8. 규정 밖 개선 지점 (보고만)

- `docs/design/keep-boundary.md:133`: §5 라이선스 줄 "trained by us on the sources in §6 only"가 Apache/MIT 사전학습 모델(EG2, e5)을 teacher로 쓰는 길을 막는 것처럼 읽힌다. 허용 범위를 한 줄로 명시하면 된다. 크기 S.
- `docs/design/keep-boundary.md:105`: §4의 "LLM deciders ... 100× over budget" 옆에 임베더 행(10~50× 초과, 이 보고서 §5)을 추가하면 단계 3/4 논의가 선명해진다. 크기 S.
- `tools/keep-labels`: 블록 텍스트와 라벨을 `{id, text, label, reason}` jsonl로 내보내는 얇은 덤프가 있으면 m-bench가 임베딩 후보를 같은 입력으로 돌릴 수 있다. 크기 S~M. 이미 있으면 무시.

## 9. 실행 모델

claude-sonnet-5-5 (Sonnet 5.5).
