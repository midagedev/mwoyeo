# research-terms: 용어집보다 나은 방법 (2026-10-18, 읽기 전용 라운드)

표시: [fetched] = URL을 열어 한 줄을 그대로 복사함. [검색요약] = 검색 결과 요약에서만 나옴(원문 미확인). [측정] = 이 Mac에서 직접 돌려 본 값.
이 라운드가 한 일: 레포 읽기, 웹 조회, 임시 Swift 파일 3개(scratchpad, 레포 밖)를 컴파일해 OS 질의 3건을 돌림
(NLTagger.availableTagSchemes, NLTagger 문장 14개, StringTransform + NSSpellChecker). Mwoyeo 빌드·렌더, Apple Translation·Foundation Models·Vision 호출은 없음.
"빌드 금지"를 레포 빌드로 읽었음. 어긋나면 알려 주세요.
임시 파일: docs/research/translation/terms-probe/ (schemes.swift, ner.swift, translit.swift)

## 0. 먼저 알아 둘 것 (레포에 이미 있는 것)

- `Core/Sources/MwoyeoCore/GlossarySuggester.swift` (440줄, 커밋 51b29c9, 2026-10-17) + 테스트가 이미 있음. 번역된 줄을 보다가
  "같은 이름이 다르게 나오거나 그대로 남은 것"을 찾아 "アリス = 앨리스를 용어집에 넣을까요?"로 제안하는 휴리스틱.
  이름 후보는 가타카나 연속열, 영어 대문자 단어, NLTagger nameType. 가타카나→한글 규칙 변환기 `KanaHangul`(같은 파일 :365)도 있음.
  App에서는 한 곳도 부르지 않음 (`grep -rn GlossarySuggester App Core/Sources` → 자기 파일뿐). 즉 "자동 제안" 아이디어는 코드가 있고 화면이 없음.
- 번역 캐시 `Memory`(TranslationService.swift:782)는 "원문 한 줄 → 번역 한 줄"이다. 같은 줄은 같게 나오지만, 이름이 다른 줄 안에 들어가면 줄마다 따로 번역됨.
- Apple Translation에는 문맥도 용어집도 넣을 길이 없음 [측정: SDK 인터페이스 확인]
  `Translation.framework/.../arm64e-apple-macos.swiftinterface`를 `context|glossary|terminolog|dictionary`로 grep → 일치 0줄.
  있는 것은 `preferredStrategy`, `skipsTranslation`, `Request(sourceText: AttributedString)`뿐. 기본 엔진에 줄 수 있는 지렛대는 "원문을 고쳐서 보내기"(사전 삽입) 하나.
- Foundation Models: 세션당 컨텍스트 4096 토큰 [fetched] TN3193 "Apple's on-device foundation model has a context window of 4096 tokens per language model session."
  라틴 문자 3–4자/토큰, CJK 약 1자/토큰 [fetched, 같은 문서]. `SystemLanguageModel.contextSize`가 있음. 지금 `IntelligenceTranslator`는 줄마다 새 세션(TranslationService.swift:901)이라 이전 줄은 안 들어감.

## 1. 용어집이 푸는 진짜 필요

한 줄로: "화면에 같은 이름이 나올 때마다 같은 모양으로 보이길 원한다." 아래 다섯 가지가 섞여 있고, 용어집은 그중 일부만 풂.

| # | 필요 | 근거 | 용어집이 푸는가 |
|---|---|---|---|
| N1 | 같은 이름이 줄마다 다르게 나옴 | 아래 Netflix 포럼, Dishonored 2 (Gundam 자막의 Katz→Gryps는 [검색요약]) | 풂, 단 사용자가 어떤 이름인지 알고 직접 써야 함 |
| N2 | 이름이 일반 단어나 다른 개체로 번역됨 | Netflix 포럼 (Gundam도 [검색요약]) | 풂 (같은 조건) |
| N3 | 음역/번역/그대로 둠 중 무엇을 원하는가 | Game Developer 글 | 사용자 취향이라 용어집만 답할 수 있음 |
| N4 | 게임 고유 용어(스킬, 아이템)를 공식/팬 번역과 맞추기 | Game Developer 글, GalTransl | 사용자만 아는 정보. 용어집이 맞는 도구 |
| N5 | 용어 뒤 조사가 어색함 | 이 레포 측정(사전 삽입 88/88, 98/102) | 사전 삽입으로 이미 해결 |

증거 (모두 [fetched]):
- Netflix 자막, 중국어 이름: https://forum.languagelearningwithnetflix.com/t/settings-for-how-chinese-names-are-machine-translated/402
  "really likes mangling the Chinese names of fictional Chinese people and organisations" (사용자). 嘉世 → "Castrol", "Carion", "The Kardashians"
  한 이름이 세 가지로 나옴 (N1+N2). 운영팀 답(요약): 원문에서 이름을 따로 떼어 선호 번역 용어집을 번역 API에 같이 보내면 가능하겠지만,
  "it's quite some work for a 'niggle'" — 즉 파이프라인이 이름을 따로 떼어 내는 일이 병목이라는 인정.
- 게임 현지화 글: https://www.gamedeveloper.com/production/translating-city-and-character-names-in-video-games
  "keep the original nouns untranslated, translate them literally or partially literally, or create brand new nouns." (N3, 정답이 하나가 아님)
  Dishonored 2 (N1): "Surprisingly, they kept the original names for the other locations, like Dunwall or the Dreadful Wale." (Dust District만 Poussièreville로 번역됨)
- GalTransl 설명(번역가 커뮤니티): "只有当本次发送给GPT的人名和句子中有这个词，这个词的解释才会被送进本轮的对话中。" (그 단어가 이번 요청에 있을 때만 사전 항목을 보냄)
  https://github.com/xd2333/GalTransl — "但不要什么词都往里加" (아무 단어나 넣지 말라). 즉 용어집 관리 비용이 커서 사용자가 힘들어함.
- [검색요약] 일반 MT 가이드(IGDA, Roblox 포럼)에서 "breath → bracelet"처럼 일반 단어가 매번 같은 오역으로 나오는 사례. 원문 미확인.

한국어 사용자의 직접 증거는 못 찾음 (한국어 검색 2회, 파파고 포함, 해당 글 없음). X에서 온 사용자에게 물어볼 것:
(1) 어떤 앱/게임인가, (2) 어떤 이름이 어떻게 보였나(스크린샷 한 장), (3) 한 줄 안에서 틀렸나 줄마다 달랐나, (4) 음역을 원하나 원문 그대로를 원하나.
이 답이 N1(줄마다 다름)과 N2(오역) 중 어느 쪽이 큰지 정함.

## 2. 아이디어와 사전 근거

### 2.0 이 레포에서 쓸 수 있는 부품 (측정)

- **NLTagger nameType**: Apple 문서는 지원 언어와 정확도를 적지 않음 [fetched] `NLTagScheme.nameType` 문서: "A scheme that classifies tokens according to whether they are part of a named entity." 끝. 언어 목록 없음, 정확도 주장 없음.
  이 Mac(macOS 27.0, 추가 에셋 없음)에서 `NLTagger.availableTagSchemes(for: .word, language:)` [측정]:
  en만 NameType 있음. ko ja zh-Hans zh-Hant fr de it es pt ru tr ar th vi id nl pl hi 전부 NameType 없음 (Language, Script, TokenType만). 레포 주석("NLTagger tags no Japanese, Chinese or Korean names")과 맞고, 유럽어도 없음.
  Apple이 에셋으로 내려받게 하는지는 확인 안 함 (내려받기는 시스템을 바꾸는 일이라 안 함).
- **영어 nameType 품질** [측정, 문장 14개라 선별 수준]: 이름 판정 자체는 반쯤 맞고 종류 표시는 못 믿음.
  맞음: "Rose draws her sword" → Rose 인명, "Priya Shah"/"Yuki Tanaka" 인명, "Kael" 인명, "Elara/Silverwood/Eastgate" 지명.
  놓침: "Varkus", "Zed", "Iron Wolves", "Flame Tongue Sword", 문장 끝 "Will you come with me, Rose?"의 Rose.
  종류 틀림: "Elena" 단독 → PlaceName, "ELENA:" 대문자 → PlaceName, "Mira" → OrganizationName, "Aria" → OrganizationName.
  결론: 쓰려면 "이름 여부"만 쓰고 종류는 버림. 단독으로는 부족하니 휴리스틱과 합쳐야 함 (GlossarySuggester가 이미 그렇게 함).
- **영어 미등록 단어 신호** (NSSpellChecker, [측정] 10단어): Varkus, Silverwood, Kael은 UNKNOWN, Elara, Mira, Zed, Eastgate, Rose는 known. 지어낸 이름의 회수율 3/7. 보조 신호로만.
- **레이아웃 신호는 언어를 가리지 않음**: 사용 사례 벤치 g01(`tools/usecase-bench/set/g01-vn-dialogue-ja.expected.txt`)은 첫 단위가 "ハルカ"(이름 상자), 다음이 대사.
  c01 채팅은 "Priya Shah 10:42 AM"(보낸 사람 + 시각). 이름 상자와 보낸 사람은 "한 줄짜리 짧은 블록이 긴 본문 블록 옆/위에 있음"으로 잡힘. 새 코드는 ParagraphGrouper 주변. 이 아이디어는 선행 사례를 못 찾음 (내 제안).
- **kana→한글 규칙 변환**: 이미 `KanaHangul`이 있음. 참고로 ICU `toLatin → latinToHangul` [측정]은 ハルカ→하루카, ミラ→미라, サクラ→사쿠라는 맞지만
  シンジ→스힌지, カイル→카이루, ヴァルカス→부~아루카수, 银月城→유이뉴에쳉으로 깨짐. ICU 길은 쓰지 말고 KanaHangul을 쓸 것. 중국어 이름은 pinyin을 거치면 艾琳→아이린이 나오나 다음절 지명은 깨짐 (공백 처리 문제일 수 있어 결론 아님).
- **OCR customWords**: [fetched] "An array of strings to supplement the recognized languages at the word-recognition stage. Custom words take precedence over the standard lexicon. The request ignores this value if [usesLanguageCorrection] is [false]."
  레포는 이미 용어집 원문을 customWords로 보냄 (RegionPipeline.swift:788, 791, 861). `.fast` 읽기는 usesLanguageCorrection=false(TextRecognizer.swift:63)라 효과 없음, `.accurate`에서만 의미.
  효과 크기는 레포에 측정이 없음.

### 2.1 아이디어별 카드

각 항목: 어떻게 / 선행 사례 / 온디바이스 가능성 / 이득 / 비용 / 위험 / "설정 없음" 적합도.

**A. 이름 상자와 라벨이 본문을 가르침 (세션 용어 기억, 레이아웃 기반)**
- 어떻게: 화면에서 짧은 한 줄 블록(이름 상자, 보낸 사람, 아이템 제목)을 이미 번역함. 그 (원문 → 번역) 쌍을 세션 메모리에 저장하고, 같은 원문이 더 긴 블록 안에 나오면
  측정된 사전 삽입 경로로 번역어를 원문에 넣어서 보냄 ("ねえ、ハルカ" → "ねえ、하루카"). 새 번역 요청은 늘지 않음 (이미 보낸 라벨 번역을 재사용). 라벨→본문 순서 의존만 생김.
- 선행: LunaTranslator "Pre-translation Substitution" [fetched] "This method directly replaces the original text with the translated text before translation."
  차이: 거기는 사용자가 쓴 치환, 여기는 화면의 라벨에서 자동 수집. 같은 곳의 고유명사 기능은 LLM이 아닌 엔진에는 자리표시자로 바꿔 보냈다가 복원함 — 이 레포는 자리표시자가 조사에서 1/4 틀리고 문장을 깨뜨렸다고 측정함(paper-translation.md §3), 사전 삽입이 더 낫다.
  VNTextPatch가 비슷하게 게임에서 이름을 모아 한 번만 번역하게 함 [fetched]: "After running `extractlocal`, VNTextPatch will populate a file called names.xml with all the character names it encountered."
- 온디바이스: 가능. Apple Translation 기본 엔진(ll, hf) 모두 사전 삽입 측정됨 (ll 88/88, hf 98/102 — 레포 측정). 새 API 없음.
- 이득: 이름 상자와 대사 속 호칭이 같아짐 (N1, N2의 "화면에서 보이는" 부분). 채팅의 보낸 사람 이름과 멘션도 해당.
- 비용: 블록 분류(짧은 한 줄 + 인접한 긴 블록), 세션 맵, resolve 한 곳. 새 UI 없음.
- 위험: (1) 흔한 단어 라벨("Start", "Back", "戻る")이 본문에 삽입되면 오히려 틀림 → 이름 상자로 분류된 것과 Title Case 두 단어 이상/미등록 단어만 핀. (2) 라벨 번역 자체가 틀리면(Rose→장미) 그 오류를 본문에 퍼뜨림. 단 사용자가 이미 보고 있는 모양과 맞춰질 뿐이고, B로 고칠 수 있음.
  (3) 사전 삽입은 hf에서 98/102만 적용됨(미적용 4건, 반복 음절로 깨진 줄 2건: "손실실은", "ロススは" — glossary-preinsert/predictions.txt). (4) 개인정보: 채팅 이름은 사람 이름이므로 디스크 금지, 메모리만 (Settings 푸터가 "never written to disk"라고 약속함).
- 설정 없음 적합도: 완전함. 사용자가 알 필요 없음.

**B. 한 번의 교정으로 배움 ("원문 단어를 눌러 번역어를 적음") + 자동 제안**
- 어떻게: 렌즈 위의 원문 단어(Vision의 단어 상자)를 누르면 작은 말풍선이 뜨고 번역어를 한 번 적음 → 용어집 한 줄이 생김. 원문 쪽을 누르므로 정렬(alignment)이 필요 없음 (Apple Translation은 정렬을 주지 않음).
  또는 이미 있는 `GlossarySuggester`를 불러 "아리스가 3가지로 나왔어요: 앨리스 ×5, 아리스 ×2. 앨리스로 고정?"을 한 번 누르면 확정.
- 선행: XUnity.AutoTranslator [fetched]: "All translation results are cached in memory and stored on disk to prevent making the same translation request twice." 와 사용자가 그 파일을 고치면 "will always have the lowest priority" 라서 고친 것이 이김.
  Moslem & Haque 2023, https://arxiv.org/abs/2301.13294 [fetched]: "It is especially important to adhere to pre-approved terminology and adapt to corrected translations in domain-specific projects."
  Netflix 포럼 운영팀도 교정 제출은 언젠가 가능할 수 있다고 답함 (요약; 사용자가 원했던 기능).
- 온디바이스: 가능. 사용자 확인을 거치므로 오탐 부담이 없음.
- 이득: 사용자가 어떤 이름이 문제인지 몰라도, 문제를 본 순간 한 번 누름. 용어집을 "쓰는" 일이 "고치는" 일로 바뀜. 앱별 저장(AppProfile에 필드 추가)과 잘 맞음.
- 비용: UI (렌즈 클릭 처리, 말풍선, 원문 단어 → 상자 매핑), Suggester 연결. 중간 크기.
- 위험: 렌즈 오버레이가 클릭을 통과시키는 구조면 눌러서 고치는 동작이 충돌할 수 있음 (확인 안 함). 디스크에 저장되는 것은 사용자가 확정한 쌍뿐이어야 함.
- 설정 없음 적합도: 처음엔 아무것도 안 보이고, 문제를 본 사용자만 찾는 "깊은 층". 원칙과 맞음.

**C. 문맥 줄과 "본 이름 목록"을 Foundation Models 엔진에 넣기**
- 어떻게: 같은 화면의 앞뒤 블록(읽는 순서)에서 이전 2–3줄을 프롬프트에 붙임. 세션 지침에 이번 세션에서 본 이름 핀 목록을 용어집처럼 추가.
- 선행: DeepL API `context`: [fetched] "Additional context that can influence a translation but is not translated itself." 그 글자는 과금되지 않음.
  RSTGameTranslation [fetched]: "Context: Previous text pieces that help the AI understand the conversation flow." 와 "Using context significantly improves translation quality, especially for conversations."
  tomkam1702/OCR-Translator [fetched]: "Remembers up to 5 previous subtitles to maintain narrative and grammatical flow across dialogue."
  OxyTranslateGame (macOS 네이티브, 같은 분야) [fetched]: "Local context of three passages and a glossary guide Ollama; output can still be wrong." 그리고 "The glossary guides the literary model; the fast engine does not apply it." — 이 레포의 기본 엔진과 같은 한계.
  GalTransl [fetched]: 새 세션이 시작되면 "最近 `gpt.contextNum` 句译文"을 다시 붙임.
  Immersive Translate [fetched]: 프롬프트 변수 `{{summary_prompt}}` "Web page context summary (when available)", `{{terms_prompt}}` "Related professional terminology (when available)".
  연구: Karpinska & Iyyer 2023, https://arxiv.org/abs/2304.03245 [fetched] "discourse-level LLM translators commit fewer mistranslations, grammar errors, and stylistic inconsistencies than sentence-level approaches"
  단 "critical errors still abound".
- 온디바이스: FM 엔진에서만. 토큰 계산: 줄당 라틴 3–4자/토큰, CJK 1자/토큰(TN3193) → 문맥 3줄 약 100–150 토큰 + 지침 약 200 토큰 ≪ 4096. 줄마다 새 세션이라 누적 없음.
- 이득: 대명사, 말투, 이름 일관성. 단 기본 엔진(Apple Translation)에는 못 씀 → 선택 기능인 "용어집 우선" 사용자에게만 해당.
- 비용: IntelligenceTranslator 한 곳 수정, 작음.
- 위험: 모델이 문맥 줄까지 번역해서 되돌려 줌, 지연 증가(prefill). hf 엔진은 지금 줄당 0.8–1.3 s.
- 설정 없음 적합도: 완전함 (내부 동작).

**D. Foundation Models로 이름 추출 (`@Generable` 또는 contentTagging)**
- 어떻게: 새 장면의 블록 전체를 한 번 FM에 보내 이름/고유명사 목록과 목표 언어 표기를 받음. 이후 A처럼 사전 삽입.
- 선행: Immersive Translate: `imt_terms` 는 "key terms extracted by the model" 이고 "extracted by proprietary services, currently only available to Pro members." [fetched]
  KeywordGacha [fetched]: "[使用 AI 能力一键分析 小说、游戏、字幕 等文本内容并生成术语表的次世代翻译辅助工具]", 작가 주장 "약 90% 적중"(자기 시험). GalTransl은 GenDic/KeywordGacha를 사전 생성에 쓰라고 안내.
  VideoLingo README [fetched]: "📚 Custom + AI-generated terminology for coherent translation" (순서나 방법은 README에 없음).
  연구: Moslem & Romani, WMT23 용어 과제, https://arxiv.org/abs/2310.14451 [fetched] LLM으로 용어를 후편집해 넣음. Ghazvininejad & Gonen 2023 DiPMT, https://arxiv.org/abs/2302.07856 [fetched] 사전 힌트를 프롬프트에 넣어 희귀어 번역을 제어.
- 온디바이스: Apple Intelligence가 있는 Mac만. FM은 `SystemLanguageModel(useCase: .contentTagging)` 지원 [fetched] "Content tagging produces a list of categorizing tags based on the input prompt." (주제, 감정, 행동, 대상 — 이름 추출용은 아님, 문서에 개체 이름이 안 나옴)
- 이득: 영어 외 언어에서 NLTagger가 못 하는 일(ja, zh, ko 이름)을 하는 유일한 길. 비용: 새 장면마다 FM 요청 1회 (엔진 hf 요청이 0.8–1.3 s이므로 같은 규모로 가정), 결과 캐시.
- 위험: ANE 경합 — 레포 메모리에 "ANE OCR stall" (Vision rev3이 ANE 컴파일러와 엮여 멈춤)이 있음. FM 호출이 OCR과 같은 시간에 돌면 위험을 알 수 없음. 가드레일 거절, 환각 번역어, 가용 Mac 제한.
- 설정 없음 적합도: 되지만 가용 Mac이 좁고 A보다 무거움. A로 부족할 때만.

**E. OCR customWords에 핀 이름 추가**
- 어떻게: A/B의 핀 원문을 customWords에 넣음. 지어낸 이름을 OCR이 비슷한 실제 단어로 "고쳐 읽는" 것(Varkus→Markus)을 막아 원문 문자열이 흔들리지 않게 함.
- 선행: Apple 문서 한 줄 (위). 다른 번역기 사례는 못 찾음.
- 이득: 알 수 없음 (측정 없음). 비용: 거의 0 (이미 배선됨). 위험: language correction이 켜진 `.accurate`에서만 의미.
- 적합도: A/B가 들어가면 덤으로.

**F. (기각) 이름을 번역 없이 그대로 두기 (skipsTranslation)**
- 이 레포 측정: ll 팩은 영어 단어에 skip을 무시함. 사전 삽입은 plain 문자열로도 ll 100%였음. 그대로 두기는 N3 취향이라 용어집이나 B로 고르게 하는 편이 맞음.

## 3. 다른 곳은 어떻게 하나 (짧게)

| 곳 | 하는 일 | 근거 |
|---|---|---|
| DeepL | 언어쌍별 용어집(최대 10 MiB, 항목 1024바이트, 계정당 1000개, "glossaries can not yet be used with source language detection"), `context`, `custom_instructions`(최대 10개, 각 300자), `style_id`. 어형 변화 처리 여부는 문서에 없음 | [fetched] developers.deepl.com/docs/api-reference/translate, .../multilingual-glossaries |
| Google Cloud Translation | 용어집. "This typically involves specifying how to translate a named entity." 예 "Google Home". TSV/CSV/TMX, 10.4M바이트 | [fetched] docs.cloud.google.com/translate/docs/advanced/glossary. 일반 Google 번역 앱에 용어집이 없다는 점은 확인 못 함 |
| Microsoft | 동적 사전 `<mstrans:dictionary translation="…">`, "고유명사, 제품명 같은 복합명사에만 안전", From 지정 필요 | [검색요약] learn.microsoft.com/azure/cognitive-services/translator/dynamic-dictionary (직접 열기는 404 경로였음) |
| Papago | 사용자 용어집 자료를 못 찾음 | 한국어 검색, 없음 |
| Immersive Translate | 용어집 + 모델이 뽑은 용어(Pro 전용) + 페이지 요약. 기본 프롬프트에 "For content that should not be translated (such as proper nouns, code, etc.), keep the original text." | [fetched] immersivetranslate.com/en/docs/prompts/ |
| LunaTranslator | 고유명사 번역(LLM에는 프롬프트에 사전, 그 밖에는 자리표시자로 바꿨다 복원), 번역 전 치환, 번역 후 교정, 게임별 설정 | [fetched] docs.lunatranslator.org/en/transoptimi.html |
| GalTransl | 요청에 나온 단어만 보내는 GPT 사전, 번역 전/후/조건부 사전, 문맥 줄 수, 자동 생성 도구 | [fetched] github.com/xd2333/GalTransl |
| Translumo | 용어집, 이름 처리, 문맥 모두 README에 없음 | [fetched] github.com/Danily07/Translumo |
| Textractor | 추출만 함, 번역은 아래 단계 | [검색요약] Textractor FAQ |
| Sugoi | 사전 기능을 못 찾음 | [검색요약] 없음 |
| OxyTranslateGame (macOS) | 용어집은 느린 문학 모드에서만. "the fast engine does not apply it" | [fetched] github.com/Datastore24Kirill/OxyTranslateGame |
| RSTGameTranslation | "Game Info"에 게임 설명을 적게 함 + 앞 N줄 문맥 | [fetched] thanhkeke97.github.io/RSTGameTranslation/ |

연구 (arXiv 초록을 API로 받아 한 줄 복사, [fetched]):
- 제약 디코딩: Hokamp & Liu 2017 (Grid Beam Search, 1704.07138), Post & Vilar 2018 (1804.06609: "The end-to-end nature of neural machine translation (NMT) removes many ways of manually guiding the translation process").
  Dinu 외 2019 (1906.01105): 제약 디코딩은 "add, however, significant computational overhead to the inference step, and ... can be brittle when tested in realistic conditions", 입력에 용어를 붙여 학습시킨 모델이 "as fast as constraint-free decoding". 닫힌 엔진(Apple)은 디코더도 학습도 못 건드리므로 "입력에 용어를 넣는 쪽"만 가능 — 이 레포의 사전 삽입이 그 계열.
- 이름 전처리: Sharma & Katyayan 2023 (2305.07360): "translating/transliterating name entities as a preprocessing step" 이후 이름 정확도 99.52% (자기 지표, 문장 품질 아님).
- 프롬프트 사전: DiPMT (2302.07856), Moslem & Haque 적응형 MT (2301.13294).
- 문서 단위 일관성: Karpinska & Iyyer 2023 (2304.03245), Wang 외 2023 (2304.02210, "GPT-3.5 and GPT-4 outperform commercial MT systems in terms of human evaluation"). Carpuat 2009 "One Translation Per Discourse" (ACL W09-2404, 제목과 서지만 확인, 초록은 페이지에 없었음).

## 4. 분해와 자원 시간선 (한 번의 렌즈 갱신: 블록 B개, 새 용어 T개)

레포에서 가져온 수치: 요청당 ll 25–70 ms, hf 0.8–1.3 s (glossary-preinsert/predictions.txt). OCR 시간은 이 라운드가 재지 않음 — 아래 "그늘" 판단은 그 가정 위.

| 아이디어 | 추가 요청 | 추가 시간 | 자원 | 그늘 아래인가 |
|---|---|---|---|---|
| A 라벨이 본문을 가르침 | 0 (라벨 번역 재사용) | 장면의 첫 본문 줄만 라벨 완료를 기다림: ll 25–70 ms, hf 0.8–1.3 s, 한 번 | CPU 문자열 처리 µs, 번역 엔진은 이미 쓰던 만큼 | 첫 줄은 아니고 2번째 줄부터 0 |
| B 클릭 교정 / 제안 | 0 | 제안 계산은 문자열 작업만 (줄 800개 상한) | CPU | 해당 |
| C FM 문맥 줄 | 0 | 줄당 prefill 약 +100–150 토큰 (코드 주석: "decode speed is the bottleneck") | FM | 디코드가 지배하므로 작을 것으로 예측, 미측정 |
| D FM 이름 추출 | 새 장면당 1 (hf급) | 0.8–1.3 s | FM, ANE 경합 가능 | 첫 프레임의 임계 경로 밖(다음 줄부터 적용)에 두면 0 |
| E customWords | 0 | 0 | 없음 | 해당 |

흐름을 바꿔야 하나: 이름 추출을 "요청을 더 보내서" 하는 길(D, 원문 단독 조회)은 비싸고, "이미 보낸 요청의 결과를 재사용"하는 길(A)은 공짜다. 먼저 A(비동기·재사용), 그다음 B(사용자가 확정), D는 최후.

## 5. 순위 (이득 / 비용)

1. **B 중 "제안" 부분 = 이미 있는 GlossarySuggester를 화면에 연결** (비용 작음~중, 위험 낮음). 사용자가 확정하므로 오탐 부담 0, 사용자 원칙("기본은 단순, 깊이는 찾을 때") 부합. 번역된 줄이 쌓인 뒤 "이름이 3가지로 나왔어요" 한 번 뜸. 이득의 크기는 아래 측정 1의 inconsistent 비율에 달림.
2. **A 라벨이 본문을 가르침** (비용 중, 위험 중). 설정 없이 기본으로 켜지고 새 요청이 없음. ja VN과 채팅에서 가장 눈에 띄는 불일치를 줄임. 단 소수의 흔한 단어 라벨에서 오삽입 위험 → 이름 상자 분류와 Title Case/미등록 단어로 제한.
3. **B 중 "원문 단어 클릭 교정"** (비용 중, UI 위험). 용어집을 직접 쓰는 일을 대체. 1번 뒤에 같은 말풍선을 공유하면 비용이 줄어듦.
4. **C FM 문맥 줄 + 핀 목록** (비용 작음, 이득은 선택 엔진 사용자에게만). 기본 엔진 사용자에게는 0이므로 4위.
5. **E customWords에 핀 추가** (비용 거의 0, 이득 미측정) — 1, 2가 들어가면 덤으로 묶음. D는 A가 모자란다고 판명될 때까지 보류 (ANE 경합 위험).

용어집은 남김: N3(음역/그대로 둠 취향)과 N4(게임 고유 용어)는 사용자만 아는 정보.

## 6. 기존 벤치로 싸게 재는 법

기존 `tools/usecase-bench`(40장 OCR 문단 읽기 점수, 번역 아님)와 `tools/engine-bench`는 장면 하나가 정적이라 "이름이 여러 줄에 반복되는 세션"이 없음 → 이름 반복 줄을 만드는 텍스트 전용 세트를 한 번 추가해야 함.
이미 있는 도구만 씀: 문장 소스는 `tools/usecase-bench/set/{g01..g08,c01..c05,s01..s09}.expected.txt`에서 뽑고, 번역은 `tools/apple-translation-probe/batch.swift`(앱과 같은 plain 배치) 경로, 판정은 `GlossarySuggester.suggestions(existing: [], limit: 99)`의 inconsistent/leftUntranslated 개수.

**측정 1 (결정을 가르는 한 항): 필요의 크기 = 기본 경로에서 이름이 줄마다 갈라지는 비율**
- 세트: 4개 이야기(ja VN, en RPG, zh 채팅, en 채팅) × 12줄, 이름 4개씩 각 5회 이상(이름 상자 1회 포함). 새로 쓰는 약 50줄.
- 실행: 번역 엔진 ll·hf 각각 plain 배치. 렌더 불필요, OCR 불필요, 텍스트만.
- 예측(실행 전 기록): 이름이 5회 나올 때 렌더링이 2가지 이상으로 갈라질 비율은 ll 15–50 %, hf 10–40 %.
  근거는 약함(Suggester를 만든 이유가 관찰이었다는 것 외에 숫자가 레포에 없음). 이 항이 유일하게 도출로 못 닫는 값.
- 다음 행동: 10 % 미만이면 이 방향은 가치가 낮으니 용어집 + 제안만 유지하고 A는 접음. 30 % 이상이면 A 먼저. 그 사이면 1번(제안)만.

**측정 2 (A의 효과): 같은 세트에 라벨 핀 사전 삽입을 적용**
- 변수: 핀 없음 vs 라벨 핀 vs (상한) 정답 핀. 지표: 이름당 서로 다른 렌더링 수, 이름이 정확히 핀과 같은 비율, 깨진 줄(반복 음절, 빠진 단어) 수, 요청당 ms.
- 예측: 라벨 핀에서 inconsistent 0–10 %, 깨짐 ≤ 1/20 (레포 게이트와 같은 문턱), 요청 수 동일, 첫 본문 줄 지연 +1 요청.
- 다음 행동: 정답 핀과 라벨 핀의 차이가 5 %p 넘으면 라벨 분류가 문제 → 분류 규칙 손봄. 라벨 핀이 정답 핀과 같으면 켬.

**측정 3 (오삽입 위험): 40장 벤치의 짧은 블록 중 다른 블록 안에서 다시 나오는 것과 그 중 흔한 단어 비율**
- 순수 텍스트 산술(엔진 없음), `set/*.expected.txt`만으로 계산. 핀 규칙(이름 상자 / Title Case / 미등록)의 정밀도를 사람이 한 번 훑어 확인.

**측정 4 (E, 값쌈): usecase-bench를 이름 목록 customWords로 한 번 더**
- `bench.sh`에는 `--glossary` 훅이 없음 (SelfTest의 `--render --glossary`는 있음). 환경변수 한 줄 추가가 필요. g01–g08의 이름 단위 점수 차이. 예측 0 (지어낸 이름이 교정으로 바뀌는 경우가 드묾). 0이면 E는 접음.

**측정 5 (C, FM 엔진 사용자만)**: `tools/engine-bench`의 data.json 줄에 이전 2줄 문맥을 붙인 변형과 비교, `judge.py` 판정. 예측: 이름/대명사 일관성 소폭 향상, 지연 증가는 prefill 몫이라 hf 1 s 대에서 눈에 띄지 않는 수준.

## 7. 레포 밖 개선 지점 (보고만, 손대지 않음)

- `Core/Sources/MwoyeoCore/GlossarySuggester.swift` 전체(440줄) + `Core/Tests/MwoyeoCoreTests/GlossarySuggesterTests.swift`: App에서 부르는 곳이 없음. 연결하거나, 쓰지 않을 거면 삭제. 크기: 연결은 UI 포함 중, 삭제는 작음.
- `Core/Sources/MwoyeoCore/GlossarySuggester.swift:238-247`: nameType 태거를 모든 언어에 만듦. 이 Mac에서는 en 외에 NameType이 없어 영어 외에서는 매번 빈 결과(비용은 작음). 언어가 en일 때만 만들도록 한정 가능. 크기: 작음 (확인 필요 — 에셋이 있는 Mac에서는 다를 수 있음).
- `tools/usecase-bench/bench.sh`: `--glossary`를 넘길 환경변수가 없음 (측정 4). 크기: 작음.
- `App/Pipeline/TranslationService.swift:910`: FM 지침이 "Keep numbers, units, names, product names ... unchanged"라 FM 엔진은 용어집에 없는 이름을 음역하지 않고 원문 그대로 둠(N3에서 "그대로 둠"으로 고정). 한국어 목표에서 이게 의도인지 확인 필요. 크기: 작음(지침 한 줄, 선택 사항).
- `docs/research/` : 이 문서의 표 5(다른 곳은 어떻게 하나)와 6(측정 설계)을 paper-translation.md처럼 남길지는 리드가 정함.

모델: Claude Sonnet 5.5 (claude-sonnet-5-5), 라운드 에이전트.
