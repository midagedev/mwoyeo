"""The scenes of H2 (h2.py draws them): what each screen shows, in the language of its prose. Everything is read from this repo at the pinned
commit (verified line by line), from the tool-output fixtures h2/src/*.txt (h2/capture.sh), or written for the scene (the Korean, Japanese and
English prose, the chat messages, the issue pages, the terminal sessions). No third-party text, no window of the user's; nothing from the
k-cases of tools/usecase-bench, the RESULTS files or CodeRegion.swift (addendum A1.2). The reason of every inline code is the author's: INLINE."""
import json, re
import h2
from h2 import CJK, INLINE, Line, Listing, PIN, fixture, lines_of, note_source, repo_text, verify


def C(lines, lang, caption=None, cmd=None):
    """A code block of a page or a chat message."""
    return ('code', Listing(lines, lang), caption, cmd)


def session(block):
    """A terminal session: `$ ` lines are commands; of the rest a line with CJK is either (program output in CJK, as the k05 notes treat it),
    any other is a log line; a trailing ⟦u⟧ marks a line uncertain."""
    ls = lines_of(block, 'term', 'log')
    for l in ls:
        if l.text.startswith('$ '): l.reason = 'cmd'
        elif CJK.search(l.text): l.opt = True
    return ls


def tool_lines(name, command, source_cmd, diff=False):
    """The lines of a tool-output fixture, after the command that printed them (shown as the prompt line)."""
    text = fixture(name)
    note_source(f'h2/src/{name}', 'tool-output', source_cmd, text)
    out = [Line('$ ' + command, 'cmd')]
    for raw in text.rstrip('\n').split('\n'):
        if diff:
            hdr = raw.startswith(('diff --git', 'index ', '--- ', '+++ ', '@@'))
            ln = lines_of(raw, 'py', 'diffmark' if hdr else 'code')[0]
            if hdr: ln.unc = False
            out.append(ln)
        else:
            ln = Line(raw.rstrip(), 'log')
            if CJK.search(raw): ln.opt = True
            out.append(ln)
    return out


# ------------------------------------------------------------------------------------------------------------------- Swift, Korean
BACKOFF = verify(lines_of('''
/// 실패할 때마다 대기 시간을 늘리는 재시도 정책. 읽기와 번역 경로의 모든 재시도가 이 타입 하나를 써요.
public struct Backoff: Sendable, Equatable {
    public let base: TimeInterval
    public let factor: Double
    public let cap: TimeInterval
    public let healthyWindow: TimeInterval?
    // 단계 목록을 직접 줄 수도 있어요. 목록이 끝나면 마지막 값을 되풀이해요.
    public let steps: [TimeInterval]?

    public private(set) var failures = 0
    // 마지막 실패의 대기가 끝나는 시각. 기다리는 중이 아니면 nil.
    public private(set) var until: TimeInterval?

    public init(base: TimeInterval, factor: Double = 2, cap: TimeInterval, healthyWindow: TimeInterval? = nil) {
        self.base = base
        self.factor = factor
        self.cap = cap  // 대기 시간의 상한
        self.healthyWindow = healthyWindow
        steps = nil
    }

    // failures번 실패한 뒤에 기다릴 시간
    public func wait(after failures: Int) -> TimeInterval {
        if let steps { return steps[min(max(failures, 0), steps.count - 1)] }
        return min(cap, base * pow(factor, Double(min(max(failures, 0), 10))))
    }
}
''', 'swift'), 'Core/Sources/MwoyeoCore/Backoff.swift', 'swift')
BACKOFF_WAIT = BACKOFF[-6:-1]

# ------------------------------------------------------------------------------------------------------------------ Swift, Japanese
DEADLINE = verify(lines_of('''
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var result: DeadlineResult<T>?
        var continuation: CheckedContinuation<DeadlineResult<T>, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func install(_ c: CheckedContinuation<DeadlineResult<T>, Never>) {
        // continuation ができる前に、呼び出し側がキャンセルされていることもある。
        let early = state.withLock { s -> DeadlineResult<T>? in
            if let r = s.result { return r }
            s.continuation = c
            return nil
        }
        if let early { c.resume(returning: early) }
    }

    func track(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let done = state.withLock { s -> Bool in
            if s.result != nil { return true }
            s.work = work
            s.timer = timer
            return false
        }
        // 結果がすでに決まっていたら、二つのタスクはすぐに止める。
        if done { work.cancel(); timer.cancel() }
    }
}
''', 'swift'), 'Core/Sources/MwoyeoCore/Deadline.swift', 'swift')

# ------------------------------------------------------------------------------------------------------------------ Swift, English
READWAIT = verify(lines_of('''
public enum RecognitionWait: String, Sendable, Equatable {
    /// No reader is ready yet, and one will be (a compile, a restart): "Preparing text recognition".
    case preparing
    /// The worker was stuck and its one recycle was stuck too: "Text recognition isn't responding".
    case notResponding
    /// The worker crash-looped and is switched off for this run: "Restart Mwoyeo".
    case restartApp
}

public struct ReadWait: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Nothing asked yet, or reset by a change of geometry or language.
        case idle
        /// A read returned.
        case showing
    }

    public private(set) var state = State.idle

    public init() {}
}
''', 'swift'), 'Core/Sources/MwoyeoCore/ReadWait.swift', 'swift')

# ------------------------------------------------------------------------------------------------------------------- shell, Korean
ANE = verify(lines_of('''
#!/bin/bash
# 컴파일러 서비스는 한 번에 네트워크 하나만 컴파일해요. 새 번들 ID의 첫 실행은 락을 잡고 줄을 서요.
set -u

ANE_ID_BASE=dev.midagedev.mwoyeo
ANE_LOCK=${ANE_LOCK:-$HOME/.cache/mwoyeo-gates/ane.lock}
ANE_POOL=4
# 디스크 여유가 8 GiB보다 적으면 컴파일을 시작하지 않아요.
ANE_FLOOR_KB=8388608
CACHE=com.apple.e5rt.e5bundlecache
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

slot() { echo "${ANE_SLOT:-$(( $(printf %s "$ROOT" | cksum | cut -d' ' -f1) % ANE_POOL + 1 ))}"; }
fresh() { echo "$(date +%s)$(uuidgen | cut -c1-4 | tr A-Z a-z)"; }

cmd_id() {
    local prefix suffix
    policy "$1"; read -r _ _ prefix suffix <<< "$KIND_ROW"
    echo "$ANE_ID_BASE.$prefix$($suffix)"
}

disk_ok() {   # 실행할 때마다 맨 처음에 한 번 확인한다
    local free=${FREE_KB:-$(df -k /System/Volumes/Data | awk 'NR == 2 {print $4}')}
    [ "$free" -ge "$ANE_FLOOR_KB" ] && return 0
    return 1
}
''', 'sh'), 'tools/ane-env.sh', 'sh')

# ------------------------------------------------------------------------------------------------------------------ shell, Japanese
CASK = verify(lines_of('''
#!/bin/zsh
# リリース用の Homebrew cask を出力する。使い方: scripts/cask.sh <バージョン> <dmg の sha256>
set -euo pipefail
cat <<CASK
cask "mwoyeo" do
  version "${1:?version}"
  sha256 "${2:?sha256}"

  url "https://github.com/midagedev/mwoyeo/releases/download/v#{version}/Mwoyeo-#{version}-arm64.dmg"
  name "Mwoyeo"
  desc "Live, in-place screen translation"  ⟦u⟧
  homepage "https://github.com/midagedev/mwoyeo"

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Mwoyeo.app"

  caveats <<~EOS
    Mwoyeo needs macOS 26 and Screen Recording permission (asked on first launch).  ⟦u⟧
    The first text recognition after launch can take up to a minute while the model loads.  ⟦u⟧
  EOS
end
CASK
''', 'sh'), 'scripts/cask.sh', 'sh')

# ------------------------------------------------------------------------------------------------------ tool outputs (fixtures)
GITLOG_CMD = "git log --format='%h %<(88,trunc)%s' --author=midagedev@gmail.com -n 12"
GITLOG_LINES = tool_lines('git-log.txt', GITLOG_CMD, f'git log {PIN} {GITLOG_CMD[8:]}')
DIFF_CMD = 'git diff ad2ad15~1 ad2ad15'
DIFF_LINES = tool_lines('git-diff.txt', DIFF_CMD, DIFF_CMD, diff=True)[1:]
TESTS = tool_lines('swift-test.txt', 'cd Core && swift test', 'cd Core && swift test --scratch-path <scratch>/core-build  (first 12 non-progress lines, last 8)')
XCODE = tool_lines('xcodebuild.txt', "cd Core && xcodebuild -scheme MwoyeoCore -destination 'platform=macOS' -derivedDataPath /tmp/dd build",
                   "cd Core && xcodebuild -scheme MwoyeoCore -destination 'platform=macOS' -derivedDataPath <scratch>/dd build  (first 28 non-blank lines, last 4)")

# ------------------------------------------------------------------------------------------------------------------------ JSON, YAML
SETTINGS_JSON = lines_of('''
{
  "targetLanguage": "ko",
  "savesTranscripts": true,
  "transcriptFormats": ["markdown", "srt", "jsonl"],
  "engines": [
    {
      "name": "ollama-gemma3-4b",
      "kind": "openAICompatible",
      "baseURL": "http://127.0.0.1:11434/v1",
      "model": "gemma3:4b",
      "thinking": "off",
      "price": "local",
      "note": "내 Mac에서 도는 모델이라 API 키가 필요 없어요"
    }
  ]
}
''', 'json', 'config')
_engine_text = repo_text('tools/translation-bench/engines/ollama-gemma3-4b.json')
note_source('tools/translation-bench/engines/ollama-gemma3-4b.json', 'repo-file', f'git show {PIN}:tools/translation-bench/engines/ollama-gemma3-4b.json', _engine_text)
_mine = json.loads('\n'.join(l.text for l in SETTINGS_JSON))['engines'][0]
_mine.pop('note')
if _mine != json.loads(_engine_text): raise SystemExit('h2: the engine entry of the JSON excerpt differs from tools/translation-bench/engines/ollama-gemma3-4b.json')

PROJECT_YML = verify(lines_of('''
name: Mwoyeo
options:
  bundleIdPrefix: dev.midagedev
  developmentLanguage: en
  deploymentTarget:
    macOS: "26.0"
  createIntermediateGroups: true
# MAS は同じターゲットの Mac App Store 版。Release に近く、Swift の条件 `MAS` とサンドボックスを持つ。
configs:
  Debug: debug
  Release: release
  MAS: release
configFiles:
  Debug: Config/Base.xcconfig
  Release: Config/Base.xcconfig
  MAS: Config/MAS.xcconfig
settings:
  base:
    # 署名の設定は xcconfig にある。ここに書くと xcconfig の設定より優先されてしまう。
    # アプリとサービスのバージョンは一つだけ。
    MARKETING_VERSION: "1.1.0"
    CURRENT_PROJECT_VERSION: "2"
packages:
  MwoyeoCore:
    path: Core
''', 'yaml', 'config'), 'project.yml', 'yaml')

# ---------------------------------------------------------------------------------------------------------------------------- sessions
SESSION_KO = session('''
$ cd ~/repo/mwoyeo-wt-k3a
$ date
2026년 10월 20일 화요일 08시 15분 12초 KST
$ git status
현재 브랜치: wt/k3a
커밋할 사항 없음, 작업 폴더 깨끗함
$ swift build -c release --product keeprules
Building for production...
[0/1] Planning build
Compiling MwoyeoCore Backoff.swift
Build complete! (53.58초)
$ tools/ane-env.sh id pool
dev.midagedev.mwoyeo.pool2
$ head -n 3 Core/Package.swift
// swift-tools-version: 6.2
import PackageDescription
''')
SESSION_JA = session('''
$ cd ~/repo/mwoyeo-wt-k3a
$ date
2026年10月20日 火曜日 08時15分12秒 JST
$ git status
ブランチ wt/k3a
コミットするものはありません、作業ツリーはきれいです
$ swift build -c release --product keeprules
Building for production...
[0/1] Planning build
Compiling MwoyeoCore Backoff.swift
Build complete! (53.58秒)
$ tools/ane-env.sh run pool -- ./ocrdump out.jsonl ja page.png
ane-lease: wait 0.0 s
ocrdump page: vn 14 blocks 31 lines, doc 12 paragraphs
ane-lease: held 6.4 s
''')
SETTINGS_CHECK = session('''
$ Mwoyeo --check-settings
settings.json:14: engines[0].thinking: "maybe" is not allowed; use one of off, provider; ignored
''')
ACK_LOG = session("""
$ xcodegen generate
$ xcodebuild -scheme Mwoyeo -destination 'platform=macOS' build
""")
SWIFT_BUILD_FAIL = session('swift build failed: /tmp/k3a/build/keeprules-build.log')
ISSUE_EN_LOG = session("""
$ /usr/bin/log stream --predicate 'subsystem == "dev.midagedev.mwoyeo"' --level info
ocr.recovered.vn3 after 4.1 s
""")
ISSUE_KO_LOG = session("""
$ Mwoyeo --check-settings settings.json
settings.json:13: engines[1].thinking: "maybe" is not allowed; use one of off, provider; ignored
""")
ISSUE_JA_LOG = session("""
$ tail -f ~/Documents/Mwoyeo/Transcripts/*.jsonl
tail: ~/Documents/Mwoyeo/Transcripts/*.jsonl: No such file or directory
""")

# -------------------------------------------------------------------------------------------------------------------------- README
JSONL_TAIL = [Line('tail -f ~/Documents/Mwoyeo/Transcripts/*.jsonl', 'cmd'),
              Line('# {"time":"2026-10-18T10:52:02.030+09:00","lens":"Chat","app":"com.example.app","source":"auto","target":"ko",'
                   '"engine":"apple","original":"こんにちは","translation":"안녕하세요"}', 'log', unc=True)]
JSONL_KEYS = lines_of('"savesTranscripts": true,\n"transcriptFormats": ["markdown", "srt", "jsonl"]', 'json', 'config')
README_KO_A = [
    ('h3', '단축키'),
    ('p', '어느 앱을 쓰고 있든 동작해요. 설정 › 단축키에서 바꾸고 싶은 단축키를 누른 다음 새 키를 입력하면 돼요. 지울 수도 있어요. 다른 앱이 이미 같은 키를 쓰고 있어도 {n:macOS}는 알려 주지 않아요.'),
    ('table', ['', ''], [['!hotkey|⌃⌥L', '렌즈 추가(드래그해서 영역 지정, 클릭하면 그 자리에 놓기, [[⌥]]를 누르고 있으면 화면에 고정)'],
                         ['!hotkey|⌃⌥O', '원문 보기 / 번역 보기'],
                         ['없음', '모든 렌즈 일시정지, 다시 번역(메뉴에 있어요. 필요하면 설정에서 키를 지정하세요)']]),
    ('h3', '렌즈 메뉴'),
    ('p', '렌즈 이름표를 오른쪽 클릭하면 그 렌즈에서 할 수 있는 일이 모여 있어요.'),
    ('ul', ['**원문 보기**, **원문 복사**, **번역 복사**: 렌즈 안 글자를 읽는 순서대로 복사해요.',
            '**소리 내어 읽기**: 번역을 시스템 음성으로 읽어 줘요. 그 언어 음성이 없으면 시스템 설정 › 손쉬운 사용 › 읽기 및 말하기에서 추가하세요.',
            '**렌즈 이미지 저장**: 번역이 올라간 렌즈 화면을 {n:PNG}로 저장해요.']),
]
README_KO_B = [
    ('h3', '설정 파일'),
    ('p', '모든 설정은 {n:JSON} 파일로도 있어서, 클릭하지 않고 직접(또는 {n:Claude Code}에게 시켜서) 바꿀 수 있어요. 파일 위치는 `~/Library/Application Support/Mwoyeo/settings.json`이고, `Mwoyeo --settings-path`로 확인하거나 설정 › 일반의 *열기* 버튼으로 열 수 있어요.'),
    ('ul', ['파일을 저장하면 1초 안에 바로 적용돼요. 설정 창과 파일은 늘 같은 내용이에요.',
            '`Mwoyeo --check-settings [경로]`는 문제가 없으면 `ok`를 출력해요. 문제가 있으면 하나에 한 줄씩 출력하고 종료 코드 1로 끝나요. 예: `settings.json:14: engines[0].thinking: "maybe" is not allowed; use one of off, provider; ignored`',
            '추가한 엔진의 {n:API} 키는 파일에 들어가지 않고 키체인에만 있어요.']),
    ('p', '**번역 로그.** `"savesTranscripts": true`로 두면 렌즈마다 읽은 원문과 번역을 `<exportFolder>/Transcripts`에 남겨요(기본은 {n:Markdown}과 {n:SRT}). `transcriptFormats`에 `"jsonl"`을 더하면 번역된 줄마다 {n:JSON} 한 줄씩, 생기는 즉시 덧붙여요.'),
    C(JSONL_KEYS, 'json'),
    C(JSONL_TAIL, 'sh'),
]
README_EN_A = [
    ('h3', 'Shortcuts'),
    ('p', "These work in any app. Change or remove them in Settings › Shortcuts: click a shortcut and press the new keys. {n:macOS} can't tell an app when another one already uses the same keys, so if a shortcut also does something elsewhere, record a different one."),
    ('table', ['', ''], [['!hotkey|⌃⌥L', 'Add a lens (drag an area, or click to drop one; hold [[⌥]] to pin it to the screen)'],
                         ['!hotkey|⌃⌥O', 'Show the original / the translation'],
                         ['none', 'Pause all lenses, Translate again (in the menu; give them keys in Settings if you like)']]),
    ('h3', 'Lens menu'),
    ('p', "Right-click a lens's name tag to find everything you can do with that lens."),
    ('ul', ['**Show Original**, **Copy Original Text**, **Copy Translation**: the two copy commands copy the text inside the lens in reading order.',
            '**Read Aloud**: speaks the translation with a system voice. If there is no voice for that language, add one in System Settings › Accessibility › Spoken Content.',
            '**Save Lens Image**: saves the lens as you see it, translation included, as a {n:PNG}.']),
]
README_EN_B = [
    ('h3', 'Settings file'),
    ('p', 'Every setting is also a {n:JSON} file, so you (or {n:Claude Code}) can change one without clicking: `Mwoyeo --settings-path` prints where it is (`~/Library/Application Support/Mwoyeo/settings.json`), and Settings › General has an *Open* button for it.'),
    ('ul', ['{n:Mwoyeo} watches the file and applies a saved change within a second; the Settings window and the file always agree.',
            '`Mwoyeo --check-settings [path]` prints `ok`, or one line per problem and exits 1: `settings.json:14: engines[0].thinking: "maybe" is not allowed; use one of off, provider; ignored`.',
            '{n:API} keys for added engines are never in the file; they stay in the {n:Keychain}.']),
    ('p', '**Translation log.** Set `"savesTranscripts": true` to have every lens write what it read and its translation to `<exportFolder>/Transcripts` ({n:Markdown} and {n:SRT} by default). Add `"jsonl"` to `transcriptFormats` for one {n:JSON} line per translated line, appended as it happens:'),
    C(JSONL_KEYS, 'json'),
    C(JSONL_TAIL, 'sh'),
]
README_JA_A = [
    ('h3', 'ショートカット'),
    ('p', 'ショートカットはどのアプリを使っていても有効です。設定 › ショートカットで変更や削除ができ、ショートカットをクリックして新しいキーを押すと記録されます。ほかのアプリがすでに同じキーを使っていても、{n:macOS}にはそれをアプリへ知らせる仕組みがありません。'),
    ('table', ['', ''], [['!hotkey|⌃⌥L', 'レンズを追加（範囲をドラッグするか、クリックして配置。[[⌥]]を押しながらで画面に固定）'],
                         ['!hotkey|⌃⌥O', '原文と訳文の表示を切り替え'],
                         ['なし', 'すべてのレンズを一時停止、もう一度翻訳（メニューから実行。必要なら設定でキーを割り当てられます）']]),
    ('h3', 'レンズのメニュー'),
    ('p', 'レンズの名札を右クリックすると、そのレンズでできることがまとめて表示されます。'),
    ('ul', ['**元のテキストを表示**、**原文をコピー**、**翻訳をコピー**: 2つのコピーは、レンズの中の文字を読む順番にそろえてコピーします。',
            '**読み上げ**: 訳文をシステムの音声で読み上げます。その言語の音声が入っていないときは、システム設定 › アクセシビリティ › 読み上げコンテンツで追加してください。',
            '**レンズの画像を保存**: 訳文が重なった状態のレンズの画面を、{n:PNG}で保存します。']),
]


def _plain(s):
    s = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', s)
    s = re.sub(r'\{[nt]:([^}]+)\}|\[\[([^\]]+)\]\]', lambda m: m.group(1) or m.group(2), s)
    s = re.sub(r'`(?:\w+\|)?([^`]+)`', r'\1', s)
    return re.sub(r'\s+', ' ', re.sub(r'[*`]', '', s)).strip()


for _p, _blocks in (('README.md', README_KO_A + README_KO_B), ('README.en.md', README_EN_A + README_EN_B), ('README.ja.md', README_JA_A)):
    _texts = []
    for _b in _blocks:
        if _b[0] in ('h3', 'p'): _texts.append(_b[1])
        elif _b[0] == 'ul': _texts += _b[1]
        elif _b[0] == 'table': _texts += [re.sub(r'^!\w+\|', '', c) for r in _b[2] for c in r]
    _src = repo_text(_p)
    note_source(_p, 'repo-file', f'git show {PIN}:{_p}', _src)
    _all = _plain(_src)
    for _t in _texts:
        if _plain(_t) not in _all: raise SystemExit(f'h2: not in {_p}@{PIN}: {_plain(_t)[:70]!r}')

# ------------------------------------------------------------------------------------------------------------------ keyboard cheat sheets
KEYS = [('⌘B', '앱 빌드', 'アプリをビルド', 'Build the app'), ('⌘R', '앱 실행', 'アプリを実行', 'Run the app'),
        ('⌘U', '테스트 전부 실행', 'すべてのテストを実行', 'Run all tests'), ('⌘.', '실행 중인 앱 중지', '実行中のアプリを停止', 'Stop the running app'),
        ('⇧⌘O', '빠르게 열기', 'クイックオープン', 'Open Quickly'), ('⌃⌘J', '정의로 이동', '定義へジャンプ', 'Jump to definition'),
        ('⌃⌘←', '뒤로 가기', '戻る', 'Go back'), ('⇧⌘F', '프로젝트에서 찾기', 'プロジェクト内を検索', 'Find in project'),
        ('⌘/', '줄 주석 켜고 끄기', '行のコメントを切り替え', 'Comment or uncomment the lines'),
        ('⌃I', '선택 영역 들여쓰기 다시 맞추기', '選択範囲のインデントを整える', 'Re-indent the selection'),
        ('⇧⌘Y', '디버그 영역 보이기 / 숨기기', 'デバッグエリアの表示を切り替え', 'Show or hide the debug area'),
        ('⌥⌘←', '코드 블록 접기', 'コードブロックを折りたたむ', 'Fold the code block')]


def keys_rows(i):
    return [[f'!hotkey|{k[0]}', k[i]] for k in KEYS]


KEYS_KO = [('h1', '{n:Xcode}에서 자주 쓰는 단축키'),
           ('p', '{n:Xcode}에서 빌드하고 테스트할 때 가장 많이 쓰는 키예요. `hotkey|⌘B`로 빌드하고 `hotkey|⌘U`로 테스트를 돌려요.'),
           ('table', ['단축키', '하는 일'], keys_rows(1)),
           ('p', '더 보려면 {n:Xcode}의 {n:Product} 메뉴를 열어 보세요.')]
KEYS_JA = [('h1', '{n:Xcode} でよく使うショートカット'),
           ('p', '{n:Xcode} でビルドやテストをするときによく使うキーです。`hotkey|⌘B` でビルド、`hotkey|⌘U` でテストを実行します。'),
           ('table', ['ショートカット', '動作'], keys_rows(2)),
           ('p', 'ほかのキーは {n:Xcode} の {n:Product} メニューで確認できます。')]
KEYS_EN = [('h1', 'Common shortcuts in {n:Xcode}'),
           ('p', 'These are the keys used most when building and testing in {n:Xcode}. `hotkey|⌘B` builds, and `hotkey|⌘U` runs the tests.'),
           ('table', ['Shortcut', 'What it does'], keys_rows(3)),
           ('p', 'To see more, open the {n:Product} menu in {n:Xcode}.')]

# ------------------------------------------------------------------------------------------------------------ the author's inline reasons
INLINE.update({
    # paths and file names
    'Backoff.swift': 'path', 'Deadline.swift': 'path', 'ReadWait.swift': 'path', 'project.yml': 'path', 'settings.json': 'path',
    'tools/ane-env.sh': 'path', 'docs/README.md': 'path', 'Mwoyeo.xcodeproj': 'path', '<exportFolder>/Transcripts': 'path',
    'Core/Sources/MwoyeoCore/Backoff.swift': 'path', 'Core/Sources/MwoyeoCore/Deadline.swift': 'path', 'Core/Sources/MwoyeoCore/ReadWait.swift': 'path',
    'docs/settings-for-agents.md': 'path', 'tools/keep-labels/run-rules.sh': 'path', '~/Library/Application Support/Mwoyeo/settings.json': 'path',
    'ane-env.sh': 'path', 'Transcripts': 'path',
    # commands and flags
    'Mwoyeo --settings-path': 'cmd', 'Mwoyeo --check-settings': 'cmd', 'Mwoyeo --check-settings [경로]': 'cmd', 'Mwoyeo --check-settings [path]': 'cmd',
    'git log -p ca12b7c': 'cmd', 'python3 tools/app-store/asc.py previews': 'cmd', 'rm -rf /tmp/dd': 'cmd', 'xcodegen generate': 'cmd',
    'KEEP_BUILD=/tmp/k3a/build ./run-rules.sh': 'cmd', 'xcodebuild': 'cmd', 'tail -f': 'cmd', 'ocrdump': 'cmd', 'regen.sh': 'path',
    '--check-settings': 'flag',
    # hashes, urls
    'ca12b7c': 'hash', 'https://github.com/midagedev/mwoyeo/releases/latest': 'url',
    # identifiers: types, functions, variables, branches, parameters
    'wait(after:)': 'id', 'factor': 'id', 'cap': 'id', 'DeadlineRace': 'id', 'continuation': 'id', 'track(work:timer:)': 'id', 'RecognitionWait': 'id',
    'ReadWait.State': 'id', 'ReadWait': 'id', 'showing': 'id', 'slot()': 'id', 'disk_ok': 'id', 'ANE_FLOOR_KB': 'id', 'TOKEN_AT': 'id',
    'wt/k3a': 'id', 'return 1': 'code', 'Backoff(base: 1, cap: 30)': 'code', 'ignored': 'log',
    # settings keys and values, build configurations
    'engines': 'config', 'thinking': 'config', 'off': 'config', 'provider': 'config', 'note': 'config', 'transcriptFormats': 'config',
    '"jsonl"': 'config', '"savesTranscripts": true': 'config', '"maybe"': 'config', 'exportFolder': 'config', 'configs': 'config', 'Debug': 'config',
    'Release': 'config', 'MAS': 'config', 'MARKETING_VERSION': 'config',
    # output
    'ok': 'log', 'BUILD SUCCEEDED': 'log', 'held 6.4 s': 'log', 'swift build failed': 'log', 'settings.json:14:': 'log', 'settings.json:14': 'log',
    'settings.json:14: engines[0].thinking: "maybe" is not allowed; use one of off, provider; ignored': 'log',
    # a modifier symbol written in a sentence without styling
    '⌥': 'hotkey',
})


# ----------------------------------------------------------------------------------------------------------------------------- scenes
def L(lines, lang, path=None, cmd=None):
    return Listing(lines, lang, path, cmd or (f'cat {path}' if path else None))


SIBLINGS = ['Deadline.swift', 'ReadWait.swift', 'RetryBackoff.swift', 'PaceStats.swift']
SCENES = [
    dict(id='swift-ko', lang='ko', looks=['ide-light', 'md-light', 'chat-dark'], channel='dev-lens', siblings=SIBLINGS,
         listing=L(BACKOFF, 'swift', 'Core/Sources/MwoyeoCore/Backoff.swift'),
         md=[('h1', '재시도 대기 시간은 어떻게 늘어나나요?'),
             ('p', '`Backoff.swift`의 `wait(after:)`는 실패 횟수가 늘수록 대기 시간을 `factor`배씩 늘려요. 아래 코드를 먼저 읽어 보세요.'),
             C(BACKOFF, 'swift', 'Core/Sources/MwoyeoCore/Backoff.swift'),
             ('p', '`cap`을 넘기지 않아서 `Backoff(base: 1, cap: 30)`처럼 상한만 정해 주면 돼요. 파일 위치는 [[Core/Sources/MwoyeoCore/Backoff.swift]]예요.')],
         chat=[('dana', '오전 10:41', [('p', '재시도 간격이 왜 이렇게 길어요? `Backoff.swift` 보면 되나요?')]),
               ('minjun', '오전 10:42', [('p', '네, 대기 시간은 `wait(after:)` 한 군데에서만 계산해요. 이 부분이에요:'), C(BACKOFF_WAIT, 'swift')]),
               ('dana', '오전 10:44', [('p', '`cap`이 30이라서 더 안 늘어나는 거군요. 고마워요!')])]),
    dict(id='swift-ja', lang='ja', looks=['ide-dark', 'md-dark'], channel='dev-lens', siblings=['Backoff.swift', 'ReadWait.swift', 'PaceStats.swift'],
         listing=L(DEADLINE, 'swift', 'Core/Sources/MwoyeoCore/Deadline.swift'),
         md=[('h1', 'タイムアウトの競争をどう管理しているか'),
             ('p', '`Deadline.swift` の `DeadlineRace` は、処理とタイマーのうち先に終わったほうの結果を、一度だけ `continuation` に渡します。'),
             C(DEADLINE, 'swift', 'Core/Sources/MwoyeoCore/Deadline.swift'),
             ('p', 'キャンセル済みなら `track(work:timer:)` がすぐに両方のタスクを止めます。全体は [[Core/Sources/MwoyeoCore/Deadline.swift]] を読んでください。')]),
    dict(id='swift-en', lang='en', looks=['ide-light', 'term-dark', 'md-light'], channel='dev-lens', siblings=['Backoff.swift', 'Deadline.swift', 'PaceStats.swift'],
         listing=L(READWAIT, 'swift', 'Core/Sources/MwoyeoCore/ReadWait.swift'),
         md=[('h1', 'What a lens shows while no reader is ready'),
             ('p', 'A lens is never silent. `RecognitionWait` in `ReadWait.swift` names the three things the pill can say, and `ReadWait.State` tracks which one is showing.'),
             C(READWAIT, 'swift', 'Core/Sources/MwoyeoCore/ReadWait.swift'),
             ('p', 'The words belong to the app. The rest of the file is in [[Core/Sources/MwoyeoCore/ReadWait.swift]].')]),
    dict(id='shell-ko', lang='ko', looks=['term-dark', 'ide-light', 'md-light'], channel='dev-lens', siblings=['ane-lease/check.sh', 'keep-labels/regen.sh'],
         listing=L(ANE, 'sh', 'tools/ane-env.sh', 'sed -n 29,60p tools/ane-env.sh'),
         md=[('h1', '컴파일러 서비스 앞에서 줄 서는 법'),
             ('p', '`tools/ane-env.sh`는 새 번들 ID로 처음 실행할 때만 락을 잡아요. `slot()`이 워크트리마다 풀 번호를 하나씩 정해 줘요.'),
             C(ANE, 'sh', 'tools/ane-env.sh'),
             ('p', '디스크 여유가 `ANE_FLOOR_KB`보다 적으면 `disk_ok`가 `return 1`로 끝내요.')]),
    dict(id='shell-ja', lang='ja', looks=['term-light', 'ide-dark'], channel='dev-lens', siblings=['mas.sh', 'release.sh', 'setup-release-secrets.sh'],
         listing=L(CASK, 'sh', 'scripts/cask.sh'), md=[]),
    dict(id='gitlog-ko', lang='ko', looks=['term-dark', 'term-light', 'md-light'], channel='dev-lens', siblings=[],
         listing=Listing(GITLOG_LINES, 'term'),
         md=[('h1', '최근 커밋 열두 개'),
             ('meta', '{n:dana}님이 {t:10월 20일}에 이 이슈를 열었어요 · 댓글 {t:3}개'),
             ('p', '`ane-env.sh`가 들어온 뒤의 커밋이에요. 해시 `ca12b7c`부터 보시면 돼요.'),
             C(GITLOG_LINES, 'term'),
             ('p', '바뀐 줄은 `git log -p ca12b7c`로 볼 수 있어요.')]),
    dict(id='gitdiff-ja', lang='ja', looks=['term-dark', 'ide-light', 'md-light'], channel='dev-lens', siblings=['screenshots/compose.sh', 'previews/cut.sh'],
         listing=Listing(DIFF_LINES, 'diff', 'tools/app-store/asc.py', DIFF_CMD),
         md=[('h1', 'asc.py: 長いアップロードで 401 になる問題'),
             ('meta', '{n:dana} さんが {t:2026-10-20} にこのプルリクエストを開きました'),
             ('p', 'トークンの有効期限は15分です。`TOKEN_AT` に作った時刻を残して、10分たったら作り直します。'),
             C(DIFF_LINES, 'diff'),
             ('p', '`python3 tools/app-store/asc.py previews` で確認しました。')]),
    dict(id='tests-en', lang='en', looks=['term-dark', 'md-dark'], channel='dev-tests', siblings=[],
         listing=Listing(TESTS[1:], 'log', None, TESTS[0].text[2:]),
         md=[('h1', 'The suite passes, but the log is long'),
             ('meta', '{n:ben} commented {t:2 hours} ago'),
             ('p', 'All 811 tests pass on my branch `wt/k3a`. This is how the run starts and ends.'),
             C(TESTS, 'log'),
             ('p', 'The first lines are the older XCTest style, the last ones the new test style.')]),
    dict(id='xcode-ko', lang='ko', looks=['term-light', 'md-dark'], channel='dev-lens', siblings=[],
         listing=Listing(XCODE[1:], 'log', None, XCODE[0].text[2:]),
         md=[('h1', '빌드 로그가 너무 길어요'),
             ('p', '`xcodebuild`는 처음 몇 줄에 어떤 대상으로 빌드하는지 보여 줘요. 끝에는 `BUILD SUCCEEDED`가 나와요.'),
             C(XCODE, 'log'),
             ('p', '대상이 여러 개라는 경고는 무시해도 돼요.')]),
    dict(id='json-ko', lang='ko', looks=['ide-light', 'md-light'], channel='dev-lens', siblings=['ollama-gemma4-e4b-fold.json', 'anthropic-haiku-5-5.json'],
         listing=L(SETTINGS_JSON, 'json', 'Mwoyeo/settings.json'),
         md=[('h1', '엔진 하나 추가하기'),
             ('p', '로컬 모델은 `settings.json`의 `engines`에 한 줄만 더하면 돼요. `thinking`은 `off`나 `provider` 중에서 골라요.'),
             C(SETTINGS_JSON, 'json', 'settings.json'),
             ('p', '`note`는 사람이 읽는 메모예요. 키는 이 파일 대신 키체인에 넣어요.')]),
    dict(id='yaml-ja', lang='ja', looks=['ide-dark', 'md-dark'], channel='dev-lens', siblings=['README.md', 'LICENSE', 'CONTRIBUTING.md'],
         listing=L(PROJECT_YML, 'yaml', 'project.yml'),
         md=[('h1', '{n:XcodeGen} の設定を読む'),
             ('p', '`project.yml` の `configs` に `MAS` があります。{n:DMG} 版は `Debug` と `Release`、{n:Mac App Store} 版は `MAS` を使います。'),
             C(PROJECT_YML, 'yaml', 'project.yml'),
             ('p', 'バージョンは `MARKETING_VERSION` の一か所だけで決めます。')]),
    dict(id='readme-ko-a', lang='ko', looks=['md-light'], channel='dev-lens', siblings=[], listing=None, md=README_KO_A),
    dict(id='readme-ko-b', lang='ko', looks=['md-dark'], channel='dev-lens', siblings=[], listing=None, md=README_KO_B),
    dict(id='readme-en-a', lang='en', looks=['md-light'], channel='dev-lens', siblings=[], listing=None, md=README_EN_A),
    dict(id='readme-en-b', lang='en', looks=['md-light'], channel='dev-lens', siblings=[], listing=None, md=README_EN_B),
    dict(id='readme-ja-a', lang='ja', looks=['md-light'], channel='dev-lens', siblings=[], listing=None, md=README_JA_A),
    dict(id='keys-ko', lang='ko', looks=['md-light'], channel='dev-lens', siblings=[], listing=None, md=KEYS_KO),
    dict(id='keys-ja', lang='ja', looks=['md-dark-plain'], channel='dev-lens', siblings=[], listing=None, md=KEYS_JA),
    dict(id='keys-en', lang='en', looks=['md-light-plain'], channel='dev-lens', siblings=[], listing=None, md=KEYS_EN),
    dict(id='session-ko', lang='ko', looks=['term-dark', 'term-light'], channel='dev-lens', siblings=[], listing=Listing(SESSION_KO, 'term'), md=[]),
    dict(id='session-ja', lang='ja', looks=['term-dark', 'chat-dark'], channel='dev-lens', siblings=[], listing=Listing(SESSION_JA, 'term'), md=[],
         chat=[('sato', '午前 9:05', [('p', '`ocrdump` を動かしたら、最後にこんな表示が出ました。これで読めていますか？'), C(SESSION_JA[-4:], 'term')]),
               ('tanaka', '午前 9:07', [('p', '`held 6.4 s` なら読めています。続けて `regen.sh` を実行してください。')])]),
    dict(id='chat-ko', lang='ko', looks=['chat-dark', 'chat-light'], channel='dev-settings', siblings=[], listing=None, md=[],
         chat=[('minjun', '오전 9:12', [('p', '`settings.json`을 직접 고쳤는데 `Mwoyeo --check-settings`가 한 줄을 출력해요.')]),
               ('dana', '오전 9:15', [('p', '어떤 줄이에요? 그대로 붙여 주세요.')]),
               ('minjun', '오전 9:16', [('p', '이래요:'), C(SETTINGS_CHECK, 'term')]),
               ('dana', '오전 9:20', [('p', '`thinking`에는 `off`나 `provider`만 쓸 수 있어요. 끝의 `ignored`는 그 항목 하나만 무시하고 나머지는 적용한다는 뜻이에요. 설명은 [[docs/settings-for-agents.md]]에 있어요.')])]),
    dict(id='chat-ja', lang='ja', looks=['chat-dark'], channel='dev-build', siblings=[], listing=None, md=[],
         chat=[('sato', '午前 10:02', [('p', 'ビルドが `Mwoyeo.xcodeproj` を見つけられないと出ます。')]),
               ('tanaka', '午前 10:04', [('p', 'まず `xcodegen generate` を実行してください。それでも出るなら `rm -rf /tmp/dd` で派生データを消して、もう一度 `xcodebuild` です。'), C(ACK_LOG, 'term')]),
               ('sato', '午前 10:09', [('p', 'できました！ありがとうございます。`BUILD SUCCEEDED` と出ました。')])]),
    dict(id='chat-en', lang='en', looks=['chat-light-plain'], channel='dev-labels', siblings=[], listing=None, md=[],
         chat=[('maria', '11:20 AM', [('p', 'Can someone look at `tools/keep-labels/run-rules.sh`? It fails with `swift build failed` on my branch `wt/k3a`.')]),
               ('ben', '11:23 AM', [('p', 'The scratch path was missing. Try `KEEP_BUILD=/tmp/k3a/build ./run-rules.sh` and read the log it names:'), C(SWIFT_BUILD_FAIL, 'term')]),
               ('maria', '11:31 AM', [('p', 'That fixed it, thanks!')])]),
    dict(id='issue-en', lang='en', looks=['md-light-plain'], channel='dev-lens', siblings=[], listing=None,
         md=[('h1', 'The reader hint stays up after the service restarts (#214)'),
             ('meta', '{n:dana} opened this issue on {t:Oct 18} · {t:3} comments'),
             ('h2', 'What happens'),
             ('p', 'After the text recognition service restarts, the pill under the lens keeps saying "Preparing text recognition" for a few seconds. `ReadWait` should go back to `showing` as soon as a read returns.'),
             ('h2', 'Steps'),
             ('ul', ['Put a lens over a chat window.', 'Restart the reader from {n:Activity Monitor}.', 'Watch the pill under the lens.']),
             C(ISSUE_EN_LOG, 'term'),
             ('p', 'Expected: the pill clears at once. The state is in [[Core/Sources/MwoyeoCore/ReadWait.swift]]; a build to try is at `url|https://github.com/midagedev/mwoyeo/releases/latest`.')]),
    dict(id='issue-ko', lang='ko', looks=['md-dark-plain'], channel='dev-lens', siblings=[], listing=None,
         md=[('h1', '`--check-settings`가 줄 번호를 하나 틀리게 알려 줘요 (#215)'),
             ('meta', '{n:minjun}님이 {t:10월 19일}에 이 이슈를 열었어요 · 댓글 {t:2}개'),
             ('h2', '어떻게 되나요'),
             ('p', '목록 안의 항목에 문제가 있으면 `settings.json:14:`처럼 줄 번호를 알려 주는데, 한 줄 위를 가리켜요.'),
             ('h2', '재현 방법'),
             ('ul', ['`engines`에 항목을 둘 넣어요.', '둘째 항목의 `thinking`을 `"maybe"`로 바꿔요.', '`Mwoyeo --check-settings`를 실행해요.']),
             C(ISSUE_KO_LOG, 'term'),
             ('p', '기대한 결과는 `settings.json:14`예요. 설명은 [[docs/settings-for-agents.md]]에 있어요.')]),
    dict(id='issue-ja', lang='ja', looks=['md-light'], channel='dev-lens', siblings=[], listing=None,
         md=[('h1', 'ログの保存先を変えても反映されない (#216)'),
             ('meta', '{n:sato} さんが {t:10月19日} にこのイシューを開きました · コメント {t:4} 件'),
             ('h2', '何が起きるか'),
             ('p', '`exportFolder` を変更しても、記録は古いフォルダの `Transcripts` に書き込まれ続けます。'),
             ('h2', '再現手順'),
             ('ul', ['設定 › 一般で保存先を変える。', '`"savesTranscripts": true` にして、レンズで何か読み取る。', '`tail -f` で新しい記録が増えるか確認する。']),
             C(ISSUE_JA_LOG, 'term'),
             ('p', '期待する結果は、新しい保存先に記録が増えることです。')]),
]
