# Mwoyeo privacy policy

Last updated: 2026-10-28

Mwoyeo translates the text you put a lens over. It is made by one developer (midagedev). It has no account, no server
and no analytics.

## Screen Recording

Mwoyeo asks for macOS Screen Recording permission. It uses it for these features, and for nothing else:

- **Lenses.** A lens captures only the area it covers, while it is open, to read the text there and draw the translation
  over it. Placing, moving and fitting a lens read the same area.
- **The whole screen while held (⌃⌥P).** While you hold the shortcut, Mwoyeo takes one picture of the display under the
  pointer, reads and translates its text, and draws the translation over it. When you let go, it is gone.
- **Windows.** Mwoyeo reads where windows are, so a lens stays on its window. It reads the title of the window under a
  lens only when you turn on context for a translation engine.

What it collects: the pixels of those areas and the text that Apple Vision finds in them, on your Mac. It records no
video and no sound.

Why: only to show the translation over the text. Screen recording data is not used for analytics, advertising, tracking,
profiling or training, and it is never sold.

Sharing: screen images never leave your Mac. In the Mac App Store version, nothing read from the screen leaves your Mac:
that version has no translation engine off this Mac. In the version from GitHub, the text (not the image) goes to a
translation engine off your Mac only if you add that engine and allow sending to its address (see below).

Storage and retention: screen images and the text read from them are kept in memory only, while Mwoyeo needs them to
show a translation, and are gone when the app quits at the latest. Nothing from the screen is written to disk,
unless you turn on saving transcripts or save a lens image yourself (see "What is saved to files").

## What stays on your Mac

- **Screen pixels.** The lens captures only the area it covers, with macOS Screen Recording permission. Frames are read
  in memory to find text and are never saved or sent, unless you save a lens image yourself.
- **Text read from the screen.** It is read on your Mac with Apple Vision. By default it is translated on your Mac with
  Apple Translation or Apple Foundation Models, so it never leaves the device.
- **Settings.** Languages, engines, per-app profiles (keyed by the app's bundle ID) and your names and terms are stored
  in the app's settings file and preferences on your Mac.
- **API keys** you enter are stored in the macOS Keychain.
- **Window titles.** When you turn on context for an engine, the app reads the title of the window under the lens. The
  title is kept in memory only.

## What leaves your Mac, and only when you choose it

- **Translation engines you add** (version from GitHub only; the Mac App Store version has no engine off this Mac). If
  you add an engine (for example an OpenAI-compatible server, DeepL or Anthropic),
  the text under the lens is sent to the address you entered for that engine, and nowhere else. If you turn on context
  for that engine, the lines before and after, the window title, and your note and terms for that app are sent too.
  That provider's own privacy policy applies to what it receives. An engine on your own Mac or network (such as Ollama)
  keeps the text on that machine.
  Before any text goes to an engine that is not on this Mac, Mwoyeo asks you to allow sending to that engine's
  address. Nothing is sent until you do, and a changed address asks again.
- **Language packs and Apple models** are downloaded by macOS, not by Mwoyeo.

## What is saved to files, and only when you choose it

- **Transcripts.** When you turn on saving translations to a file, the lines and their translations are written to the
  folder you pick, with the names and terms learned for each app. Nothing is written while this is off.
- **Lens images** are saved only when you save one.

## What Mwoyeo does not do

- No analytics, tracking, advertising or usage counting.
- No data is sold or shared.
- No account and no sign-in.

The Mac App Store version never checks for updates by itself; the App Store does that. The version downloaded from
GitHub checks GitHub for a new release once a day, and fetches a small file from GitHub once at install and once a
month to count installs. GitHub sees your IP address for those requests. Turning the automatic update check off in Settings stops both.

Crash reports reach the developer only if you allow macOS to share them with app developers.

## Deleting your data

- Settings: remove the app, or delete its settings file and preferences (the Mac App Store version keeps them in
  `~/Library/Containers/dev.midagedev.mwoyeo.appstore`).
- API keys: delete the engine in Mwoyeo, or remove the "Mwoyeo" items in Keychain Access.
- Transcripts and images: delete them from the folder you chose.

## Children

Mwoyeo is a general-purpose tool and is not directed at children.

## Contact

Questions: open an issue at https://github.com/midagedev/mwoyeo/issues or message https://x.com/midagedev.
Changes to this policy are recorded in this file's history.

---

# Mwoyeo 개인정보처리방침

최종 수정: 2026-10-28

Mwoyeo는 렌즈를 올린 곳의 글자를 번역하는 앱입니다. 개발자 한 명(midagedev)이 만듭니다. 계정, 서버, 분석 도구가 없습니다.

## 화면 기록

Mwoyeo는 macOS 화면 기록 권한을 요청합니다. 이 권한은 아래 기능에만 쓰고 다른 데에는 쓰지 않습니다.

- **렌즈.** 렌즈는 열려 있는 동안 자기가 덮은 영역만 캡처해 그 글자를 읽고 그 위에 번역을 그립니다. 렌즈를 놓고, 옮기고,
  맞출 때도 같은 영역을 읽습니다.
- **누르는 동안 화면 전체(⌃⌥P).** 단축키를 누르고 있는 동안 포인터가 있는 디스플레이를 한 번 찍어 글자를 읽고 번역해 그
  위에 그립니다. 손을 떼면 사라집니다.
- **창.** 렌즈가 자기 창을 따라가도록 창의 위치를 읽습니다. 렌즈 아래 창의 제목은 번역 엔진에 맥락 기능을 켰을 때만 읽습니다.

수집하는 것: 그 영역의 픽셀과, Apple Vision이 Mac에서 그 안에서 찾은 글자입니다. 영상과 소리는 기록하지 않습니다.

목적: 글자 위에 번역을 보여 주는 데만 씁니다. 화면 기록 데이터를 분석, 광고, 추적, 프로파일링, 학습에 쓰지 않고 팔지 않습니다.

공유: 화면 이미지는 Mac 밖으로 나가지 않습니다. Mac App Store판에서는 화면에서 읽은 어떤 것도 Mac 밖으로 나가지 않습니다.
이 판에는 이 Mac 밖의 번역 엔진이 없습니다. GitHub판에서는 이 Mac 밖의 엔진을 직접 추가하고 그 주소로 보내기를 허용한
경우에만 글자(이미지가 아님)가 그 엔진으로 갑니다(아래 참고).

보관과 보존 기간: 화면 이미지와 거기서 읽은 글자는 번역을 보여 주는 데 필요한 동안 메모리에만 두고, 늦어도 앱을 끝내면
사라집니다. 번역 기록 저장을 켜거나 렌즈 이미지를 직접 저장하지 않는 한 화면에서 온 것은 디스크에 쓰지 않습니다
("직접 고른 경우에만 파일로 저장되는 것" 참고).

## Mac 안에만 머무는 것

- **화면.** 렌즈는 macOS 화면 녹화 권한으로 자기가 덮은 영역만 캡처합니다. 화면은 메모리에서 글자를 찾는 데만 쓰고, 렌즈
  이미지를 직접 저장하지 않는 한 저장하거나 보내지 않습니다.
- **화면에서 읽은 글자.** Apple Vision으로 Mac에서 읽습니다. 기본값으로는 Apple 번역이나 Apple Foundation Models로 Mac
  안에서 번역하므로 기기를 벗어나지 않습니다.
- **설정.** 언어, 엔진, 앱별 프로필(앱의 bundle ID 기준), 직접 입력한 이름과 용어는 Mac의 설정 파일과 환경설정에 저장됩니다.
- **API 키**는 macOS 키체인에 저장됩니다.
- **창 제목.** 엔진에 맥락 기능을 켜면 렌즈 아래 창의 제목을 읽습니다. 제목은 메모리에만 둡니다.

## 직접 고른 경우에만 Mac 밖으로 나가는 것

- **직접 추가한 번역 엔진**(GitHub판만 해당합니다. Mac App Store판에는 이 Mac 밖의 엔진이 없습니다). 엔진(예: OpenAI 호환
  서버, DeepL, Anthropic)을 추가하면 렌즈 아래 글자는 그 엔진에 입력한
  주소로만 갑니다. 그 엔진에 맥락 기능을 켜면 앞뒤 줄, 창 제목, 그 앱에 적어 둔 메모와 용어도 함께 갑니다. 받은 쪽에는 그
  제공자의 개인정보처리방침이 적용됩니다. 내 Mac이나 내 네트워크의 엔진(Ollama 등)을 쓰면 글자는 그 기기에 머뭅니다.
  이 Mac 밖의 엔진으로 글자를 보내기 전에, Mwoyeo는 그 엔진의 주소로 보내도 되는지 먼저 묻습니다. 허용하기 전에는 아무것도
  보내지 않고, 주소가 바뀌면 다시 묻습니다.
- **언어팩과 Apple 모델**은 Mwoyeo가 아니라 macOS가 받습니다.

## 직접 고른 경우에만 파일로 저장되는 것

- **번역 기록.** 번역을 파일로 기록하기를 켜면 원문과 번역이, 앱마다 익힌 이름과 용어와 함께 고른 폴더에 저장됩니다. 꺼져
  있으면 아무것도 쓰지 않습니다.
- **렌즈 이미지**는 직접 저장할 때만 저장됩니다.

## 하지 않는 것

- 분석, 추적, 광고, 사용량 집계를 하지 않습니다.
- 데이터를 팔거나 공유하지 않습니다.
- 계정과 로그인이 없습니다.

Mac App Store판은 스스로 업데이트를 확인하지 않고 App Store가 맡습니다. GitHub에서 받은 판은 하루에 한 번 GitHub에서 새
버전을 확인하고, 설치 수를 세기 위해 설치 때 한 번과 매달 한 번 GitHub에서 작은 파일을 받습니다. 이때 GitHub는 IP 주소를
봅니다. 설정에서 자동 업데이트 확인을 끄면 둘 다 멈춥니다.

충돌 보고서는 macOS에서 앱 개발자와 공유하기를 허용한 경우에만 개발자에게 전달됩니다.

## 데이터 지우기

- 설정: 앱을 지우거나 설정 파일과 환경설정을 지웁니다(Mac App Store판은
  `~/Library/Containers/dev.midagedev.mwoyeo.appstore`에 있습니다).
- API 키: Mwoyeo에서 엔진을 지우거나 키체인 접근에서 "Mwoyeo" 항목을 지웁니다.
- 번역 기록과 이미지: 고른 폴더에서 지웁니다.

## 아동

Mwoyeo는 일반 도구이며 아동을 대상으로 하지 않습니다.

## 연락

문의는 https://github.com/midagedev/mwoyeo/issues 에 이슈를 열거나 https://x.com/midagedev 로 보내 주세요. 방침이
바뀌면 이 파일의 기록에 남습니다.
