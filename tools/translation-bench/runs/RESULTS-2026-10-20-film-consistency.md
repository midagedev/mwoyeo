# Does an app's memory visibly fix inconsistent translation? The film's evidence (2026-10-20, round film2-measure)

Written once, by hand, from the preserved runs named below (all under `runs/`, `film-*`). The table is `film_consistency.py`
(`python3 -I film_consistency.py runs/film-*`), the probe numbers are `score.py`'s `check_probe`, `runs/SUMMARY.md` has the same
figures. Nothing in the app changed. The runs are `--layout t2`: the bytes `RequestLayout.body` gives. No default is decided here.

## What was run

**The scene.** `sequences/film-ja-ko-1.json` and `memory/film-ja-ko-1.json` (ours, no third-party text): a fantasy RPG scene,
ja -> ko, kind `game`, 36 lines in 27 screens of 1-3 lines, four characters.
- Names whose Korean spelling is open without a memory: 九十九 (つくも, said in 8 lines), シュザンヌ (8 lines), エルヴェ (5), ハク (4).
- Invented terms: 月影の祠 (6 lines), 月涙石 (6), 夜明けの守り手 (5). Their memory renderings are 월영 사당, 월루석, 새벽지기.
- Speech levels only the memory decides: the princess シュザンヌ speaks 반말 to the swordsman 九十九 and 해요체 to the old tutor エルヴェ;
  九十九 speaks 합쇼체 to her and 해요체 to エルヴェ; エルヴェ speaks 합쇼체 to her and 반말 to 九十九. ハク has no level.
- 41 probes: 14 name, 14 term, 13 speech_level; 39 `by: memory`, 2 `by: none` controls (石段, 錆びた門). The memory renders to 149
  estimated tokens (limit 150). `validate.py --only film-ja-ko-1`: 0 errors, 0 warnings.

**The condition.** The product's request when an app profile has memory and the engine's context is off is "memory only"
(`ContextOptions(enabled: true, transcriptCount: 0, memoryOnly: true)`, `EngineContext.swift:86`): the card (app name, category word),
the note, the rows whose name occurs in the lines, no neighbours, no earlier lines. The bench has no condition that sets
`memoryOnly` (`Conditions.swift:196` builds the options with `ContextOptions.from(engine:)`, which never does). The closest is
**`M0 --layout t2`**: card, note and rows with `previousLines: 0`. Its difference from the product: `memoryOnly` also withholds the
window title from an on-device engine, and `M0` sends it. This memory has no window title, so nothing differs. Checked by running
both option sets through `RequestLayout.body` with this scene's rows (scratch program, below): the bytes are identical for the
Ollama kind and for the Anthropic kind with no title or a title equal to the app name; they differ only for a local engine
with a title other than the app name (1498 against 1467 bytes). The request the model got (captured on a mock server) is the rules,
`Document: 月涙譚 (games).`, `User's note for this app: fantasy RPG; shrine quest`, and in the last message only the rows whose names are in
the item, e.g. `{"memory":["シュザンヌ -> 쉬잔 (person, f; princess; to エルヴェ: polite; to 九十九: casual)"],"translate":[...]}`.
**`A`** is today's request (no card, no note, no rows).

Two controls the round did not ask for, both cheap: **`B0 --layout t2`** is the product request shape with the card and no note,
rows or lines (it separates the memory from the request format: `gemma4:e4b` echoes its source under A, and under the t2 shape it does
not); a second Haiku `M0` run (the cloud engine is not deterministic at temperature 0, so one `M0` run cannot say whether its slips repeat).

| engine | A | A repeat | B0 (control) | M0 |
|:---|:---|:---|:---|:---|
| gemma3:4b (Ollama) | `film-A-gemma3-4b` | `-r2` | `film-B0-gemma3-4b-t2` | `film-M0-gemma3-4b-t2` |
| gemma4:e4b (Ollama) | `film-A-gemma4-e4b` | `-r2` | `film-B0-gemma4-e4b-t2` | `film-M0-gemma4-e4b-t2` |
| claude-haiku-5-5 | `film-A-haiku-5-5` | `-r2` | `film-B0-haiku-5-5-t2` | `film-M0-haiku-5-5-t2`, `-r2` |

One sequence per run (`--seq film-ja-ko-1`), 27 requests, `--jobs 1`, batches of at most 3. The Mac was shared with other sessions all
the time (load average 135 to 230, swap 21 GB used; each manifest note has the numbers): latency is not a result here, temperature-0
quality is not affected. `ANTHROPIC_API_KEY` was set; no key is printed or stored.

## The table

Distinct Korean renderings of each name/term over the lines that carry it (1 = consistent), then the summary columns.

| run | engine | cond | 九十九 | シュザンヌ | エルヴェ | ハク | 月影の祠 | 月涙石 | 夜明けの守り手 | names 1-form | terms 1-form | canonical | speech | echo/kana | probes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| film-A-gemma3-4b | ollama-gemma3-4b | A | 7 | 2 | 3 | 2 | 5 | 4 | 1 | 0/4 | 1/3 | 0/7 | 6/13 | 0/3 of 36 | 11/41 (27%) |
| film-A-gemma3-4b-r2 | ollama-gemma3-4b | A | 7 | 2 | 3 | 2 | 5 | 4 | 1 | 0/4 | 1/3 | 0/7 | 6/13 | 0/3 of 36 | 11/41 (27%) |
| film-B0-gemma3-4b-t2 | ollama-gemma3-4b | B0 | 6 | 3 | 3 | 3 | 5 | 4 | 2 | 0/4 | 0/3 | 0/7 | 8/13 | 0/4 of 36 | 11/41 (27%) |
| film-M0-gemma3-4b-t2 | ollama-gemma3-4b | M0 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 4/4 | 3/3 | 7/7 | 8/13 | 0/3 of 36 | 36/41 (88%) |
| film-A-gemma4-e4b | ollama-gemma4-e4b | A | 2 | 1 | 1 | 1 | 1 | 1 | 1 | 3/4 | 3/3 | 0/7 | 0/13 | 31/36 of 36 | 0/41 (0%) |
| film-A-gemma4-e4b-r2 | ollama-gemma4-e4b | A | 2 | 1 | 1 | 1 | 1 | 1 | 1 | 3/4 | 3/3 | 0/7 | 0/13 | 31/36 of 36 | 0/41 (0%) |
| film-B0-gemma4-e4b-t2 | ollama-gemma4-e4b | B0 | 2 | 1 | 2 | 1 | 1 | 4 | 1 | 2/4 | 2/3 | 1/7 | 9/13 | 0/0 of 36 | 16/41 (39%) |
| film-M0-gemma4-e4b-t2 | ollama-gemma4-e4b | M0 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 4/4 | 3/3 | 7/7 | 9/13 | 0/0 of 36 | 37/41 (90%) |
| film-A-haiku-5-5 | anthropic-haiku-5-5 | A | 3 | 2 | 2 | 1 | 4 | 1 | 2 | 1/4 | 1/3 | 2/7 | 8/13 | 2/4 of 36 | 19/41 (46%) |
| film-A-haiku-5-5-r2 | anthropic-haiku-5-5 | A | 4 | 2 | 2 | 1 | 4 | 1 | 1 | 1/4 | 2/3 | 2/7 | 10/13 | 0/0 of 36 | 22/41 (54%) |
| film-B0-haiku-5-5-t2 | anthropic-haiku-5-5 | B0 | 4 | 2 | 3 | 2 | 4 | 1 | 1 | 0/4 | 2/3 | 1/7 | 9/13 | 2/6 of 36 | 18/41 (44%) |
| film-M0-haiku-5-5-t2 | anthropic-haiku-5-5 | M0 | 2 | 2 | 1 | 1 | 1 | 1 | 1 | 2/4 | 3/3 | 5/7 | 7/13 | 0/0 of 36 | 34/41 (83%) |
| film-M0-haiku-5-5-t2-r2 | anthropic-haiku-5-5 | M0 | 1 | 2 | 1 | 1 | 1 | 1 | 1 | 3/4 | 3/3 | 6/7 | 11/13 | 0/0 of 36 | 37/41 (90%) |

- names / terms 1-form: keys with one rendering. *canonical*: keys whose every line carries the memory's form (7 keys). *speech*: the 13
  speech-level probes passed. *echo/kana*: lines copied back untranslated (score.py `is_echo`) / lines that still hold a kana.
- A key with one rendering is "consistent" even when it is the wrong one: `gemma4:e4b` A is "consistent" because it copies the
  Japanese back (31 of 36 lines), which is why *canonical* (0/7) and the echo column sit beside it.
- **How a rendering is found** (`film_consistency.py`): (1) a known form: the memory's `dst`, the `any` / `none` strings and the
  `bad_sub` replacement of the probes of the key, and the source string itself; the longest found wins ("쉬잔느" over "쉬잔"), spaces are
  ignored, every accepted form counts as the `dst`; (2) otherwise the output characters opposite the `dst` in the line's hand-written
  `ref` (difflib alignment), and a longer aligned string that contains a shorter one counts as the shorter; a span that cannot be
  aligned is `(unaligned)`. **The counts are lower bounds of what a Korean reader sees**: a listed wrong form stands for every
  spelling that contains it (슈잔느 and 슈잔누 are both "슈잔"), and `(unaligned)` lines count once. `--detail` lists every rendering.

## The A repeat

`film_consistency.py --repeat A A-r2` (temperature 0, same requests):

| engine | identical output lines | same probe verdicts | keys with the same renderings |
|:---|:---|:---|:---|
| gemma3:4b | 36/36 | 41/41 | 7/7 |
| gemma4:e4b | 36/36 | 41/41 | 7/7 |
| claude-haiku-5-5 | 14/36 | 38/41 | 4/7 |
| claude-haiku-5-5, M0 vs M0-r2 | 10/36 | 34/41 | 6/7 |

The local engines are deterministic: the inconsistency of gemma3:4b is stable, not noise, and it can be shown again byte for byte.
Haiku is not: the two A runs differ in 22 of 36 lines and probe accuracy moves 46% -> 54% (3 probes), but the kinds of drift repeat
(九十九 as 츠쿠모 / 구십구 / 구구 / 구쥬구 or the kanji, 月影の祠 as 4 different things in each run, エルヴェ as 엘베 / 에르베, the princess as 수잔 / 슈잔).
The two M0 runs of Haiku both land at 83-90%, with a slip or two in different lines.

## Reading it

| engine | A | B0 | M0 | what the memory does |
|:---|:---|:---|:---|:---|
| gemma3:4b | 27%, 0/7 canonical | 27% | **88%, 7/7 canonical** | +61 points; 7 renderings of 九十九 become one; line 19 of A is romanised Japanese, not a translation |
| gemma4:e4b | 0% (copies 31 of 36 lines back) | 39%, 1/7 canonical | **90%, 7/7 canonical** | +51 over B0; against A the memory also cures the echo, which the t2 request shape does by itself |
| claude-haiku-5-5 | 46% / 54%, 2/7 canonical | 44% | **83% / 90%, 5/7 and 6/7 canonical** | +15 probes of 41 in each pair of runs (+37 points); names 1/4 -> 2/4 and 3/4 consistent; terms 1-2/3 -> 3/3 |

- **Names and terms: a large effect on all three.** Without the memory the names come out in more than one rendering for 4 of 4 keys
  (gemma3 A), 2 of 4 (gemma4:e4b B0) and 3 of 4 (Haiku A, both runs); the memory makes the local engines 7/7 and Haiku 5/7 and 6/7 keys
  carry only the memory's form.
- **Speech level: no effect to speak of.** 13 probes: gemma3 6 -> 8, gemma4:e4b 9 -> 9 (B0 -> M0), Haiku 8 / 10 -> 7 / 11. The reason is the
  request, not the engine: the app sends no speaker, a row says how the *named* person speaks to others, and the line of the princess
  to her tutor names the tutor (エルヴェ、大丈夫よ): the tutor's row, not hers, goes along. Her lines to エルヴェ (5, 16) fail in every
  gemma run, M0 included (0/2), and in Haiku M0 (1/2 and 1/2); only Haiku A r2 passes both without a memory. The Japanese text already
  carries most of the register (わ, よ, です, ください): the princess to 九十九 is 반말 in 7/7 lines even in `gemma4:e4b` B0. The film
  cannot claim the princess register is fixed by this memory; the names and terms it can.
- **Side effect worth knowing.** Haiku M0 turns the row note "princess" into the title 공주님: `쉬잔 공주님` stands where the source says 様
  (lines 4, 30, 34 in the first M0 run; lines 4, 27 in the second); the memory's form is right, the added title is not in the source.
- **Residual misses under M0**: Haiku M0 run 1 writes 구줴 for 九十九 once (line 12) and 슈잔누 for シュザンヌ once (line 11); run 2 writes
  슈잔느 once (line 23). gemma3 M0 still leaves Japanese in 3 lines (9, 30, 33; A leaves it in 19, 20, 25), and its translations are not
  fluent in places (`월루석이 파랗게 맥打고`, `쉬잔ヌ 님`).

**Which engine shows the largest real effect.** *Largest*: gemma3:4b (+61 points, 0/7 -> 7/7 canonical), repeatable byte for byte. *Real*,
meaning a believable translation before and after: **claude-haiku-5-5**. Its A is fluent Korean with visible drift, which is the
film's story: 九十九 / 구십구 / the kanji and 슈잔 / 수잔 for the same people, 月影の祠 as 월영 사당 / 월영의 사당 / 요미사당 / 月影の祠 left
untranslated, 새벽의 수호자 / 새벽을 지키는 자; the memory fixes 5 to 6 of 7 keys and 34-37 of 41 probes. gemma3:4b's A is
partly nonsense (line 19), which reads as a broken engine more than as inconsistency. `gemma4:e4b`'s A is an echo (closed finding, README
"Model findings"): its true "before" for the film is B0, which is not a state the app has. One thing the scene does not do for Haiku:
月涙石 -> 월루석 is already its own rendering in all 6 lines (the Sino-Korean reading of the kanji equals the memory's form), so that
term cannot show drift on a strong engine; 月影の祠 and 夜明けの守り手 do.

## Five lines per engine (source -> A -> memory)

Line ids are `film-ja-ko-1` ids; every output is the stored reply, unedited (`runs/<run>/film-ja-ko-1.json`).

**gemma3:4b** (A `film-A-gemma3-4b`, M0 `film-M0-gemma3-4b-t2`)

| id | source | A | M0 |
|:---|:---|:---|:---|
| 2 | 九十九、ここが月影の祠よ。間違いないわ | 구루나, 여기가 월계의 신사야. 틀림없어. | 츠쿠모, 여기가 월영 사당이야. 틀림없어. |
| 14 | 月涙石を持つ者だけが、夜明けの守り手に会える。それが祠の掟じゃ | 달 눈물 돌을 가진 자만이, 새벽의 수호자에게 만날 수 있다. 그것이 사제의 규칙이다. | 월루석을 가진 자만이 새벽지기에게 바랠 수 있다. 그것이 신전의 규칙이다. |
| 19 | 月涙石は月影の祠の奥、水鏡の底に沈んでおる。取ってこられるかな | 츠키노노-いし는 쿠레ミカゲ노-미타노 우쿠, 미즈카구로노 소シニ 스ირ데오루. 토롯테코라레루카나 | 월루석은 월영 사당의 깊숙한 곳, 물결 거울 바닥에 잠겨 있더라. 가져올 수 있을까 |
| 22 | 九十九、私が行くわ。この月影の祠は私の家の先祖が建てたのよ | 큐지 99, 내가 가. 이 월계의 신사는 내 집의 조상이 지은 거야. | 츠쿠모, 내가 간다. 이 월영 사당은 내 집 조상이 지은 곳이야. |
| 34 | 九十九、よく無事でいたな。シュザンヌ様を頼んだぞ | 큐큐부, 잘 지냈구나. 슈자누 님을 부탁했어. | 츠쿠모, 잘 지냈구나. 쉬잔님께 부탁했어. |

**gemma4:e4b** (before = the control `film-B0-gemma4-e4b-t2`, because its A copies the Japanese back: line 2 of A is the source line unchanged;
M0 `film-M0-gemma4-e4b-t2`)

| id | source | B0 | M0 |
|:---|:---|:---|:---|
| 2 | 九十九、ここが月影の祠よ。間違いないわ | 쿠쿠, 여기가 달 그림자 신사야. 틀림없어 | 츠쿠모, 여기가 월영 사당이야. 틀림없어 |
| 14 | 月涙石を持つ者だけが、夜明けの守り手に会える。それが祠の掟じゃ | 월루이시를 가진 자만이 새벽의 수호자를 만날 수 있다. 그것이 사당의 율법이다 | 월루석을 가진 자만이 새벽지기를 만날 수 있다. 그것이 사당의 율법이다 |
| 19 | 月涙石は月影の祠の奥、水鏡の底に沈んでおる。取ってこられるかな | 월루이시는 달 그림자 신사의 깊은 곳, 물 거울 바닥에 가라앉아 있다. 꺼낼 수 있을까 | 월루석은 월영 사당 깊숙한 곳, 수경 바닥에 가라앉아 있다. 꺼낼 수 있을까 |
| 29 | 水の底で、月涙石が青く脈打っていた。 | 물 밑에서, 달눈물석이 푸르게 고동치고 있었다. | 물 밑에서, 월루석이 푸르게 맥동하고 있었다. |
| 34 | 九十九、よく無事でいたな。シュザンヌ様を頼んだぞ | 쿠쿠, 무사히 잘 지냈구나. 슈잔느 님을 부탁할게 | 츠쿠모, 무사히 잘 지냈구나. 쉬잔 님을 부탁하마. |

(Lines 14, 19 and 29 of B0 give the one stone as 월루이시 / 월루이시 / 달눈물석.)

**claude-haiku-5-5** (A `film-A-haiku-5-5`, M0 `film-M0-haiku-5-5-t2`)

| id | source | A | M0 |
|:---|:---|:---|:---|
| 6 | エルヴェさん、肩をお貸ししますよ | 엘베 씨, 어깨를 빌려 드릴게요 | 에르베 씨, 어깨를 빌려 드리겠습니다. |
| 15 | 夜明けの守り手の話は、古い書物で読んだ覚えがございます | 새벽을 지키는 자의 이야기는 오래된 책에서 읽은 기억이 있습니다 | 새벽지기 이야기는 오래된 책에서 읽은 기억이 있습니다 |
| 22 | 九十九、私が行くわ。この月影の祠は私の家の先祖が建てたのよ | 구십구, 제가 가겠어요. 이 츠쿠요미 사당은 저희 집안 조상이 세운 거예요. | 츠쿠모, 내가 갈게. 이 월영 사당은 우리 집안 선조가 세운 거야. |
| 32 | 石が光を放ち、月影の祠全体が低く震え出した。 | 돌이 빛을 내뿜자, 월영사(月影の祠) 전체가 낮게 떨리기 시작했다. | 돌이 빛을 내뿜자, 월영 사당 전체가 낮게 떨리기 시작했다. |
| 34 | 九十九、よく無事でいたな。シュザンヌ様を頼んだぞ | 구십구, 용케 무사했구나. 슈잔느 님을 부탁하마. | 츠쿠모, 용케 무사했구나. 쉬잔 공주님을 부탁한다. |

(Line 22 of A also shows the princess speaking 존댓말 to the swordsman: `제가 가겠어요 / 저희 집안`; M0 has the 반말 of the memory, and the same line in
both M0 runs. Line 15 against line 14 of the same A run: 새벽의 수호자 in 14 and 17, 새벽을 지키는 자 in 15. Line 34 of M0 carries the added 공주님.)

## Frictions and limits

- No bench condition for the product's memory-only request (`Conditions.swift:196`); `M0 --layout t2` is the closest, byte-identical for
  this memory. A `memoryOnly` condition would make the match structural, not argued (not added, per the spec).
- `matrix.sh` / `cloud.sh` / `runs.py add` take `--seq` but store the whole corpus as the run's snapshot (`runs/_corpus/9c326ccbb47568c5`,
  260 KB); the film runs sit in `SUMMARY.md` beside the full-corpus runs, whose header (`summary.py:150`, "312 planted probes in 14
  sequences") now describes only the first run. `README.md:296` ("the corpus has 312") is stale: the live corpus has 353 probes in 15 sequences.
- `tests/test_film_consistency.sh` is not in `tests/run-all.sh` (that file was not in the round's list).
- The extraction is a lower bound (above); a surface-form count would need a tokenizer for Korean particles.
- One scene, one sequence order, temperature 0: the numbers say what happens on this text, not how often.

## The byte-equality check (scratch, not in the repo)

`swift build` of a package depending on `Core` by path; it builds one `ContextRequest` (this scene's rows, card from `月涙譚` / `games`,
the note, line 13 as the item) and lays it out twice:

```swift
let m0 = ContextOptions.from(engine: EngineContext(enabled: true, previousLines: 0))   // what the bench's M0 builds
let product = ContextOptions(enabled: true, transcriptCount: 0, memoryOnly: true)       // EngineContext.memoryOnlyOptions
let a = RequestLayout.body(kind: kind, request: req, options: m0)
let b = RequestLayout.body(kind: kind, request: req, options: product)
```

Output: `ollama / no window title: M0 bytes 1467, memory-only bytes 1467, identical true`; `anthropic / no window title: 1544, 1544, true`;
`ollama / title = app name: 1467, 1467, true`; `anthropic / title = app name: 1544, 1544, true`;
`ollama / another title: 1498, 1467, false`; `anthropic / another title: 1544, 1544, true`.
