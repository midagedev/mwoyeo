# App Store Connect metadata (first submission)

Bundle id `dev.midagedev.mwoyeo.appstore`. Limits are App Store Connect's: name and subtitle 30 characters, promotional
text 170, keywords 100, description 4000. `scripts/check-metadata.py` would be overkill for one submission; the counts below
were taken with `python3 -c 'print(len(s))'` when this file was written.

## Shared fields

| Field | Value |
|---|---|
| Primary category | Productivity |
| Secondary category | Utilities |
| Price | Free |
| Age rating | 4+ (no content of its own; it shows what is already on the screen) |
| Support URL | https://github.com/midagedev/mwoyeo/issues |
| Marketing URL | https://github.com/midagedev/mwoyeo |
| Privacy policy URL | https://github.com/midagedev/mwoyeo/blob/main/docs/PRIVACY.md |
| App Privacy | Data Not Collected (audit §2: no analytics, no update check in this build; text goes only to an engine the person adds) |
| Export compliance | `ITSAppUsesNonExemptEncryption = NO` (HTTPS only) |
| Copyright | 2026 Hyeoncheol Kim |

## 한국어

**이름** (19): `Mwoyeo – 화면 그 자리 번역`

**부제** (18): `렌즈 아래 글자를 제자리에서 번역`

**프로모션 텍스트** (93):
채팅, 게임, 영상 자막, 논문까지. 렌즈를 올려 두면 원문을 지우고 같은 자리에 같은 크기와 색으로 번역을 써요. 기본 설정에서는 모든 처리가 Mac 안에서 끝나요.

**키워드** (UTF-8 100 바이트 이내로 맞춤): `번역,화면번역,실시간번역,OCR,게임번역,자막,채팅,논문,일본어,번역기,렌즈`

**설명**:
화면 속 외국어를 그 자리에서 한국어로.

번역 팝업도, 화면 아래 자막 줄도 없어요. Mwoyeo는 렌즈 아래 글자를 읽어서 화면에서 지우고, 같은 자리에 같은 크기와 색으로 번역을 다시 써요. 그래서 원래 한국어로 된 화면을 보는 것처럼 읽혀요. 새 메시지가 올라오거나 페이지를 스크롤해도 번역이 따라와요.

렌즈 하나로
• 채팅과 피드: 새 메시지가 올라오는 대로 번역해요.
• 게임과 영상 자막: 무늬 배경이나 움직이는 장면 위의 글자도 읽어요.
• 논문과 문서: 두 단 논문은 단마다 제자리에 번역하고, 코드와 수식은 원문 그대로 둬요.
• 이미지: 이미지 파일을 끌어다 놓거나 붙여 넣으면 같은 방식으로 번역해요.

쓰는 법
• ⌃⌥L을 누르고 읽을 곳에 상자를 그리면 렌즈가 생겨요. 렌즈 안은 클릭이 그대로 통해서 평소처럼 스크롤하고 대화할 수 있어요.
• ⌃⌥O로 원문과 번역을 오가요.
• 창 렌즈는 그 창을 따라 움직이고, 화면 렌즈는 놓은 자리에서 아래에 오는 무엇이든 번역해요.
• 렌즈 메뉴에서 원문 복사, 번역 복사, 소리 내어 읽기, 렌즈 이미지 저장을 할 수 있어요.
• 키보드로 렌즈를 놓을 수 있고, 렌즈는 VoiceOver로 읽혀요. "동작 줄이기"를 켜면 움직임이 멈춰요.

개인정보
기본 설정에서는 Apple의 번역을 써서 모든 처리가 Mac 안에서 끝나고, 화면 내용은 어디에도 보내지 않아요. 분석 도구도 없어요. Ollama나 LM Studio 같은 이 Mac의 엔진, 또는 직접 키를 넣은 클라우드 엔진을 더할 수 있어요. 클라우드 엔진은 처음 보내기 전에 엔진과 주소마다 한 번 허락을 받고, 렌즈가 읽은 글자만 보내요. 화면 이미지는 보내지 않아요. 키는 macOS 키체인에만 저장해요.

필요한 것
• macOS 26 이상, Apple silicon(M1 이상)
• 화면 기록 권한(렌즈 아래 글자를 읽는 데 써요. 화면은 저장하지 않아요)
• 언어팩을 받으면 번역이 거의 바로 나오고 오프라인에서도 돼요.

## English

**Name** (27): `Mwoyeo – Translate in Place`

**Subtitle** (29): `Your screen, in your language`

**Promotional text** (169):
Chats, games, subtitles, papers. Put a lens over them and Mwoyeo erases the original and writes the translation in its place, same size and colour. On-device by default.

**Keywords**: `translate,translator,screen,OCR,overlay,live,game,subtitle,chat,paper,Japanese,Korean,Chinese,lens`

**Description**:
Foreign text on your screen, translated right where it is.

No pop-up, no subtitle bar. Mwoyeo reads the text under a lens, erases it from the screen and writes the translation in the same place, at the same size and colour. It reads as if the page had been in your language all along, and it keeps up as new messages arrive and as you scroll.

One lens for
• Chats and feeds: new messages are translated as they arrive.
• Games and video subtitles: text on patterned backgrounds and moving scenes.
• Papers and documents: two-column papers are translated column by column, in place; code and formulas stay as written.
• Images: drop or paste an image file and it is translated the same way.

How it works
• Press ⌃⌥L and drag a box over what you want to read. The inside of a lens is click-through, so you scroll and chat as usual.
• ⌃⌥O switches between the original and the translation.
• A window lens moves with its window; a screen lens stays put and translates whatever is under it.
• The lens menu copies the original or the translation, reads it aloud, or saves the lens as an image.
• Place a lens with the keyboard; VoiceOver reads it. With Reduce Motion on, it holds still.

Privacy
By default Mwoyeo uses Apple's translation, everything stays on your Mac, and nothing on your screen is sent anywhere. There are no analytics. You can add an engine on this Mac, such as Ollama or LM Studio, or a cloud engine with your own key. A cloud engine asks once per engine and host before anything is sent, and only the text a lens reads is sent, never a picture of your screen. Keys are stored only in the macOS Keychain.

Requirements
• macOS 26 or later, Apple silicon (M1 or later)
• Screen Recording permission (to read the text under a lens; nothing is recorded or saved)
• With a language pack, translation is near-instant and works offline.

## Notes for Review (English)

Mwoyeo translates text on the screen in place. It lives in the menu bar (viewfinder icon); there is no Dock icon.

To try it:
1. Open Mwoyeo. The welcome window asks for Screen Recording permission. Allow it in System Settings › Privacy &
   Security › Screen & System Audio Recording. If the lens stays empty after allowing, quit and reopen Mwoyeo once
   (macOS applies the permission to a running app only after a relaunch).
2. Open any page with English or Japanese text, for example a news site in Safari.
3. Press Control-Option-L and drag a box over the text. The text inside the box is replaced by its translation.
   Control-Option-O shows the original again.

Translation uses Apple's Translation framework on the device. If the language pack is not installed, Mwoyeo offers the
download in Settings › Translation; without it, Apple Intelligence translates when available (slower). No account, no
server of ours, no analytics. Screen frames are read in memory and never saved; saving transcripts and lens images is
off by default and goes to a folder the person picks.

Optional engines: a person may add an engine on the Mac (Ollama, LM Studio) or a cloud engine with their own API key.
Before text is first sent to a cloud host, the app asks for permission for that engine and host. Keys are kept in the
Keychain. Nothing is downloaded or executed; command-line engines of the GitHub build are not available in this build.
