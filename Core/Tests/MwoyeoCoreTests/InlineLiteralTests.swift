import Foundation
import Testing
@testable import MwoyeoCore

/// Literals inside a sentence of prose (a URL, a path, a command, a flag, an identifier, a hash, a version, a config
/// filename, a hotkey, an e-mail address) stay as written, found from the table of `InlineLiteral`. One positive and one
/// negative case per reason; the negatives are prose shapes that look like a literal to a loose pattern.
@Suite struct InlineLiteralTests {
    private func found(_ s: String) -> [(text: String, reason: String)] {
        let chars = Array(s)
        return InlineLiteral.spans(in: s).map { (String(chars[$0.range]), $0.reason.rawValue) }
    }

    private func keeps(_ s: String, _ reason: String) -> Bool {
        found(s).contains { $0.reason == reason }
    }

    private func keepsNothing(_ s: String) -> Bool {
        found(s).isEmpty
    }

    @Test func aURLStaysAsWritten() {
        #expect(keeps("Read the notes at https://github.com/midagedev/mwoyeo/releases/latest.", "url"))
        #expect(!keeps("Visit the site for details.", "url"))
    }

    /// Japanese and Chinese set a colon or a bracket full width and glue the URL to it: the full-width mark ends the CJK text,
    /// not the URL (H3: 1841 url words, recall 0.07 before).
    @Test func aURLAfterAFullWidthColonStaysAsWritten() {
        #expect(found("• リリース：https://github.com/midagedev/mwoyeo/releases").map(\.text) == ["https://github.com/midagedev/mwoyeo/releases"])
        #expect(keeps("详见（https://example.com/a）。", "url"))
    }

    @Test func anEmailAddressStaysAsWritten() {
        #expect(keeps("Write to admin@example.org about it.", "email"))
        #expect(!keeps("Mr. Smith wrote to us.", "email"))
    }

    @Test func aPathStaysAsWritten() {
        #expect(keeps("See Core/Sources/MwoyeoCore/Text.swift now.", "path"))
        #expect(keeps("The settings live in ~/.ledgerrc.", "path"))
        #expect(keeps("The file is ReadWait. swift in the folder.", "path"))
        #expect(!keeps("Use and/or the other one.", "path"))
        #expect(!keeps("A/B testing is next.", "path"))
    }

    @Test func aCommandStaysAsWritten() {
        #expect(keeps("Run git log -p ca12b7c to see the change.", "cmd"))
        #expect(keeps("Then xcodebuild -scheme Mwoyeo build runs.", "cmd"))
        #expect(!keeps("Please make sure the tests pass.", "cmd"))
    }

    @Test func aFlagStaysAsWritten() {
        #expect(keeps("Pass --month 2026-09 to see one month.", "flag"))
        #expect(!keeps("That is a state-of-the-art design.", "flag"))
    }

    @Test func anIdentifierStaysAsWritten() {
        #expect(keeps("Check ANE_FLOOR_KB before the run.", "id"))
        #expect(keeps("ReadWait.State names the state.", "id"))
        #expect(!keeps("The deadline is near.", "id"))
    }

    @Test func aHashStaysAsWritten() {
        #expect(keeps("The commit ca12b7c landed today.", "hash"))
        #expect(!keeps("deadbeef is a made-up word.", "hash"))
    }

    @Test func aVersionStaysAsWritten() {
        #expect(keeps("Upgrade to 1.4.2 before the release.", "version"))
        #expect(!keeps("It took 3.5 hours to finish.", "version"))
    }

    @Test func aConfigFilenameStaysAsWritten() {
        #expect(keeps("Edit settings.json first.", "config"))
        #expect(!keeps("The note is in the file.", "config"))
    }

    @Test func aHotkeyStaysAsWritten() {
        #expect(keeps("Press Ctrl+Shift+P to open the palette.", "hotkey"))
        #expect(!keeps("Press the button to continue.", "hotkey"))
    }

    @Test func proseShapesAreNotLiterals() {
        for s in ["e.g. this one", "U.S. policy", "and/or", "A/B testing", "Mr. Smith", "It is 3.5 hours.",
                  "設定 > 一般の順に開きます。", "설정 > 일반에서 확인하세요.", "The words belong to the app."] {
            #expect(keepsNothing(s), "\(s): \(found(s))")
        }
    }
}
