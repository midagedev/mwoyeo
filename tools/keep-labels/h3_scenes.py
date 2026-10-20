"""The scenes of H3, a second hold-out for the keep boundary (round h3, 2026-10-20). h2.py draws them (h3.py is the entry point), with the looks of h3_looks.py.
Same construction as H2 (h2.py's header: a unit is a piece of text with the class the AUTHOR gives it, never a shape rule of truth.py), new material:
  - repo excerpts of files H2 did not use (scripts/*.sh and stats.py, Core/Tests, Config/MAS.xcconfig, App/Resources/Localizable.xcstrings, the plist of scripts/,
    docs/settings-for-agents.md, CONTRIBUTING.md, README.zh-CN.md, tools/engine-bench, tools/mock-openai), read at the pinned commit and verified line by line,
    with the comments replaced by Korean / Japanese / Chinese ones where the scene says so;
  - tool-output fixtures captured once (h3/capture.sh -> h3/src/*.txt): git diff / show --stat / blame / grep of midagedev's own commits, a swift build, ls -l,
    the bench report of tools/engine-bench;
  - prose written for the scene in ko / ja / en / zh-Hans, and the app's own UI strings from the string catalog (real ko / ja / zh-Hans / en values).
Nothing from usecase-bench/set/k*, RESULTS-*, CODE-FEATURES-*, CodeRegion.swift, nor any source in h2/MANIFEST.tsv. The reason of every inline piece is the author's."""
import json, os, re
import h2
import h3_looks                                                       # registers the themes and layouts of H3 in h2's tables
from h2 import CJK, INLINE, Line, Listing, lines_of, note_source, repo_text, verify

HERE = os.path.dirname(os.path.abspath(__file__))
PIN = '5c25067'                                                       # main when the round started; every repo excerpt is read from here
h2.PIN = PIN
h2.SRC = os.environ.get('H3_SRC') or os.path.join(HERE, 'h3', 'src')   # H3_SRC: another fixture dir (the FAIL-first of the frozen manifest)


def C(lines, lang, caption=None, cmd=None):
    return ('code', Listing(lines, lang), caption, cmd)


def session(block):
    """A terminal session: `$ ` lines are commands, a line with CJK is either (program output in a CJK language), any other is a log line."""
    ls = lines_of(block, 'term', 'log')
    for l in ls:
        if l.text.startswith('$ '): l.reason = 'cmd'
        elif CJK.search(l.text): l.opt = True
    return ls


def fixture_lines(name, command, source_cmd, diff=False, take=None):
    """The lines of a tool-output fixture, after the command that printed them. diff: the lines of a unified diff (header lines diffmark, comments
    uncertain, as H2's). take: (first, last) 0-based slice of the fixture's lines."""
    text = h2.fixture(name)
    note_source(f'h3/src/{name}', 'tool-output', source_cmd, text)
    raw = text.rstrip('\n').split('\n')
    if take: raw = raw[take[0]:take[1]]
    out = [Line('$ ' + command, 'cmd')] if command else []
    for r in raw:
        if diff:
            hdr = r.startswith(('diff --git', 'index ', '--- ', '+++ ', '@@'))
            ln = lines_of(r, 'py', 'diffmark' if hdr else 'code')[0]
            if hdr: ln.unc = False
        else:
            ln = Line(r.rstrip(), 'log')
            if CJK.search(r): ln.opt = True
        out.append(ln)
    return out


def ranged(path, first, last, lang='json', reason='config'):
    """Lines first..last (1-based) of a repo file at the pinned commit, as they are."""
    text = repo_text(path)
    note_source(path, 'repo-file', f'git show {PIN}:{path}', text)
    return lines_of('\n'.join(text.split('\n')[first - 1:last]), lang, reason)


def catalog(key, langs, state_only=False):
    """An entry of App/Resources/Localizable.xcstrings with only `langs` (the file's own format, 2-space JSON); every value is checked against the file."""
    path = 'App/Resources/Localizable.xcstrings'
    text = repo_text(path)
    note_source(path, 'repo-file', f'git show {PIN}:{path}', text)
    entry = json.loads(text)['strings'][key]
    sub = {'localizations': {l: entry['localizations'][l] for l in langs}}
    lines = json.dumps({key: sub}, ensure_ascii=False, indent=2).split('\n')
    for l, v in sub['localizations'].items():
        if '"value": ' + json.dumps(v['stringUnit']['value'], ensure_ascii=False) not in text: raise SystemExit(f'h3: catalog value of {key!r} {l} not in the file')
    return lines_of('\n'.join(lines), 'json', 'config')


def ui(key, lang):
    """The app's own string for `key` in `lang` (App/Resources/Localizable.xcstrings at the pin)."""
    text = repo_text('App/Resources/Localizable.xcstrings')
    note_source('App/Resources/Localizable.xcstrings', 'repo-file', f'git show {PIN}:App/Resources/Localizable.xcstrings', text)
    e = json.loads(text)['strings'][key]
    return key if lang == 'en' else e['localizations'][lang]['stringUnit']['value']


# --------------------------------------------------------------------------------------------------------------------- shell scripts
MAS = verify(lines_of('''
#!/bin/zsh
# 인증 정보는 파일에 두지 않아요. 환경 변수로만 받고, 없으면 바로 멈춰요.
set -euo pipefail

ROOT=${0:A:h:h}
OUT=$ROOT/build/mas
APP_ID=dev.midagedev.mwoyeo.appstore
IDENTITY=${MWOYEO_MAS_IDENTITY:?set MWOYEO_MAS_IDENTITY to your Apple Distribution identity}
PROFILE=${MWOYEO_MAS_PROFILE:?set MWOYEO_MAS_PROFILE to the name of the Mac App Store provisioning profile}
INSTALLER=${MWOYEO_MAS_INSTALLER:-3rd Party Mac Developer Installer}
TEAM=${IDENTITY##*\\(}; TEAM=${TEAM%\\)}

cd "$ROOT"
# 인페인팅 모델이 없으면 앱을 만들어도 소용없으니 먼저 확인해요.
[[ -d tools/inpaint/models/MIGAN_512.mlpackage ]] || { echo "missing tools/inpaint/models/MIGAN_512.mlpackage" >&2; exit 1; }

echo "==> Archive"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate >/dev/null
xcodebuild -project Mwoyeo.xcodeproj -scheme Mwoyeo-MAS -configuration MAS -destination 'generic/platform=macOS' \\
  -archivePath "$OUT/Mwoyeo.xcarchive" -derivedDataPath "$OUT/dd" \\
''', 'sh'), 'scripts/mas.sh', 'sh')

RELEASE = verify(lines_of('''
echo "==> Disk image"
STAGE=$OUT/stage
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mwoyeo.app"
ln -s /Applications "$STAGE/Applications"
# ディスクイメージを作り、署名してから公証に出す。
hdiutil create -volname Mwoyeo -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

echo "==> Notarize"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$DMG"
echo "sha256 $SHA"
''', 'sh'), 'scripts/release.sh', 'sh')

SECRETS = verify(lines_of('''
#!/bin/zsh
# 只在持有开发者证书的那台 Mac 上运行一次。
set -euo pipefail

P12=${1:?usage: scripts/setup-release-secrets.sh <devid.p12>}
REPO=${REPO:-midagedev/mwoyeo}
[[ -f "$P12" ]] || { echo "no such file: $P12" >&2; exit 1; }

# 公证密钥优先从环境变量读取，否则读 ~/.appstoreconnect 里的文件。
if [[ -z "${MWOYEO_NOTARY_KEY:-}" && -f ~/.appstoreconnect/credentials.env ]]; then
  source ~/.appstoreconnect/credentials.env
  MWOYEO_NOTARY_KEY_ID=$ASC_KEY_ID
  MWOYEO_NOTARY_ISSUER_ID=$ASC_ISSUER_ID
  MWOYEO_NOTARY_KEY=~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
fi
[[ -f "${MWOYEO_NOTARY_KEY:-}" ]] || { echo "no notary key found" >&2; exit 1; }
''', 'sh'), 'scripts/setup-release-secrets.sh', 'sh')

# --------------------------------------------------------------------------------------------------------------------- Python
STATS_EN = verify(lines_of('''
def totals(rels):
    t = {"installs": 0, "months": 0, "checks": 0, "downloads": 0}
    for r in rels:
        # Releases from before the app counted itself (no install.json): their disk image downloads stand in for
        # installs. Someone who upgrades from one is counted again when the new version counts its install.
        if not any(a["name"] == "install.json" for a in r["assets"]):
            t["installs"] += sum(a["download_count"] for a in r["assets"] if a["name"].endswith(".dmg"))
        for a in r["assets"]:
            key = {"install.json": "installs", "month.json": "months", "version.json": "checks"}.get(a["name"])
            if key:
                t[key] += a["download_count"]
            elif a["name"].endswith(".dmg"):
                t["downloads"] += a["download_count"]
    return t
''', 'py'), 'scripts/stats.py', 'py')

STATS_KO = verify(lines_of('''
def monthly_active(history, today):
    # 이번 달 이전의 마지막 행에서 month.json 내려받기가 얼마나 늘었는지 센다. 설치마다 한 달에 한 번만 세어진다.
    month = today[:7]
    before = [r for r in history if r["date"][:7] < month]
    base = int(before[-1]["months"]) if before else 0
    now = int(history[-1]["months"])
    return now - base


def short(n):
    return f"{n / 1000:.1f}k".replace(".0k", "k") if n >= 1000 else str(n)
''', 'py'), 'scripts/stats.py', 'py')

# --------------------------------------------------------------------------------------------------------------------- Swift tests
MENU = verify(lines_of('''
@Suite struct MenuBarIconTests {
    private func icon(paused: Bool = false, visible: Bool = true, lens: Bool = true, attention: Bool = false) -> MenuBarIcon {
        MenuBarIcon(paused: paused, translationsVisible: visible, hasLens: lens, needsAttention: attention)
    }

    // メニューバーのアイコンの形は、状態によって決まる。
    @Test func theSymbolFollowsTheState() {
        #expect(icon().symbol == "text.viewfinder")
        #expect(icon(lens: false).symbol == "viewfinder")
        #expect(icon(visible: false).symbol == "eye.slash")
        #expect(icon(paused: true, visible: false).symbol == "pause.circle")
    }

    @Test func pausedIsOnPurposeAndShowsNoBadge() {
        #expect(!icon(paused: true, attention: true).badge)
    }
}
''', 'swift'), 'Core/Tests/MwoyeoCoreTests/MenuBarIconTests.swift', 'swift')

PACE = verify(lines_of('''
@Suite struct PaceStatsTests {
    private let engine = UUID()
    private func slot(_ pair: String, engine: UUID? = nil) -> PaceStats.Slot {
        PaceStats.Slot(key: "\\(pair)|\\(engine == nil ? "apple:auto" : "ext:x")", engine: engine)
    }

    @Test func expectedSecondsFollowsTheNamespaceInUseAndIsNilUntilItsFirstLine() {
        let p = PaceStats()
        let en = slot("en>ko"), ja = slot("ja>ko")
        p.use(en)
        #expect(p.expectedSeconds(lines: 3) == nil)
        p.record(1.5, isFirst: true, slot: en)
        p.record(0, isFirst: false, slot: en)
        #expect(p.expectedSeconds(lines: 3) == 1.5)
        // 换一个语言组合时，它还什么都不知道。
        p.use(ja)
        #expect(p.expectedSeconds(lines: 3) == nil)
        p.use(en)
        #expect(p.expectedSeconds(lines: 3) == 1.5)
    }
}
''', 'swift'), 'Core/Tests/MwoyeoCoreTests/PaceStatsTests.swift', 'swift')

HTTP = verify(lines_of('''
@Suite struct HTTPTemplateTests {
    private let nasty = "say \\"hi\\" & bye\\nline2 😀 a=b?c"

    private func template(url: String = "http://h/t", headers: [String: String] = [:], body: String = "",
                          path: String = "r", batching: HTTPTemplate.Batching = .perLine) -> HTTPTemplate {
        HTTPTemplate(url: url, headers: headers, body: body, resultPath: path, batching: batching)
    }

    @Test func textInTheURLIsPercentEncoded() throws {
        let r = try one(template(url: "http://h/t?q={{text}}&k={{key}}"))
        #expect(r.url == "http://h/t?q=say%20%22hi%22%20%26%20bye%0Aline2%20%F0%9F%98%80%20a%3Db%3Fc&k=SECRET")
        #expect(URL(string: r.url) != nil)
    }

    @Test func textInAFormBodyIsPercentEncoded() throws {
        let r = try one(template(body: "q={{text}}&target={{target_upper}}"))
        #expect(String(decoding: r.body!, as: UTF8.self) == "q=say%20%22hi%22%20%26%20bye%0Aline2%20%F0%9F%98%80%20a%3Db%3Fc&target=KO")
    }
}
''', 'swift'), 'Core/Tests/MwoyeoCoreTests/HTTPTemplateTests.swift', 'swift')


def must_have(path, snippet):
    """A command or sentence written into a scene is a text of the repo file at the pin."""
    text = repo_text(path)
    note_source(path, 'repo-file', f'git show {PIN}:{path}', text)
    if snippet not in text: raise SystemExit(f'h3: not in {path}@{PIN}: {snippet!r}')
    return snippet


# --------------------------------------------------------------------------------------------------------------- numbered lines (nl -ba)
_orig_add_line_unit = h2.add_line_unit


def _add_line_unit(doc, ln, region):
    """A `nl -ba` row is two units: the number the tool prints (keep, lineno) and the line (its own class)."""
    n = getattr(ln, 'number', None)
    if n is None: return _orig_add_line_unit(doc, ln, region)
    doc.unit(str(n), keep=True, reason='lineno', region=region, kind='lineno')
    return _orig_add_line_unit(doc, Line(ln.code, ln.reason, ln.unc, ln.opt), region)                        # a blank line gives no unit


h2.add_line_unit = _add_line_unit                                    # h2.emit_lines looks the function up by name when it runs


def numbered(lines, first):
    """The lines of an excerpt as `nl -ba` prints them (6-wide number, two spaces, the line); a blank line is numbered too."""
    out = []
    for k, ln in enumerate(lines):
        row = Line(f'{first + k:6d}  {ln.text}'.rstrip(), ln.reason, ln.unc, ln.opt)
        row.number, row.code = first + k, ln.text.strip()
        out.append(row)
    return out


# ------------------------------------------------------------------------------------------------------------------------ JSON, xcconfig, plist
CATALOG_KO = catalog('Allow screen recording', ['ko', 'ja', 'zh-Hans'])
CATALOG_JA = catalog('Not set', ['ko', 'ja'])
CATALOG_ZH = catalog('Paste Setup', ['ja', 'zh-Hans'])
APPPROFILE_EN = lines_of('''
{
  "appProfiles": [
    {
      "bundleID": "com.example.chat",
      "appName": "Example Chat",
      "source": "ja",
      "target": "en",
      "note": "Casual chat between two friends. Keep it informal and short.",
      "context": { "mode": "nearby", "previousLines": 3 }
    }
  ]
}
''', 'json', 'config')
_prof = json.loads('\n'.join(l.text for l in APPPROFILE_EN))['appProfiles'][0]
_doc = repo_text('docs/settings-for-agents.md')
note_source('docs/settings-for-agents.md', 'repo-file', f'git show {PIN}:docs/settings-for-agents.md', _doc)
for _k in ('"bundleID": "com.example.chat"', '"appName": "Example Chat"', '"source": "ja"', '"target": "en"',
           '"note": "Casual chat between two friends. Keep it informal and short."', '"context": { "mode": "nearby", "previousLines": 3 }'):
    if _k not in _doc: raise SystemExit(f'h3: not in docs/settings-for-agents.md@{PIN}: {_k}')
XCCONFIG = verify(lines_of('''
// The Mac App Store flavour: the same targets, Release-like, built with `-configuration MAS` (scheme Mwoyeo-MAS, scripts/mas.sh).
// Credentials never live here: the identity and the profile come in as variables (scripts/mas.sh checks them).
#include "Base.xcconfig"

MWOYEO_APP_ID = dev.midagedev.mwoyeo.appstore
MWOYEO_APP_ENTITLEMENTS = App/Mwoyeo-MAS.entitlements
MWOYEO_READER_ENTITLEMENTS = Reader/Reader-MAS.entitlements
MWOYEO_SIGN_IDENTITY = Apple Distribution

SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) MAS
ENABLE_APP_SANDBOX = YES
''', 'swift', 'config'), 'Config/MAS.xcconfig', 'swift')
PLIST = ranged('scripts/ExportOptions-MAS.plist', 4, 17, 'xml', 'config')

# ------------------------------------------------------------------------------------------------------------------------ tool outputs
BLAME = fixture_lines('git-blame.txt', 'git blame -L 14,33 --date=short scripts/release.sh', 'git blame -L 14,33 --date=short 5c25067 -- scripts/release.sh  (cut to 150 columns)')
STAT = fixture_lines('git-show-stat.txt', "git show --stat=100 --format='%h %s' 3871352", "git show --stat=100 --format='%h %s' 3871352")
GREP = fixture_lines('git-grep.txt', "git grep -n MWOYEO_FAKE_READER -- Core/Tests", "git grep -n 'MWOYEO_FAKE_READER' 5c25067 -- Core/Tests | head -n 12  (cut to 150 columns)")
BUILD_SRC = 'swift build -c release --scratch-path <scratch> --product snap|ocrdump  (the two SwiftPM products, 2026-10-20; bare progress lines dropped)'
BUILD = (fixture_lines('swift-build.txt', 'swift build -c release --product snap', BUILD_SRC, take=(0, 7)) +
         fixture_lines('swift-build.txt', 'swift build -c release --product ocrdump', BUILD_SRC, take=(7, None)))
LS = fixture_lines('ls-scripts.txt', 'ls -l scripts', 'ls -l scripts  (owner name replaced)')
BENCH = fixture_lines('bench-report.txt', 'python3 -I report.py results', 'cd tools/engine-bench && python3 -I report.py results | head -n 14')
DIFF_PERM = fixture_lines('git-diff-perm.txt', None, 'git diff b459840~1 b459840', diff=True, take=(4, None))
DIFF_SETTINGS = fixture_lines('git-diff-settings.txt', None, 'git diff 63d28f6~1 63d28f6 | head -n 44', diff=True, take=(4, None))
BENCH_CMDS = [Line(must_have('tools/engine-bench/README.md', c), 'cmd') for c in (
    'python3 -I bench.py --out out/raw-http.jsonl', 'python3 -I bench.py --engines gpt-5.4-mini --pairs ja-ko --out out/raw-http.jsonl')]
MOCK_CMD = [Line('python3 -I tools/mock-openai/server.py <port> <mode> [native,stamp]', 'cmd')]
must_have('tools/mock-openai/README.md', 'python3 -I tools/mock-openai/server.py <port> <mode> [native,stamp]')
RELEASE_CMDS = [Line(must_have('scripts/release.sh', 'scripts/release.sh 1.0.0'), 'cmd'), Line(must_have('scripts/release.sh', 'scripts/release.sh 1.0.0 --publish'), 'cmd')]
SETTINGS_CMDS = [Line(must_have('docs/settings-for-agents.md', 'Mwoyeo --check-settings [path]'), 'cmd')]
SETTINGS_ISSUES = session('''
$ Mwoyeo --check-settings
settings.json:7: unknown key appProfiles[0].paragraphReadr (did you mean paragraphReader?)
settings.json:14: appProfiles[0].entries[1]: missing "src"; dropped
''')
for _l in ('settings.json:7: unknown key appProfiles[0].paragraphReadr (did you mean paragraphReader?)', 'settings.json:14: appProfiles[0].entries[1]: missing "src"; dropped'):
    must_have('docs/settings-for-agents.md', _l)


# -------------------------------------------------------------------------------------------------------------- nl -ba of an exact range
def nl_range(path, first, last, lang):
    ls = ranged(path, first, last, lang, 'code')
    for l in ls:
        if '"""' in l.text: l.unc = True                     # a docstring in a code region reads as prose
    return numbered(ls, first)


NL_KO = nl_range('scripts/stats.py', 44, 54, 'py')
NL_JA = nl_range('scripts/release.sh', 52, 62, 'sh')
NL_ZH = nl_range('scripts/setup-release-secrets.sh', 12, 24, 'sh')
DATE_KO = session('''
$ date
2026년 10월 20일 화요일 09시 30분 12초 KST
''')
DATE_JA = session('''
$ date
2026年10月20日 火曜日 09時30分12秒 JST
''')
DATE_ZH = session('''
$ date
2026年10月20日 星期二 09:30:12 CST
''')

# ---------------------------------------------------------------------------------------------------------------------- shared tables
KEYS = [('Ctrl+C', '실행 중인 명령을 멈춰요', '実行中のコマンドを止めます', '中断正在运行的命令', 'Stops the running command'),
        ('Ctrl+R', '명령 기록에서 찾아요', 'コマンド履歴を検索します', '在命令历史中搜索', 'Searches the command history'),
        ('Ctrl+L', '화면을 지워요', '画面をクリアします', '清除屏幕', 'Clears the screen'),
        ('Ctrl+A', '줄 맨 앞으로 가요', '行の先頭へ移動します', '移到行首', 'Jumps to the start of the line'),
        ('Ctrl+E', '줄 맨 끝으로 가요', '行の末尾へ移動します', '移到行尾', 'Jumps to the end of the line'),
        ('Ctrl+W', '앞의 단어 하나를 지워요', '直前の単語を削除します', '删除前一个单词', 'Deletes the word before the cursor'),
        ('Ctrl+U', '줄의 처음까지 지워요', '行の先頭まで削除します', '删除到行首', 'Deletes to the start of the line'),
        ('Tab', '이름을 자동으로 완성해요', '名前を補完します', '自动补全名称', 'Completes the name'),
        ('Cmd+T', '새 탭을 열어요', '新しいタブを開きます', '打开新标签页', 'Opens a new tab'),
        ('Cmd+K', '터미널 출력을 비워요', 'ターミナルの出力を消します', '清空终端输出', 'Clears the terminal output'),
        ('Ctrl+D', '셸을 끝내요', 'シェルを終了します', '结束当前 shell', 'Ends the shell session'),
        ('Ctrl+Z', '실행 중인 일을 잠시 멈춰요', '実行中の処理を一時停止します', '暂停正在运行的任务', 'Suspends the running job'),
        ('Cmd+F', '터미널에서 글자를 찾아요', 'ターミナル内の文字を検索します', '在终端中查找文字', 'Finds text in the terminal'),
        ('Cmd+N', '새 창을 열어요', '新しいウィンドウを開きます', '打开新窗口', 'Opens a new window')]


def keys_rows(i, n=14):
    return [[f'!hotkey|{k[0]}', k[i]] for k in KEYS[:n]]


GH = 'https://github.com/midagedev/mwoyeo'
URLS = {
    'repo': GH, 'issues': GH + '/issues', 'releases': GH + '/releases', 'latest': GH + '/releases/latest',
    'dmg': GH + '/releases/latest/download/Mwoyeo-arm64.dmg', 'settings': GH + '/blob/main/docs/settings-for-agents.md',
    'contrib': GH + '/blob/main/CONTRIBUTING.md', 'bench': GH + '/tree/main/tools/engine-bench', 'release': GH + '/blob/main/scripts/release.sh',
    'commit': GH + '/commit/3a07a45', 'migan': 'https://github.com/Picsart-AI-Research/MI-GAN',
    'mock': GH + '/tree/main/tools/mock-openai', 'tap': 'https://github.com/midagedev/homebrew-tap',
}
_readmes = ''.join(repo_text(f) for f in ('README.zh-CN.md', 'README.en.md', 'README.md'))
for _k in ('repo', 'releases', 'latest', 'dmg', 'migan'):                  # the urls that are written in the repo's READMEs; the rest point at real paths of the repo
    if URLS[_k] not in _readmes and URLS[_k].replace(GH, '') not in _readmes: raise SystemExit(f'h3: url not in the READMEs: {URLS[_k]}')


def res(*pairs):
    """A list of 'label: url' items (the url is a styled inline piece, reason url)."""
    return ('ul', [f'{label}: `url|{URLS[k]}`' for label, k in pairs])


FLAG_ROWS = ['--settings-path', '--settings-schema', '--check-settings [path]', '--render in.png out.png', '--publish', '--engines <list>', '--pairs <list>', '--out <file>']
FLAG_DESC = {
    'ko': ['설정 파일이 어디 있는지 출력해요', '설정 파일의 JSON 스키마를 출력해요', '파일에 문제가 있는지 확인해요', '실제 파이프라인을 이미지 한 장에 돌려 봐요',
           '릴리스를 {n:GitHub}에 올려요', '시험할 엔진을 쉼표로 나열해요', '시험할 언어 쌍을 나열해요', '결과를 쓸 파일을 정해요'],
    'ja': ['設定ファイルの場所を表示します', '設定ファイルの JSON スキーマを表示します', 'ファイルに問題がないか確かめます', '実際のパイプラインを画像1枚に流します',
           'リリースを {n:GitHub} に公開します', '試すエンジンをカンマ区切りで指定します', '試す言語の組み合わせを指定します', '結果を書き出すファイルを指定します'],
    'en': ['Prints where the settings file is', 'Prints the JSON Schema of the file', 'Checks the file and exits 1 if anything is wrong', 'Runs the real pipeline on one image',
           'Publishes the release on {n:GitHub}', 'The engines to try, separated by commas', 'The language pairs to try', 'The file the results are written to'],
    'zh-Hans': ['打印设置文件的位置', '打印设置文件的 JSON Schema', '检查文件有没有问题', '对一张图片运行完整的处理流程',
                '把发布版本公开到 {n:GitHub}', '要试的引擎，用逗号隔开', '要试的语言组合', '结果写入的文件'],
}
API_IDS = ['MenuBarIcon', 'PaceStats', 'HTTPTemplate', 'ContextRoute', 'AppMemoryEditor', 'ReaderTiming', 'LensHint', 'ParagraphGrouper']
API_DESC = {
    'ko': ['메뉴 막대 아이콘의 모양을 정해요', '번역 한 줄에 걸리는 시간을 재요', '직접 만든 HTTP 엔진의 요청을 채워요', '요청에 쓸 엔진과 앱 메모리를 정해요',
           '앱별 메모리 시트의 동작을 맡아요', '글자 인식의 대기 시간을 한곳에 모아요', '렌즈 알림의 문구를 고르는 규칙이에요', '읽은 줄을 문단으로 묶어요'],
    'ja': ['メニューバーのアイコンの形を決めます', '翻訳1行にかかる時間を測ります', '自作 HTTP エンジンのリクエストを組み立てます', 'リクエストに使うエンジンとアプリのメモリを決めます',
           'アプリごとのメモリシートの動作を担当します', '文字認識の待ち時間を一か所にまとめます', 'レンズの通知文を選ぶ規則です', '読み取った行を段落にまとめます'],
    'en': ['Chooses the menu bar icon', 'Times a translated line', 'Fills in the request of a custom HTTP engine', 'Pairs the engine and the app memory for a request',
           'Runs the per-app memory sheet', 'Holds the waits of text recognition in one place', 'The rules that pick the lens pill text', 'Groups the lines read into paragraphs'],
    'zh-Hans': ['决定菜单栏图标的样子', '统计每行译文所用的时间', '填写自定义 HTTP 引擎的请求', '决定请求使用的引擎与应用记忆',
                '负责每个应用的记忆面板', '把文字识别的等待时间集中在一处', '挑选透镜提示文字的规则', '把识别出的行归并成段落'],
}
API_SLICE = {'ko': (0, 5), 'ja': (3, 8), 'en': (1, 6), 'zh-Hans': (2, 7)}
FILE_PATHS = ['scripts/release.sh', 'scripts/mas.sh', 'Config/MAS.xcconfig', 'scripts/stats.py', 'tools/engine-bench/bench.py', 'docs/settings-for-agents.md']
FILE_DESC = {
    'ko': ['공증한 디스크 이미지를 만들어요', '맥 앱 스토어용 pkg를 내보내요', 'MAS 구성의 빌드 설정이에요', '내려받기 수로 사용 통계를 계산해요', '번역 엔진의 속도와 품질을 재요', '설정 파일을 고치는 에이전트를 위한 안내예요'],
    'ja': ['公証済みのディスクイメージを作ります', 'Mac App Store 用の pkg を書き出します', 'MAS 構成のビルド設定です', 'ダウンロード数から利用統計を計算します', '翻訳エンジンの速度と品質を測ります', '設定ファイルを編集するエージェント向けの案内です'],
    'en': ['Builds the notarized disk image', 'Exports the pkg for the Mac App Store', 'Build settings of the MAS configuration', 'Computes the usage numbers from download counts', 'Measures the speed and quality of the engines', 'A guide for agents that edit the settings file'],
    'zh-Hans': ['制作经过公证的磁盘映像', '导出 Mac App Store 用的 pkg', 'MAS 配置的构建设置', '根据下载次数计算使用统计', '测量翻译引擎的速度与质量', '给编辑设置文件的代理看的说明'],
}
COMMIT_ROWS = {
    'ko': [('3a07a45', '디스크 여유 공간을 30초마다 재서 렌즈 알림에 보여 줘요'), ('7bdb093', '컴파일이 실패하면 별도의 실패로 다뤄요'), ('2da6413', '디스크 공간 안내 문구를 모든 언어로 넣었어요'), ('3871352', '앱 미리보기 영상을 만드는 스크립트예요'),
           ('e9a58d5', '앱 분류 이름을 각 언어의 낱말로 보여 줘요'), ('813d7be', '`cmd|Sent:` 줄의 낱말을 한 곳에서 관리해요')],
    'ja': [('3a07a45', 'ディスクの空きを30秒ごとに測り、レンズの表示に出します'), ('7bdb093', 'コンパイルの失敗を独立した失敗として扱います'), ('2da6413', 'ディスク容量の案内文を全言語に入れました'), ('3871352', 'アプリのプレビュー動画を作るスクリプトです'),
           ('e9a58d5', 'アプリのカテゴリ名を各言語の言葉で表示します'), ('813d7be', '`cmd|Sent:` の行の言葉を一か所で管理します')],
    'en': [('3a07a45', 'Free disk space is sampled every 30 s and shown in the lens pill'), ('7bdb093', 'A compile that fails is its own kind of failure'), ('2da6413', 'The disk space hint in every language'), ('3871352', 'Scripts that make the app preview videos'),
           ('e9a58d5', 'The app category is shown as a word in the app\'s language'), ('813d7be', 'One owner for the words of the `cmd|Sent:` line')],
    'zh-Hans': [('3a07a45', '每 30 秒检测一次磁盘剩余空间，并显示在透镜提示里'), ('7bdb093', '编译失败被当作单独的一种失败'), ('2da6413', '各语言的磁盘空间提示'), ('3871352', '制作应用预览视频的脚本'),
           ('e9a58d5', '应用类别用该语言的词语显示'), ('813d7be', '`cmd|Sent:` 行的用词由一处统一管理')],
}
TABLE_HEADS = {'ko': ('옵션', '하는 일', '이름', '하는 일', '파일', '내용', '커밋', '바뀐 내용'), 'ja': ('オプション', '意味', '名前', '役割', 'ファイル', '内容', 'コミット', '変更内容'),
               'en': ('Option', 'What it does', 'Name', 'Role', 'File', 'Contents', 'Commit', 'Change'), 'zh-Hans': ('选项', '作用', '名称', '职责', '文件', '内容', '提交', '改动')}


def flag_table(lang):
    h = TABLE_HEADS[lang]
    return ('table', [h[0], h[1]], [[f'!flag|{f}', d] for f, d in zip(FLAG_ROWS, FLAG_DESC[lang])])


def api_table(lang, full=False):
    h, (a, b) = TABLE_HEADS[lang], (0, 8) if full else API_SLICE[lang]
    return ('table', [h[2], h[3]], [[f'!id|{i}', d] for i, d in zip(API_IDS[a:b], API_DESC[lang][a:b])])


def files_table(lang):
    h = TABLE_HEADS[lang]
    return ('table', [h[4], h[5]], [[f'!path|{f}', d] for f, d in zip(FILE_PATHS, FILE_DESC[lang])])


def commits_table(lang, n=4):
    h = TABLE_HEADS[lang]
    return ('table', [h[6], h[7]], [[f'!hash|{c}', d] for c, d in COMMIT_ROWS[lang][:n]])


H2T = {'ko': ('옵션', '이름', '파일', '최근 커밋'), 'ja': ('オプション', '名前', 'ファイル', '最近のコミット'), 'en': ('Options', 'Names', 'Files', 'Recent commits'),
       'zh-Hans': ('选项', '名称', '文件', '最近的提交')}


# ------------------------------------------------------------------------------------------------------------------------- docs site chrome
def D(lang, current):
    nav = {'ko': [('시작하기', ['설치', '빠른 시작', '권한']), ('참고', ['설정 파일', '명령줄', '번역 엔진', '문제 해결'])],
           'ja': [('はじめに', ['インストール', 'クイックスタート', '権限']), ('リファレンス', ['設定ファイル', 'コマンドライン', '翻訳エンジン', 'トラブルシューティング'])],
           'en': [('Getting started', ['Install', 'Quick start', 'Permissions']), ('Reference', ['Settings file', 'Command line', 'Engines', 'Troubleshooting'])],
           'zh-Hans': [('开始使用', ['安装', '快速上手', '权限']), ('参考', ['设置文件', '命令行', '翻译引擎', '疑难解答'])]}[lang]
    t = {'ko': ('문서 검색…', '이 페이지에서', '이 페이지 고치기'), 'ja': ('ドキュメントを検索…', 'このページの内容', 'このページを編集'),
         'en': ('Search the docs…', 'On this page', 'Edit this page'), 'zh-Hans': ('搜索文档…', '本页内容', '编辑此页')}[lang]
    return dict(search=t[0], toc_title=t[1], edit=t[2], updated='2026-10-20', nav=nav, current=current)


PANE = {'ko': ('코드 조각', '%d줄'), 'ja': ('コードの断片', '%d行'), 'en': ('Snippet', '%d lines'), 'zh-Hans': ('代码片段', '%d 行')}
PANE_TITLE = {k: v[0] for k, v in PANE.items()}
PANE_STATUS = {k: v[1] for k, v in PANE.items()}
COMMITS = {'ko': '이 풀 리퀘스트의 커밋', 'ja': 'このプルリクエストのコミット', 'en': 'Commits in this pull request', 'zh-Hans': '此拉取请求的提交'}


# --------------------------------------------------------------------------------------------------------------- the author's inline reasons
# Every inline piece is written with its reason (`reason|text`); this table holds only the [[bare]] ones (code-like text drawn as plain text: uncertain keep).
INLINE.update({
    'build/mas/export/Mwoyeo.pkg': 'path', '~/.appstoreconnect/credentials.env': 'path', 'Core/Tests/MwoyeoCoreTests/PaceStatsTests.swift': 'path',
    'Config/MAS.xcconfig': 'path', 'docs/settings-for-agents.md': 'path', 'scripts/stats.py': 'path',
})


def L(lines, lang, path=None, cmd=None):
    return Listing(lines, lang, path, cmd or (f'cat {path}' if path else None))


def S(id, lang, looks, cur=None, **kw):
    d = dict(id=id, lang=lang, looks=looks, channel='dev-lens', siblings=[], listing=None, md=[], chat=[], cards=[],
             pane_title=PANE_TITLE[lang], pane_status=PANE_STATUS[lang])
    if cur: d['docs'] = D(lang, cur)
    d.update(kw)
    return d


SH_SIBLINGS = ['release.sh', 'cask.sh', 'stats.py', 'setup-release-secrets.sh']
CARD_BLUE, CARD_GREY, CARD_GREEN = '#2f6fed', '#7d838c', '#2eb67d'


def card_set(lang, build_title, build_body, git_title, git_body, actions):
    """Three or four notification cards: two of them are the app's own strings from the string catalog (real values in the language)."""
    return [
        dict(app='Mwoyeo', time='09:41', color=CARD_BLUE, title=ui('Allow screen recording', lang),
             body=ui('Put a lens on the screen. The text under it is erased and rewritten in your language.', lang)),
        dict(app='Terminal', time='09:43', color=CARD_GREY, title=build_title, body=build_body,
             code=[Line('Build complete! (53.44' + {'ko': '초', 'ja': '秒', 'zh-Hans': '秒', 'en': 's'}[lang] + ')', 'log', opt=lang != 'en')]),
        dict(app='Mwoyeo', time='09:45', color=CARD_BLUE, title=ui('Text recognition isn’t responding', lang),
             body=ui("macOS text recognition isn't responding. Restarting the Mac usually fixes it.", lang), actions=actions),
        dict(app='Git', time='09:50', color=CARD_GREEN, title=git_title, body=git_body),
    ]


REVIEW = {
    'ko': dict(title='엔진 권한 안내가 요청이 보내는 메모리와 어긋나지 않게 해요', meta='{n:dana}님이 {t:10월 19일}에 이 풀 리퀘스트를 열었어요 · 커밋 {t:6}개 · `url|' + GH + '/pull/231`',
               comments=[('minjun', '오전 10:12', [('p', '`id|memoryProfiles(_:profiles:)`는 이제 `id|customEngineID`를 묻지 않아요. 앞에 올 수 있는 엔진은 어떤 것이든 될 수 있기 때문이에요.')])],
               commits=[('b459840', '엔진 권한: 앞에 올 수 있는 모든 엔진에 앱의 메모리를 알려요'), ('d0c8bea', '요청과 `cmd|Sent:` 미리보기가 `id|ContextRoute`를 거쳐요'),
                        ('b94f122', '`id|ContextRoute`가 엔진과 메모리의 짝을 한 곳에서 정해요'), ('54e8ff0', '프로필의 ⋯ 메뉴에서 앱별 메모리 시트를 열어요'),
                        ('99da05c', '메모리 시트의 논리를 `id|AppMemoryEditor`에 모아요'), ('4cf0a5a', '메모리 시트 검사: 편집, 상한, 고정, 삭제, 새로 시작')]),
    'ja': dict(title='設定画面にアプリごとのメモリの要約と「メモリ…」メニューを足しました', meta='{n:sato} さんが {t:10月19日} にこのプルリクエストを開きました · コミット {t:6} 件 · `url|' + GH + '/pull/231`',
               comments=[('tanaka', '午前 10:12', [('p', '`id|profileLabel`は、メモリがあるときだけ要約を出します。長すぎる場合は、まずそこが省略されます。')])],
               commits=[('63d28f6', '設定: プロファイル行のメモリの要約と、⋯ メニューの「メモリ…」'), ('99da05c', 'メモリシートのロジックを `id|AppMemoryEditor` にまとめる'),
                        ('a7aa142', '文字列: メモリシート（英語のみ、他の言語は確認待ち）'), ('f364179', '文字列（韓国語）: エンジンの文脈とメモリシート'),
                        ('11bf9af', 'UI キャプチャ: メモリシートの場面と `cmd|check-logic` の配線'), ('b2546c0', 'アクセシビリティ検査: メモリシートの監査')]),
    'en': dict(title='Engine permissions: tell the person about every engine that can be in front', meta='{n:dana} opened this pull request on {t:Oct 19} · {t:6} commits · `url|' + GH + '/pull/231`',
               comments=[('minjun', '10:12 AM', [('p', 'The profile\'s own `id|customEngineID` is no longer asked. Any engine can be the one in front, so every profile with memory is a candidate.')])],
               commits=[('b459840', 'Engine permissions: disclose an app\'s memory to every engine that can be in front'), ('d0c8bea', 'Requests and the `cmd|Sent:` preview go through `id|ContextRoute`'),
                        ('b94f122', '`id|ContextRoute`: one owner for which engine and which memory a request pairs'), ('54e8ff0', 'Memory sheet: the per-app sheet from the profile\'s ⋯ menu'),
                        ('99da05c', '`id|AppMemoryEditor` holds the sheet\'s logic'), ('4cf0a5a', 'Memory sheet checks: editing, caps, pin, remove, forget, start fresh')]),
    'zh-Hans': dict(title='设置页：每个应用一行记忆摘要，以及“记忆…”菜单', meta='{n:sato} 在 {t:10 月 19 日} 创建了此拉取请求 · {t:6} 个提交 · `url|' + GH + '/pull/231`',
                    comments=[('tanaka', '上午 10:12', [('p', '`id|profileLabel` 只在有记忆时才显示摘要。空间不够时，最先被截短的就是它。')])],
                    commits=[('63d28f6', '设置：应用行的记忆摘要，以及 ⋯ 菜单里的“记忆…”'), ('99da05c', '记忆面板的逻辑集中到 `id|AppMemoryEditor`'),
                             ('a7aa142', '字符串：记忆面板（仅英文，其他语言待审）'), ('f364179', '字符串（韩语）：引擎上下文与记忆面板'),
                             ('11bf9af', '界面截图：记忆面板场景与 `cmd|check-logic` 接线'), ('b2546c0', '无障碍检查：记忆面板审计')]),
}


def review(lang, diff):
    r = REVIEW[lang]
    return dict(title=r['title'], meta=r['meta'], file='App/Support/EnginePermission.swift' if diff is DIFF_PERM else 'App/UI/SettingsView.swift',
                diff=diff, comments=r['comments'], commits=r['commits'], commits_title=COMMITS[lang])


# -------------------------------------------------------------------------------------------------------------------------------------- ko
CLI_KO = [('h1', '터미널에서 쓰는 옵션과 단축키'),
          ('p', '앱을 켜지 않고도 설정 파일을 읽고 확인할 수 있어요. 아래 옵션은 모두 `cmd|Mwoyeo` 뒤에 붙여 써요. 릴리스는 `path|scripts/release.sh`로 만들어요.'),
          ('h2', H2T['ko'][0]), flag_table('ko'),
          C(RELEASE_CMDS, 'sh'),
          ('h2', '터미널 단축키'),
          ('table', ['단축키', '하는 일'], keys_rows(1)),
          ('h2', '자료'),
          res(('릴리스', 'releases'), ('이슈', 'issues'), ('설정 안내', 'settings'), ('내려받기', 'dmg'), ('기여', 'contrib'), ('저장소', 'repo'))]
STATS_KO_MD = [('h1', '월간 사용자 수는 어떻게 세나요?'),
               ('p', '`path|scripts/stats.py`의 `id|monthly_active`는 이번 달 이전의 마지막 행과 지금 값의 차이를 구해요. 설치마다 `config|month.json`을 한 달에 한 번만 내려받아요.'),
               C(STATS_KO, 'py', 'scripts/stats.py'),
               ('p', '숫자는 `id|short`가 `log|1.2k`처럼 줄여서 보여 줘요.'),
               ('h2', '자료'),
               res(('릴리스', 'releases'), ('이슈', 'issues'))]
STRINGS_KO_MD = [('h1', '문자열 카탈로그 읽는 법'),
                 ('p', '앱의 모든 화면 문구는 `path|Localizable.xcstrings`에 있어요. 문구마다 `config|localizations` 아래에 언어별 `config|stringUnit`이 하나씩 붙어요.'),
                 C(CATALOG_KO, 'json', 'App/Resources/Localizable.xcstrings'),
                 ('h2', '상태 값'),
                 ('p', '번역이 끝난 문구는 `config|"state": "translated"`로 적혀 있어요. 영어 원문이 문구의 이름이라서 `config|Allow screen recording`처럼 찾아보면 돼요.'),
                 ('h2', H2T['ko'][3]), commits_table('ko'),
                 ('h2', '자료'),
                 res(('저장소', 'repo'), ('릴리스', 'releases'), ('이슈', 'issues'))]
MAS_KO_MD = [('h1', '맥 앱 스토어용 빌드 만들기'),
             ('p', '`path|scripts/mas.sh`는 `config|MAS` 구성으로 앱을 빌드해서 {n:App Store Connect}에 올릴 `path|Mwoyeo.pkg`를 내보내요. 인증 정보는 환경 변수 `id|MWOYEO_MAS_IDENTITY`와 `id|MWOYEO_MAS_PROFILE`로만 받아요.'),
             C(MAS, 'sh', 'scripts/mas.sh'),
             ('p', '실행은 `cmd|scripts/mas.sh`만 치면 돼요. 결과물은 [[build/mas/export/Mwoyeo.pkg]]에 생겨요.'),
             ('h2', '자료'),
             res(('저장소', 'repo'), ('릴리스', 'releases'))]
CHAT_KO = [('dana', '오전 9:12', [('p', '`path|scripts/release.sh`에 `flag|--publish`를 붙이면 {n:GitHub} 릴리스까지 올라가나요?')]),
           ('minjun', '오전 9:14', [('p', '네, {n:Homebrew} cask까지요. 먼저 `id|MWOYEO_RELEASE_IDENTITY`를 설정하세요.'), C(RELEASE_CMDS, 'sh')]),
           ('dana', '오전 9:20', [('p', '`cmd|brew upgrade mwoyeo`로 받아 보고 알려 드릴게요.')])]

# -------------------------------------------------------------------------------------------------------------------------------------- ja
RELEASE_JA_MD = [('h1', 'ディスクイメージを作って公証に出す'),
                 ('p', '`path|scripts/release.sh`は、アプリを`cmd|hdiutil`で{n:DMG}にまとめ、署名してから`cmd|xcrun notarytool`で公証に出します。'),
                 C(RELEASE, 'sh', 'scripts/release.sh'),
                 ('h2', '確認のしかた'),
                 ('p', '最後に`cmd|spctl`で評価し、ハッシュを`id|SHA`に入れて表示します。公開するときは`flag|--publish`を付けます。'),
                 ('h2', '参考リンク'),
                 res(('リリース', 'releases'), ('スクリプト', 'release'), ('Homebrew の tap', 'tap'))]
MENU_JA_MD = [('h1', 'メニューバーのアイコンのテスト'),
              ('p', '`path|MenuBarIconTests.swift`は、状態ごとにアイコンの形を確かめます。`id|MenuBarIcon`の`id|symbol`が状態に従います。'),
              C(MENU, 'swift', 'Core/Tests/MwoyeoCoreTests/MenuBarIconTests.swift'),
              ('p', '一時停止は意図的なものなので、`id|badge`は出ません。'),
              ('h2', '参考リンク'),
              res(('リリース', 'releases'), ('リポジトリ', 'repo'))]
STRINGS_JA_MD = [('h1', '日本語の文字列を確認する'),
                 ('p', '`path|Localizable.xcstrings`の`config|"Not set"`を見ると、`config|ko`と`config|ja`の訳が並んでいます。'),
                 C(CATALOG_JA, 'json', 'App/Resources/Localizable.xcstrings'),
                 ('p', '状態は`config|translated`です。新しい文言は英語だけを先に入れ、他の言語は後から足します。'),
                 ('h2', H2T['ja'][3]), commits_table('ja'),
                 ('h2', '参考リンク'),
                 res(('リリース', 'releases'), ('課題', 'issues'), ('リポジトリ', 'repo'))]
CLI_JA = [('h1', 'コマンドラインのオプションとショートカット'),
          ('p', '`path|tools/engine-bench`の`cmd|bench.py`は、次のオプションで対象を絞れます。鍵は環境変数から読み、ファイルには書きません。'),
          ('h2', H2T['ja'][0]), flag_table('ja'),
          C(BENCH_CMDS, 'sh'),
          ('h2', 'ターミナルのショートカット'),
          ('table', ['ショートカット', '動作'], keys_rows(2)),
          ('h2', '参考リンク'),
          res(('ベンチ', 'bench'), ('モックサーバー', 'mock'), ('リリース', 'releases'), ('課題', 'issues'), ('スクリプト', 'release'), ('リポジトリ', 'repo'))]
CHAT_JA = [('sato', '午前 10:02', [('p', '公証が終わったか確かめたいです。`cmd|xcrun stapler staple`の後に何を見ればいいですか？')]),
           ('tanaka', '午前 10:05', [('p', '`cmd|spctl --assess`の出力に`log|accepted`と出れば大丈夫です。'), C(RELEASE[-5:-1], 'sh')]),
           ('sato', '午前 10:09', [('p', '見られました。ありがとうございます。リンクは`url|' + URLS['release'] + '`ですね。')])]

# -------------------------------------------------------------------------------------------------------------------------------------- en
HTTP_EN_MD = [('h1', 'How the HTTP template encodes text'),
              ('p', 'The tests in `path|HTTPTemplateTests.swift` show where the text of a line goes: into a query string or a form body, percent-encoded.'),
              C(HTTP, 'swift', 'Core/Tests/MwoyeoCoreTests/HTTPTemplateTests.swift'),
              ('p', 'A JSON body is escaped instead, with or without quotes around `config|{{text}}`. The key goes in as `config|{{key}}`.'),
              ('h2', 'Links'),
              res(('Source', 'repo'), ('Mock server', 'mock'))]
APPPROFILE_EN_MD = [('h1', 'Per-app memory'),
                    ('p', 'Inside `config|appProfiles`, a profile can carry a `config|note` for the translator. A profile still needs `config|bundleID`, `config|source` and `config|target`.'),
                    C(APPPROFILE_EN, 'json', 'settings.json'),
                    ('h2', 'Check the file'),
                    ('p', 'Run `cmd|Mwoyeo --check-settings`. It prints one line for each problem, and exits with 1:'),
                    C(SETTINGS_ISSUES[1:], 'term'),
                    ('h2', H2T['en'][3]), commits_table('en'),
                    ('h2', 'Links'),
                    res(('Source', 'settings'), ('Releases', 'releases'), ('Issues', 'issues'))]
CLI_EN = [('h1', 'Settings checks and the mock server'),
          ('p', 'Every option below goes after `cmd|Mwoyeo`. They read or check the settings without starting the app. The mock server takes a port and a mode:'),
          C(MOCK_CMD, 'sh'),
          ('h2', H2T['en'][0]), flag_table('en'),
          ('table', ['Mode', 'Answer'], [['!config|ok', 'Answers every request'], ['!config|slow:<ms>', 'Waits before it answers'],
                                         ['!config|429', 'Answers with a Retry-After of 7'], ['!config|hang', 'Never answers']]),
          ('h2', 'Terminal shortcuts'),
          ('table', ['Shortcut', 'What it does'], keys_rows(4)),
          ('h2', 'Links'),
          res(('Mock server', 'mock'), ('Releases', 'releases'), ('Download', 'dmg'), ('Contributing', 'contrib'), ('Bench', 'bench'), ('Source', 'repo'))]
CONTRIB_EN = [('h1', 'Pull requests'),
              ('ul', [must_have('CONTRIBUTING.md', 'Keep a PR to one change. Small PRs are easier to review.'),
                      'Run `cmd|' + must_have('CONTRIBUTING.md', 'cd Core && swift test') + '`. Build steps are in the [README](README.en.md#development).',
                      'If you change how text is read, erased or drawn, `cmd|' + must_have('CONTRIBUTING.md', 'Mwoyeo --render in.png out.png') + '` runs the real pipeline on an image. Before and after images in the PR help a lot.',
                      must_have('CONTRIBUTING.md', 'PRs are merged with a merge commit, so your commits stay in the history as you wrote them.')]),
              ('h2', 'AI-assisted contributions'),
              ('p', must_have('CONTRIBUTING.md', 'Contributions made with AI tools are welcome, issues and PRs alike. You do not need to say that you used one.') +
                    ' Please check that the change works, as you would with any change.'),
              ('h2', 'Where to look'),
              res(('Contributing', 'contrib'), ('Issues', 'issues'), ('Source', 'repo'))]
CARDS_EN = card_set('en', 'Build finished', '`cmd|swift build -c release` is done. The last line of its output:', 'Pushed', '`hash|3a07a45` is on `id|main`: `url|' + URLS['commit'] + '`', ['Restart', 'Close'])
CARDS_KO = card_set('ko', '빌드가 끝났어요', '`cmd|swift build -c release`가 끝났어요. 출력의 마지막 줄이에요:', '푸시했어요', '`hash|3a07a45`이 `id|main`에 올라갔어요: `url|' + URLS['commit'] + '`', ['다시 시작', '닫기'])
CARDS_ZH = card_set('zh-Hans', '构建已完成', '`cmd|swift build -c release` 已完成。输出的最后一行：', '已推送', '`hash|3a07a45` 已推送到 `id|main`：`url|' + URLS['commit'] + '`', ['重新启动', '关闭'])


# -------------------------------------------------------------------------------------------------------------------------------------- zh-Hans
def pick(lines, first, n):
    k = next(i for i, l in enumerate(lines) if first in l.text)
    return lines[k:k + n]


SECRETS_ZH_MD = [('h1', '把签名证书和公证密钥放进 {n:GitHub} secrets'),
                 ('p', '`path|scripts/setup-release-secrets.sh` 只需要在装有证书的那台 {n:Mac} 上运行一次。公证密钥从 [[~/.appstoreconnect/credentials.env]] 读取，也可以用环境变量 `id|MWOYEO_NOTARY_KEY` 指定。'),
                 C(SECRETS, 'sh', 'scripts/setup-release-secrets.sh'),
                 ('p', '运行方式：`cmd|' + must_have('scripts/setup-release-secrets.sh', 'scripts/setup-release-secrets.sh ~/Desktop/devid.p12') + '`。'),
                 ('h2', '链接'),
                 res(('发布页', 'releases'), ('仓库', 'repo'))]
PACE_ZH_CHAT = [('lin', '上午 10:20', [('p', '`id|expectedSeconds` 在第一行译文出来之前为什么是 `id|nil`？')]),
                ('wei', '上午 10:23', [('p', '因为 `id|PaceStats` 按语言组合和引擎分别计时。换一个组合，它还什么都不知道：'), C(pick(PACE, 'p.use(ja)', 2), 'swift')]),
                ('lin', '上午 10:25', [('p', '明白了，谢谢！')])]
STRINGS_ZH_MD = [('h1', '怎么读字符串目录'),
                 ('p', '界面上的每一句话都在 `path|Localizable.xcstrings` 里。比如 `config|Paste Setup` 这一条，下面有日语和简体中文两种译文：'),
                 C(CATALOG_ZH, 'json', 'App/Resources/Localizable.xcstrings'),
                 ('h2', '语言代码'),
                 ('p', '简体中文的代码是 `config|zh-Hans`，繁体中文是 `config|zh-Hant`。每条译文的 `config|state` 都是 `config|translated`。'),
                 ('h2', H2T['zh-Hans'][3]), commits_table('zh-Hans'),
                 ('h2', '链接'),
                 res(('仓库', 'repo'), ('发布页', 'releases'), ('议题', 'issues'))]
CLI_ZH = [('h1', '命令行选项与终端快捷键'),
          ('p', '安装用 `cmd|brew install midagedev/tap/mwoyeo`，更新用 `cmd|brew upgrade mwoyeo`。下面的选项都写在 `cmd|Mwoyeo` 后面。'),
          ('h2', H2T['zh-Hans'][0]), flag_table('zh-Hans'),
          ('h2', '终端快捷键'),
          ('table', ['快捷键', '作用'], keys_rows(3)),
          ('h2', '链接'),
          res(('发布页', 'releases'), ('议题', 'issues'), ('下载', 'dmg'), ('图像修复模型', 'migan'), ('仓库', 'repo'), ('脚本', 'release'))]
README_ZH_A = [('h2', '系统要求'),
               ('table', ['', ''], [['**{n:macOS}**', '26.0 或更高版本（不用语言包翻译和*高保真*引擎需要 26.4 或更高版本）'],
                                    ['**权限**', '只需“屏幕录制”，不需要“辅助功能”，也不监听键盘'],
                                    ['**网络**', '默认设置下翻译不需要联网。唯一的网络请求是每天一次的更新检查，可以关掉。你自己添加的云端引擎是唯一的例外。'],
                                    ['**磁盘**', '{n:App} 本身约 {t:20 MB}。语言包（以及 {n:Apple Intelligence} 模型，最多 {t:8–14 GB}）由 {n:macOS} 负责下载和存放。']]),
               ('h2', '安装'),
               ('p', '也可以直接[下载磁盘映像](https://github.com/midagedev/mwoyeo/releases/latest/download/Mwoyeo-arm64.dmg)，把 {n:Mwoyeo} 拖进“应用程序”文件夹。{n:App} 已签名并经过公证。'),
               C([Line('brew install midagedev/tap/mwoyeo', 'cmd')], 'sh'),
               ('p', '用 `cmd|brew upgrade mwoyeo` 更新，或者下载新的磁盘映像即可。')]
README_ZH_B = [('h2', '小技巧与常见问题'),
               ('ul', ['**一直卡在“正在翻译…”？** 多半是没装语言包，到“设置 › 翻译”里下载即可。',
                       '**名字翻得不对**（角色名、地名、用户名）？把它们加进术语表，再选*术语表优先*。',
                       '**更新后什么都不显示？** {n:macOS} 有时会重新索要屏幕录制权限。到“系统设置”里确认一下，然后重新打开 {n:Mwoyeo}。']),
               ('h2', '术语表'),
               ('p', '专有名词，每行一条 `config|original = translation`。设置里的 {n:Markdown} 记录默认放在 `path|~/Documents/Mwoyeo`。'),
               ('h2', H2T['zh-Hans'][3]), commits_table('zh-Hans'),
               ('h2', '链接'),
               res(('发布页', 'releases'), ('下载', 'dmg'), ('图像修复模型', 'migan'))]


def _plain(s):
    s = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', s)
    s = re.sub(r'\{[nt]:([^}]+)\}|\[\[([^\]]+)\]\]', lambda m: m.group(1) or m.group(2), s)
    s = re.sub(r'`(?:\w+\|)?([^`]+)`', r'\1', s)
    return re.sub(r'\s+', ' ', re.sub(r'[*`]', '', s)).strip()


_zh = repo_text('README.zh-CN.md')
note_source('README.zh-CN.md', 'repo-file', f'git show {PIN}:README.zh-CN.md', _zh)
_zh_all = _plain(_zh)
for _b in README_ZH_A + README_ZH_B:
    _texts = [_b[1]] if _b[0] in ('h2', 'p') else (_b[1] if _b[0] == 'ul' else [c for r in _b[2] for c in r] if _b[0] == 'table' else [])
    for _t in _texts:
        if _b[0] in ('h2',) and _t in ('术语表', '链接', '最近的提交'): continue          # headings of the scene, not passages of the README
        if _t.startswith(('专有名词', '用 `cmd|brew upgrade', '运行方式', '!hash|')) or 'url|' in _t or _b[0] == 'table' and '!hash|' in _b[2][0][0]: continue
        if _plain(_t) not in _zh_all: raise SystemExit(f'h3: not in README.zh-CN.md@{PIN}: {_plain(_t)[:70]!r}')


def ref_page(lang, title, intro, links_title, links):
    return [('h1', title), ('p', intro),
            ('h2', H2T[lang][1]), api_table(lang, full=True),
            ('h2', H2T[lang][2]), files_table(lang),
            ('h2', H2T[lang][3]), commits_table(lang, 6),
            ('h2', links_title), res(*links)]


REF_KO = ref_page('ko', '코드 이름과 파일 한눈에 보기', '이 문서에서 가장 자주 나오는 이름과 파일, 그리고 최근 커밋이에요.', '자료', (('저장소', 'repo'), ('릴리스', 'releases'), ('이슈', 'issues')))
REF_JA = ref_page('ja', '主な名前とファイルの一覧', 'このドキュメントによく出てくる名前とファイル、最近のコミットをまとめました。', '参考リンク', (('リポジトリ', 'repo'), ('リリース', 'releases'), ('課題', 'issues')))
REF_EN = ref_page('en', 'Names, files and recent commits', 'The names and files that come up most in these docs, and the latest commits.', 'Links', (('Source', 'repo'), ('Releases', 'releases'), ('Issues', 'issues')))
REF_ZH = ref_page('zh-Hans', '常用名称、文件与最近提交', '文档里最常出现的名称、文件，以及最近的提交。', '链接', (('仓库', 'repo'), ('发布页', 'releases'), ('议题', 'issues')))


# ------------------------------------------------------------------------------------------------------------------------------- scenes
CAT = 'App/Resources/Localizable.xcstrings'
SCENES = [
    # ko
    S('mas-ko', 'ko', ['term-solarized', 'pane-dark', 'md-sepia'], listing=L(MAS, 'sh', 'scripts/mas.sh', 'cat scripts/mas.sh'), siblings=SH_SIBLINGS, md=MAS_KO_MD),
    S('strings-ko', 'ko', ['ide-solar', 'docs-light'], cur='설정 파일', listing=L(CATALOG_KO, 'json', CAT), siblings=['InfoPlist.xcstrings', 'PrivacyInfo.xcprivacy'], md=STRINGS_KO_MD),
    S('cli-ko', 'ko', ['docs-light', 'md-night'], cur='명령줄', md=CLI_KO),
    S('review-ko', 'ko', ['review-light', 'review-dark'], review=review('ko', DIFF_PERM)),
    S('cards-ko', 'ko', ['card-light', 'card-dark'], cards=CARDS_KO),
    S('chat-ko', 'ko', ['chat-dark-plain'], channel='dev-release', chat=CHAT_KO),
    S('ref-ko', 'ko', ['docs-dark', 'md-sepia'], cur='설정 파일', md=REF_KO),
    S('nl-ko', 'ko', ['term-green', 'term-solarized'], listing=Listing([Line('$ nl -ba scripts/stats.py | sed -n 44,54p', 'cmd')] + NL_KO, 'term')),
    S('stats-ko', 'ko', ['pane-light', 'md-night'], listing=L(STATS_KO, 'py', 'scripts/stats.py'), md=STATS_KO_MD),
    # ja
    S('release-ja', 'ja', ['ide-solar', 'docs-light'], cur='コマンドライン', listing=L(RELEASE, 'sh', 'scripts/release.sh'), siblings=SH_SIBLINGS, md=RELEASE_JA_MD),
    S('menu-ja', 'ja', ['pane-light', 'md-night'], listing=L(MENU, 'swift', 'Core/Tests/MwoyeoCoreTests/MenuBarIconTests.swift'), md=MENU_JA_MD),
    S('strings-ja', 'ja', ['pane-dark', 'md-sepia'], listing=L(CATALOG_JA, 'json', CAT), md=STRINGS_JA_MD),
    S('cli-ja', 'ja', ['docs-dark', 'md-sepia'], cur='コマンドライン', md=CLI_JA),
    S('review-ja', 'ja', ['review-dark', 'review-light'], review=review('ja', DIFF_SETTINGS)),
    S('ref-ja', 'ja', ['md-night', 'docs-light'], cur='設定ファイル', md=REF_JA),
    S('stat-ja', 'ja', ['term-solarized'], listing=Listing(STAT, 'term')),
    S('nl-ja', 'ja', ['term-solarized', 'term-green'], listing=Listing([Line('$ nl -ba scripts/release.sh | sed -n 52,62p', 'cmd')] + NL_JA + DATE_JA, 'term')),
    S('chat-ja', 'ja', ['chat-mint'], channel='dev-release', chat=CHAT_JA),
    # en
    S('stats-en', 'en', ['ide-solar', 'pane-dark'], listing=L(STATS_EN, 'py', 'scripts/stats.py'), siblings=SH_SIBLINGS),
    S('http-en', 'en', ['term-solarized', 'md-sepia'], listing=L(HTTP, 'swift', 'Core/Tests/MwoyeoCoreTests/HTTPTemplateTests.swift', 'cat Core/Tests/MwoyeoCoreTests/HTTPTemplateTests.swift'), md=HTTP_EN_MD),
    S('appprofile-en', 'en', ['pane-light', 'docs-light'], cur='Settings file', listing=L(APPPROFILE_EN, 'json', 'settings.json'), md=APPPROFILE_EN_MD),
    S('cli-en', 'en', ['docs-light', 'md-night'], cur='Command line', md=CLI_EN),
    S('review-en', 'en', ['review-light', 'review-dark'], review=review('en', DIFF_PERM)),
    S('cards-en', 'en', ['card-light'], cards=CARDS_EN),
    S('contrib-en', 'en', ['docs-dark'], cur='Quick start', md=CONTRIB_EN),
    S('ref-en', 'en', ['md-sepia', 'docs-dark'], cur='Settings file', md=REF_EN),
    S('blame-en', 'en', ['term-green'], listing=Listing(BLAME, 'term')),
    S('bench-en', 'en', ['term-solarized'], listing=Listing(BENCH + LS, 'term')),
    # zh-Hans
    S('secrets-zh', 'zh-Hans', ['term-green', 'md-night'], listing=L(SECRETS, 'sh', 'scripts/setup-release-secrets.sh', 'cat scripts/setup-release-secrets.sh'), md=SECRETS_ZH_MD),
    S('pace-zh', 'zh-Hans', ['ide-solar', 'chat-mint'], channel='dev-tests', listing=L(PACE, 'swift', 'Core/Tests/MwoyeoCoreTests/PaceStatsTests.swift'), siblings=['HTTPTemplateTests.swift', 'MenuBarIconTests.swift'], chat=PACE_ZH_CHAT),
    S('strings-zh', 'zh-Hans', ['docs-dark', 'pane-light'], cur='设置文件', listing=L(CATALOG_ZH, 'json', CAT), md=STRINGS_ZH_MD),
    S('cli-zh', 'zh-Hans', ['docs-light', 'md-sepia'], cur='命令行', md=CLI_ZH),
    S('review-zh', 'zh-Hans', ['review-light', 'review-dark'], review=review('zh-Hans', DIFF_SETTINGS)),
    S('readme-zh-a', 'zh-Hans', ['md-sepia', 'docs-light'], cur='快速上手', md=README_ZH_A),
    S('readme-zh-b', 'zh-Hans', ['md-night'], md=README_ZH_B),
    S('ref-zh', 'zh-Hans', ['docs-dark', 'md-night'], cur='设置文件', md=REF_ZH),
    S('nl-zh', 'zh-Hans', ['term-solarized', 'term-green'], listing=Listing([Line('$ nl -ba scripts/setup-release-secrets.sh | sed -n 12,24p', 'cmd')] + NL_ZH + DATE_ZH, 'term')),
    S('cards-zh', 'zh-Hans', ['card-dark'], cards=CARDS_ZH),
]
