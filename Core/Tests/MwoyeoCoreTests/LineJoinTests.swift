import Foundation
import Testing
@testable import MwoyeoCore

/// A word broken at the end of a line is one word for the engine (round read117, item 1; film3's take of page 6 of the method paper
/// translated "noth-ing"). The pairs are the line ends of our own paper (`pdftotext` of tools/paper-own/mwoyeo-method/main.pdf, the bench
/// pages) and of arXiv 1706.03762 (the compounds: "sequence-" "aligned", "position-" "wise", "English-" "to-German"), which a rule that
/// joins every lowercase continuation breaks. The dictionary is the app's spell checker in the build; here it is a list.
@Suite struct LineJoinTests {
    private static let words: Set<String> = [
        "nothing", "transduction", "multiplicative", "transformation", "convolutional", "surprisingly", "image", "section", "overlap",
        "background", "total", "between", "context", "estimate", "minimum", "threshold", "rectangle", "latency", "assignment", "directly",
        "memory", "confirmed", "applications", "pretrained", "resetting", "readnothing", "platform",
        // Joined forms that are words, so that only the rule (not the dictionary) keeps the hyphen of a name, a code span or a capital.
        "barbaz", "somename", "nocache", "rex", "berkeleyparser", "kappatau", "xray", "emailx", "korayx",
    ]
    private static func isWord(_ s: String) -> Bool { words.contains(s.lowercased()) }
    private static func isCJK(_ c: Character) -> Bool { c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) } }

    private func kept(_ lines: [String]) -> String { LineJoin.text(lines, isCJK: Self.isCJK) }
    private func joined(_ lines: [String]) -> String { LineJoin.text(lines, hyphens: .word(isWord: Self.isWord), isCJK: Self.isCJK) }

    /// What `TextRecognizer.makeBlock` did before the rule: a space between the lines, none after a hyphen or at a CJK edge.
    private func legacy(_ lines: [String]) -> String {
        var text = ""
        for line in lines {
            if let last = text.last, let first = line.first, !(Self.isCJK(last) || Self.isCJK(first)) { text += last == "-" ? "" : " " }
            text += line
        }
        return text
    }

    // MARK: A word the typesetter broke

    @Test func aBrokenWordIsOneWord() {
        #expect(joined(["there is noth-", "ing left to read"]) == "there is nothing left to read")
        #expect(joined(["The ellipsis is counted by the paper bench (Sec-", "tion 6), because it is a loss"])
                == "The ellipsis is counted by the paper bench (Section 6), because it is a loss")
        #expect(joined(["a sequence transduc-", "tion, and"]) == "a sequence transduction, and")
        #expect(joined(["the (multi-", "plicative) form"]) == "the (multiplicative) form")
    }

    @Test func aCapitalisedStemIsOneWordToo() {
        #expect(joined(["Convolu-", "tional layers"]) == "Convolutional layers")
    }

    @Test func severalBreaksInOneBlock() {
        #expect(joined(["a noth-", "ing about the con-", "text of a la-", "tency"]) == "a nothing about the context of a latency")
    }

    @Test func aPossessiveEndsTheWordToo() {
        // Page 6 of the paper bench: "so that the plat-" "form's line breaker" went to the engine as "plat-form's".
        #expect(joined(["so that the plat-", "form's line breaker"]) == "so that the platform's line breaker")
        #expect(joined(["so that the plat-", "form’s line breaker"]) == "so that the platform’s line breaker")
        #expect(joined(["a noth-", "ing's end"]) == "a nothing's end")
        #expect(joined(["a noth-", "ing'x end"]) == "a noth-ing'x end", "only the possessive")
    }

    @Test func theEndOfTheLineMayCarryAMarkOfTheClause() {
        for (next, tail) in [("ing", ""), ("ing,", ","), ("ing.", "."), ("ing)", ")"), ("ing;", ";"), ("ing:", ":"), ("ing\"", "\"")] {
            #expect(joined(["noth-", next]) == "nothing" + tail, "next: \(next)")
        }
    }

    // MARK: A hyphen that belongs to the word stays

    @Test func aCompoundKeepsItsHyphen() {
        // The joined form is no word: "sequencealigned", "positionwise", "attentionbased", "sourcetarget", "cooccurrence".
        for (head, tail) in [("sequence-", "aligned"), ("position-", "wise"), ("attention-", "based"), ("source-", "target"), ("co-", "occurrence"),
                             ("self-", "attention"), ("held-", "out"), ("per-", "channel")] {
            #expect(joined(["a " + head, tail + " model"]) == "a " + head + tail + " model", "\(head)\(tail)")
        }
    }

    @Test func aCompoundThatGoesOnInAHyphenKeepsIt() {
        #expect(joined(["from English-", "to-German"]) == "from English-to-German")
        #expect(joined(["the state-of-the-", "art"]) == "the state-of-the-art")
        #expect(joined(["on a Wi-", "Fi link"]) == "on a Wi-Fi link")
    }

    @Test func aContinuationThatIsNotLowercaseKeepsTheHyphen() {
        #expect(joined(["the Berkeley-", "Parser"]) == "the Berkeley-Parser")
        #expect(joined(["COVID-", "19 cases"]) == "COVID-19 cases")
        #expect(joined(["a Kappa-", "Tau split"]) == "a Kappa-Tau split")
    }

    @Test func aOneLetterStemOrContinuationKeepsTheHyphen() {
        #expect(joined(["an x-", "ray image"]) == "an x-ray image")
        #expect(joined(["an e-", "mail"]) == "an e-mail")
        #expect(joined(["a re-", "x test"]) == "a re-x test")
    }

    @Test func aNameThatIsNotAWordKeepsTheHyphen() {
        #expect(joined(["by Ko-", "ray and"]) == "by Ko-ray and")
    }

    // MARK: Code and names are not stems

    @Test func codeIsLeftAsRead() {
        #expect(joined(["run --no-", "cache again"]) == "run --no-cache again")
        #expect(joined(["see foo_bar-", "baz here"]) == "see foo_bar-baz here")
        #expect(joined(["open src/some-", "name today"]) == "open src/some-name today")
        #expect(joined(["call a.b-", "noth now"]) == "call a.b-noth now")
        #expect(joined(["v2-", "image"]) == "v2-image")
        #expect(joined(["readNoth-", "ing now"]) == "readNoth-ing now")   // camelCase, though the list has "readnothing"
        #expect(joined(["a nothing -", "ing"]) == "a nothing -ing")
    }

    @Test func aContinuationThatIsCodeKeepsTheHyphen() {
        #expect(joined(["a noth-", "ing.swift is"]) == "a noth-ing.swift is")
        #expect(joined(["a noth-", "ing_x is"]) == "a noth-ing_x is")
        #expect(joined(["a noth-", "ing/x is"]) == "a noth-ing/x is")
        #expect(joined(["a noth-", "ing2 is"]) == "a noth-ing2 is")
        #expect(joined(["a noth-", "ing@x is"]) == "a noth-ing@x is")
    }

    // MARK: Everything else is today's join

    @Test func theOtherJoinsAreTheOnesBefore() {
        let samples: [[String]] = [
            ["one", "two", "three"],
            ["日本語の", "テキスト"],
            ["日本語-", "テキスト"],
            ["ends in a dash -", "next"],
            ["Latin text", "日本語"],
            ["a", "b-", "c"],
            ["single"],
            [],
            ["end-", "of-line", "mixed-", "Case", "and noth-", "ing"],
        ]
        for lines in samples {
            #expect(kept(lines) == legacy(lines), "\(lines)")
        }
    }

    @Test func hyphensKeptIsToday() {
        #expect(kept(["there is noth-", "ing left"]) == "there is noth-ing left")
        #expect(kept(["a sequence-", "aligned model"]) == "a sequence-aligned model")
    }

    @Test func aJoinOnlyChangesTheHyphens() {
        // Every join differs from today's text by the hyphens it dropped, nothing else.
        for lines in [["there is noth-", "ing left"], ["a noth-", "ing about the con-", "text"], ["a sequence-", "aligned model"]] {
            let joined = LineJoin.join(lines, hyphens: .word(isWord: Self.isWord), isCJK: Self.isCJK)
            #expect(joined.text.count == kept(lines).count - joined.words.count, "\(lines)")
        }
        #expect(LineJoin.join(["a noth-", "ing about the con-", "text"], hyphens: .word(isWord: Self.isWord), isCJK: Self.isCJK).words == ["nothing", "context"])
        #expect(LineJoin.join(["a sequence-", "aligned model"], hyphens: .word(isWord: Self.isWord), isCJK: Self.isCJK).words == [])
    }

    @Test func theDictionaryIsAskedWithTheJoinedFormOnly() {
        var asked: [String] = []
        _ = LineJoin.text(["noth-", "ing", "the con-", "text", "x-", "ray", "Ko-", "ray"], hyphens: .word(isWord: { asked.append($0); return false }), isCJK: Self.isCJK)
        #expect(asked == ["nothing", "context", "Koray"], "asked \(asked)")
    }
}
