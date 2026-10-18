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
}
