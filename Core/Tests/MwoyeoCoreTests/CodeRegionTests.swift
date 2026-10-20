import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// Geometry in picture pixels, a line 30 px tall on a 36 px pitch, the page margin at x=60. The shapes are the ones of
/// tools/keep-labels (cases k01 to k12, the two papers): a code box tinted by 9 levels, a dark terminal view, an indented listing.
@Suite struct CodeRegionTests {
    private let white = RGBA(255, 255, 255)
    private let lightBox = RGBA(246, 248, 250)        // a code box on a white page: 9 levels
    private let darkBox = RGBA(30, 30, 30)

    /// One block of `lines` whose first line starts at (x, y); stacked blocks are 36 px apart per line.
    private func block(_ lines: [String], x: Double = 60, y: Double, bg: RGBA? = nil) -> CodeRegion.Block {
        let lh = 30.0
        let ls = lines.enumerated().map { i, t in
            CodeRegion.Line(text: t, rect: CGRect(x: x, y: y + Double(i) * 36, width: Double(t.count) * 15, height: lh))
        }
        let w = ls.map(\.rect.width).max() ?? 0
        return CodeRegion.Block(text: lines.joined(separator: " "), rect: CGRect(x: x, y: y, width: w, height: Double(lines.count - 1) * 36 + lh),
                                lines: ls, background: bg ?? white)
    }

    /// Blocks stacked one under another, one line each, starting at y.
    private func stack(_ lines: [String], x: Double = 60, y: Double = 100, bg: RGBA? = nil) -> [CodeRegion.Block] {
        lines.enumerated().map { block([$1], x: x, y: y + Double($0) * 40, bg: bg) }
    }

    /// The words of a line with boxes: every character 15 px wide (a typeface of fixed pitch), or each word at its own width per character.
    private func words(_ line: String, x: Double = 90, fixed: Bool = true) -> [CodeRegion.Word] {
        var at = x
        return line.split(separator: " ").enumerated().map { i, w in
            let width = Double(w.count) * 15 * (fixed ? 1 : [0.72, 1.0, 1.35, 0.9][i % 4])
            defer { at += width + 15 }
            return CodeRegion.Word(text: String(w), rect: CGRect(x: at, y: 0, width: width, height: 30))
        }
    }

    /// `stack` with the boxes of the words (fixed or proportional pitch).
    private func spoken(_ lines: [String], fixed: Bool, bg: RGBA? = nil) -> [CodeRegion.Block] {
        stack(lines, x: 90, y: 200, bg: bg).enumerated().map { i, b in
            var b = b
            b.lines[0].words = words(lines[i], fixed: fixed)
            return b
        }
    }

    private func verdicts(_ blocks: [CodeRegion.Block]) -> [CodeRegion.Reason?] {
        CodeRegion.keep(blocks: blocks, frameBackground: white)
    }

    private func prose(_ y: Double) -> CodeRegion.Block { block(["Install the latest release and check the version."], y: y) }

    // MARK: code

    @Test func aTintedBoxOfCodeIsKeptWhole() {
        let box = stack(["const nested = [1, 12, [3, [4]]];", "// flatten every level at once", "console.log(flat); // [1, 2, 3, 4]"], x: 90, y: 200, bg: lightBox)
        #expect(verdicts([prose(100)] + box) == [nil, .code, .code, .code])
    }

    @Test func aCalloutBoxOfProseIsTranslated() {
        // Tinted, stacked, a keyword-like word or two ("to", "in", "if"): a box is a container of prose as often as of code.
        let box = stack(["Tip: if you want to see the balance of one account,", "pass its name in the command line and press Enter.",
                         "The report is printed to the terminal."], x: 90, y: 200, bg: lightBox)
        #expect(verdicts([prose(100)] + box) == [nil, nil, nil, nil])
    }

    @Test func aBoxOfCJKProseIsTranslated() {
        let box = stack(["이 설정은 기본값을 사용합니다.", "필요하면 설정 파일에서 바꿀 수 있습니다."], x: 90, y: 200, bg: lightBox)
        #expect(verdicts(box) == [nil, nil])
    }

    @Test func aCommentInAnyScriptIsCodeBecauseOfWhereItSits() {
        let box = stack(["C = Canvas(640, 480) # 캔버스를 만든다", "C.fill(\"#ffffff\") # 흰색으로 채운다"], x: 90, y: 200, bg: lightBox)
        #expect(verdicts(box) == [.code, .code])
        let ja = stack(["// 合計を計算する", "total = sum(prices);"], x: 90, y: 200, bg: lightBox)
        #expect(verdicts(ja) == [.code, .code])
    }

    @Test func aListingIndentedWithLineNumbersIsKeptWithoutAnyTint() {
        // Pseudo-code of an algorithm box: the numbers are blocks of their own beside the lines.
        var blocks = [block(["Algorithm 1 groups the lines greedily."], y: 80)]
        let code = [("3:", "if d < T then"), ("4:", "append I to the last group of G"), ("5:", "else"), ("6:", "open a new group"), ("7:", "end if"), ("8:", "return G")]
        for (i, (n, t)) in code.enumerated() {
            blocks.append(block([n], x: 60, y: 200 + Double(i) * 40))
            blocks.append(block([t], x: 150, y: 200 + Double(i) * 40))
        }
        let v = verdicts(blocks)
        #expect(v[0] == nil)
        #expect(v.dropFirst().allSatisfy { $0 == .code })
    }

    @Test func oneCodeLineAloneNeedsStrongEvidence() {
        #expect(verdicts([block(["console.log(flat); // [1, 2, 3, 4]"], y: 100)]) == [nil])             // one comment: not enough alone
        #expect(verdicts([block(["if (x) { return null; }"], y: 100)]) == [.code])                      // keywords and line end
        #expect(verdicts([block(["The function returns null when the key is missing."], y: 100)]) == [nil])
    }

    // MARK: what H2 found (round k3b, 2026-10-20)

    private let testLog = ["Building for debugging...", "Test Suite 'All tests' started at 2026-10-20 08:12:52.200.",
                           "Test Case 'LensCalmTests testBlipDuringShownDoesNotTurnOff' passed", "Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds"]

    @Test func outputInATypefaceOfFixedPitchIsKeptInABox() {
        // No keyword, no symbol, no line end: only the typeface says it is output. In a box (a tint) or an indented run, that is enough.
        #expect(verdicts([prose(100)] + spoken(testLog, fixed: true, bg: darkBox)) == [nil, .code, .code, .code, .code])
        #expect(verdicts([prose(100)] + spoken(testLog, fixed: true)) == [nil, .code, .code, .code, .code])             // indented under the paragraph
        // The same words set in a proportional face, or with no word boxes: prose.
        #expect(verdicts([prose(100)] + spoken(testLog, fixed: false, bg: darkBox)).allSatisfy { $0 == nil })
        #expect(verdicts([prose(100)] + stack(testLog, x: 90, y: 200, bg: darkBox)).allSatisfy { $0 == nil })
    }

    @Test func aFixedPitchAloneOutsideABoxKeepsNothing() {
        var lone = block([testLog[1]], x: 60, y: 200)
        lone.lines[0].words = words(testLog[1], x: 60)
        #expect(verdicts([lone]) == [nil])
    }

    @Test func theWidthPerCharacterOfThreeAsciiWordsSaysFixedPitch() {
        func box(_ text: String, _ width: Double) -> CodeRegion.Word { .init(text: text, rect: CGRect(x: 0, y: 0, width: width, height: 30)) }
        #expect(CodeRegion.fixedPitch([box("Test", 60), box("Suite", 75), box("started", 105)]) == true)
        #expect(CodeRegion.fixedPitch([box("Test", 60), box("Suite", 75)]) == nil)                                  // two words are no measure
        #expect(CodeRegion.fixedPitch([box("Test", 40), box("Suite", 75), box("started", 105)]) == false)           // 10 against 15 px a character
        #expect(CodeRegion.fixedPitch([box("Test", 60), box("は", 15), box("Suite", 75), box("設定", 30)]) == nil)   // words that are not ASCII do not count
        #expect(CodeRegion.fixedPitch([box("Test", 60), box("Suite", 75), box("started", 105), box("は", 15), box("の", 40)]) == true)
        // Prose with inline code: the chips are set in a fixed face too, but they are a fifth of the words (xcode-ko md-dark, 3 of 15).
        let chips = [box("xcodebuild", 150), box("BUILD", 75), box("SUCCEEDED", 135)] + (0..<12).map { box("그리고", 40 + Double($0)) }
        #expect(chips.count == 15 && CodeRegion.fixedPitch(chips) == nil)
    }

    @Test func aRunIsFixedPitchWhenEveryBlockThatCanBeMeasuredIs() {
        // yaml-ja: the Japanese comment says nothing (mostly not ASCII); the three rows of yaml are set in the fixed face.
        let rows = ["name: Mwoyeo options: dev", "bundleIdPrefix: dev.midagedev tools", "#アプリと サービスの バージョンは 一つだけ。", "settings: base: path: Core"]
        #expect(verdicts([prose(100)] + spoken(rows, fixed: true, bg: darkBox)) == [nil, .code, .code, .code, .code])
        // One block alone, measured, says nothing: a garbled equation of three words (2401.10066 page 6) in an indented run with a sentence.
        let pair = [spoken(["Test Suite started"], fixed: true, bg: nil)[0], stack(["eigenfunctions of the form"], x: 90, y: 240)[0]]
        #expect(verdicts([prose(100)] + pair).allSatisfy { $0 == nil })
        // One lucky heading among prose blocks measured and not fixed: nothing is kept (tests-en md-dark, keys-en cheat sheet).
        var mixed = spoken(["The suite passes but", "ben commented hours ago", "All tests pass on branch"], fixed: false, bg: darkBox)
        mixed[0].lines[0].words = words("The suite passes but", fixed: true)
        #expect(verdicts([prose(100)] + mixed).allSatisfy { $0 == nil })
    }

    @Test func declarationsWithModifiersAreCodeAndTheWordsAloneAreProse() {
        #expect(verdicts([block(["public init() {}"], y: 100)]) == [.code])
        #expect(verdicts([block(["public struct ReadWait: Equatable, Sendable {"], y: 100)]) == [.code])
        #expect(verdicts([block(["public enum RecognitionWait: String, Sendable, Equatable {"], y: 100)]) == [.code])
        // "public" and "private" are English too: they count beside a keyword of code only.
        let callout = stack(["Anyone can join a public or private channel,", "and a final static extension protocol is not a thing."], x: 90, y: 200, bg: lightBox)
        #expect(verdicts([prose(100)] + callout) == [nil, nil, nil])
    }

    @Test func aNameWithAValueIsAConfigLineAndALabelIsNot() {
        func assignment(_ line: String) -> Bool { CodeRegion.features(of: [line], fixedPitch: false, tinted: false).assignment }
        for line in ["\"note\": \"Runs on this Mac, so no API key is needed\"", "\"savesTranscripts\": true,", "\"transcriptFormats\": [\"markdown\", \"srt\", \"jsonl\"]",
                     "name: Mwoyeo", "bundleIdPrefix: dev.midagedev", "options:", "MARKETING_VERSION: \"1.1.0\"", "total = 2;"] {
            #expect(assignment(line), "\(line)")
        }
        for line in ["Tip: if you want to see the balance of one account,", "Note: restart the app", "Example:", "Price: $5", "https://example.com/a",
                     "Expected: the pill clears at once.", "10:42 AM", "Set the currency = EUR in the file and restart."] {
            #expect(!assignment(line), "\(line)")
        }
    }

    @Test func aCommentLineIsKeptWithTheCodeItSitsAgainst() {
        // shell-ko term-dark (a full-bleed terminal: no tint, no indent): the comment is the only line with a Korean word in it.
        let script = stack(["ANE_POOL=4", "# 디스크 여유가 8 GiB보다 적으면 컴파일을 시작하지 않아요.", "ANE_FLOOR_KB=8388608"], x: 60, y: 200)
        #expect(verdicts([prose(100)] + script) == [nil, .config, .config, .config])
        let swift = stack(["// failures번 실패한 뒤에 기다릴 시간", "public func wait(after failures: Int) -> TimeInterval {"], x: 60, y: 200)
        #expect(verdicts(swift) == [.code, .code])
        // A mark in prose is a mark and nothing more: a heading, a bullet and a hashtag leave their neighbours alone.
        for mark in ["# Install", "* Install the latest release.", "#general is where the release is announced.", "-- see the notes"] {
            #expect(verdicts([prose(100), block([mark], y: 140), block(["Check the version afterwards."], y: 180)]).allSatisfy { $0 == nil }, "\(mark)")
        }
        // A settings box that sits a little inside the paragraph's margin is not the paragraph's edge (k01: the sentence above it stays prose).
        let settings = stack(["# ~/.ledgerrc", "currency = \"EUR\"", "round_to = 2"], x: 90, y: 200, bg: lightBox)
        #expect(verdicts([block(["Run it with --month 2026-09 to see one month only."], x: 70, y: 160)] + settings) == [nil, .config, .config, .config])
        // Another left edge is another column.
        #expect(verdicts([block(["ANE_POOL=4"], x: 60, y: 200), block(["# 디스크 여유가 8 GiB보다 적으면 컴파일을 시작하지 않아요."], x: 400, y: 240)]).allSatisfy { $0 == nil })
    }

    @Test func threeLinesOfOneShapeAreAListingOfSettings() {
        // json-ko ide-light: `"key": value` lines in an indented run (eleven there); each one is weak evidence alone, three or more are not.
        let run = ["\"targetLanguage\": \"ko\",", "\"savesTranscripts\": true,", "\"name\": \"ollama-gemma3-4b\",", "\"note\": \"Runs on this Mac, so no API key is needed\""]
        #expect(verdicts([prose(100)] + stack(run, x: 90, y: 200)) == [nil, .config, .config, .config, .config])
        #expect(verdicts([prose(100)] + stack(Array(run.prefix(2)), x: 90, y: 200)) == [nil, nil, nil])
        // The same shape in prose: labels with a capital are not names (a card of "Name: John", "Email: ...").
        let card = ["Name: John", "Email: john@example.com", "Plan: Pro", "Status: Active"]
        #expect(verdicts([prose(100)] + stack(card, x: 90, y: 200, bg: lightBox)).allSatisfy { $0 == nil })
    }

    // MARK: terminal

    @Test func aPromptLineIsATerminal() {
        #expect(verdicts([block(["dev@mbp:~/shop$ git status"], y: 100)]) == [.terminal])
        #expect(verdicts([block(["devembp：~/shop$ go test ./..."], y: 100)]) == [.terminal])          // OCR's full-width colon
        #expect(verdicts([block(["$ brew install ledgerline"], x: 90, y: 100, bg: lightBox)]) == [.terminal])
        #expect(verdicts([block(["PS C:\\Users\\dev> dir"], y: 100)]) == [.terminal])
        #expect(verdicts([block(["dev@mbp ~ % ls"], y: 100)]) == [.terminal])
    }

    @Test func aDollarOrPercentInProseIsNotAPrompt() {
        for text in ["$5 off every order today", "50% off until Friday", "% of the total", "Pay $ 5 now", "C# is a language", "What is your name?"] {
            #expect(verdicts([block([text], y: 100)]) == [nil], "\(text)")
        }
    }

    // MARK: log

    @Test func aGitLogInADarkViewIsALog() {
        let view = stack(["a3f9c21 Fix rounding of negative balances", "7be04d2 Add the month flag", "c01d55e Update the changelog"], x: 90, y: 200, bg: darkBox)
        #expect(verdicts(view) == [.log, .log, .log])
    }

    @Test func aGitLogLineAloneOrInProseIsNotEnough() {
        #expect(verdicts([block(["a3f9c21 Fix rounding of negative balances"], y: 100)]) == [nil])
        #expect(verdicts([block(["The rounding fix landed in commit a3f9c21 last week."], y: 100)]) == [nil])
        // A tinted callout with a hash in a sentence is prose.
        #expect(verdicts([block(["The fix landed in commit a3f9c21."], x: 90, y: 100, bg: lightBox)]) == [nil])
    }

    @Test func aTracebackIsALog() {
        let box = stack(["Traceback (most recent call last):", "File \"app/main.py\", line 42, in run", "KeyError: 'user'"], x: 90, y: 200, bg: darkBox)
        #expect(verdicts(box) == [.log, .log, .log])
    }

    // MARK: config

    @Test func aSettingsBoxWithAComment() {
        let box = stack(["# ~/.ledgerrc", "currency = \"EUR\"", "round_to = 2"], x: 90, y: 200, bg: lightBox)
        #expect(verdicts(box) == [.config, .config, .config])
    }

    @Test func aSentenceWithAnEqualsSignInATintedBoxIsProse() {
        #expect(verdicts([block(["Set the currency = EUR in the file and restart."], x: 90, y: 100, bg: lightBox)]) == [nil])
    }

    // MARK: diff

    @Test func aTintedDiffIsKept() {
        let view = stack(["+ total += item.price;", "- total = item.price;", "@@ -4,6 +4,7 @@"], x: 90, y: 200, bg: RGBA(230, 255, 237))
        #expect(verdicts(view) == [.diff, .diff, .diff])
    }

    @Test func linesThatStartWithPlusOrMinusInAnEquationAreNotADiff() {
        // A displayed equation set over several lines (untinted, indented under the paragraph): the marks are operators.
        let eq = stack(["b_out = b_in (cosh r - sinh r)", "+ a sinh r cosh r (1 - V)", "- sinh r (16)"], x: 200, y: 200)
        #expect(verdicts([prose(100)] + eq) == [nil, nil, nil, nil])
    }

    // MARK: prose that looks like a container

    @Test func anIndentedBulletListIsTranslated() {
        let bullets = stack(["• In encoder-decoder attention layers, the queries come from the previous decoder layer,",
                             "• The encoder contains self-attention layers. In a self-attention layer all of the keys,",
                             "• Similarly, self-attention layers in the decoder allow each position to attend to all positions"], x: 150, y: 200)
        #expect(verdicts([prose(100)] + bullets) == [nil, nil, nil, nil])
    }

    @Test func aTwoColumnTableIsTranslated() {
        var blocks = [prose(60)]
        let rows = [("Layer Type", "Complexity per Layer"), ("Self-Attention", "O(n^2 · d)"), ("Recurrent", "O(n · d^2)"), ("Convolutional", "O(k · n · d^2)"),
                    ("Self-Attention (restricted)", "O(r · n · d)")]
        for (i, (a, b)) in rows.enumerated() {
            blocks.append(block([a], x: 160, y: 200 + Double(i) * 40))
            blocks.append(block([b], x: 700, y: 200 + Double(i) * 40))
        }
        #expect(verdicts(blocks).allSatisfy { $0 == nil })
    }

    @Test func aStrayKeywordInALongIndentedRunKeepsNothing() {
        // Twelve indented prose blocks and one "end": evidence in one block of thirteen does not turn the run into code.
        var lines = Array(repeating: "an indented line of an ordinary sentence about the method", count: 12)
        lines.insert("end;", at: 5)
        #expect(verdicts([prose(60)] + stack(lines, x: 160, y: 200)).allSatisfy { $0 == nil })
    }

    @Test func emptyAndSingleBlocks() {
        #expect(verdicts([]).isEmpty)
        #expect(verdicts([prose(100)]) == [nil])
    }

    @Test func aTintDistinctFromTheFrameNeedsSixLevels() {
        let faint = RGBA(251, 251, 251)                                                  // 4 levels: the frame, not a box
        #expect(verdicts(stack(["var x = 1;", "var y = 2;"], x: 90, y: 200, bg: faint)) == [nil, nil])          // two lines alone: one feature each
        #expect(verdicts(stack(["var x = 1;", "var y = 2;"], x: 90, y: 200, bg: lightBox)) == [.code, .code])   // 9 levels: one box
    }

    // MARK: what the app hands over

    @Test func aBlocksBackgroundIsThePerChannelMedianOfItsLines() {
        // Three lines in a light box and one whose ring caught the page: the block is the box, channel by channel.
        let box = RGBA(246, 248, 250), page = RGBA(255, 255, 255)
        #expect(CodeRegion.background(ofLines: [box, page, box, box]) == RGBA(246, 248, 250))
        #expect(CodeRegion.background(ofLines: [RGBA(10, 200, 30), RGBA(20, 100, 60), RGBA(30, 150, 90)]) == RGBA(20, 150, 60))
        #expect(CodeRegion.background(ofLines: [box]) == box)
        #expect(CodeRegion.background(ofLines: [RGBA(0, 0, 0), RGBA(10, 10, 10)]) == RGBA(10, 10, 10))      // an even count takes the upper middle
        #expect(CodeRegion.background(ofLines: []) == RGBA(0, 0, 0))
    }

    @Test func theVerdictDoesNotDependOnTheOrderOfTheBlocks() {
        let box = stack(["const nested = [1, 12, [3, [4]]];", "// flatten every level at once", "console.log(flat); // [1, 2, 3, 4]"], x: 90, y: 200, bg: lightBox)
        let all = [prose(100)] + box + [prose(400)]
        let expected = verdicts(all)
        #expect(expected == [nil, .code, .code, .code, nil])
        for shift in 1..<all.count {
            let order = Array(all.indices.dropFirst(shift)) + Array(all.indices.prefix(shift))
            let got = verdicts(order.map { all[$0] })
            #expect(order.indices.allSatisfy { got[$0] == expected[order[$0]] }, "shift \(shift)")
        }
    }

    /// A price that starts a line ("$ 20 per month") is prose, not a shell prompt: the prompt needs a command after "$ ", and
    /// commands do not start with a digit (c2-code-region probe, 2026-10-19: the sentence was kept as a terminal).
    @Test func aDollarPriceIsNotAPrompt() {
        #expect(!CodeRegion.isPrompt("$ 20 per month for the team plan"))
        #expect(!CodeRegion.isPrompt("$ 4.99 a year"))
        #expect(CodeRegion.isPrompt("$ cd repo"))
        #expect(CodeRegion.isPrompt("$ ./build.sh --release"))
    }
}
