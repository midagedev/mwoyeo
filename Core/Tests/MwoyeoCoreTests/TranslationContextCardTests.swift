import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct TranslationContextCardTests {
    // MARK: title normalisation: real-looking titles (app, raw title, what goes in the card)

    static let table: [(app: String, raw: String, want: String)] = [
        // Safari: the page title as is; Safari adds no suffix.
        ("Safari", "Swift Concurrency | Apple Developer Documentation", "Swift Concurrency | Apple Developer Documentation"),
        ("Safari", "Start Page", "Start Page"),
        // Chrome: the app name at the end, an unread counter in front, an e-mail address in the middle.
        ("Google Chrome", "SwiftUI Tutorials - Apple Developer - Google Chrome", "SwiftUI Tutorials - Apple Developer"),
        ("Google Chrome", "(3) YouTube - Google Chrome", "YouTube"),
        ("Google Chrome", "Inbox (12) - alice@example.com - Gmail - Google Chrome", "Inbox - Gmail"),
        ("Chrome", "Release notes — Chrome", "Release notes"),
        ("Google Chrome", "https://example.com/watch?v=abc123&t=30s - Google Chrome", "https://example.com/watch"),
        ("Google Chrome", "https://user:secret@example.com/a/b?token=xyz#frag", "https://example.com/a/b"),
        // Slack: counters, a leading bullet, the app name at the start or the end.
        ("Slack", "* general - Acme - 2 new items - Slack", "general - Acme"),
        ("Slack", "Slack | Project Alpha | Acme", "Project Alpha | Acme"),
        ("Slack", "Slack", ""),
        // Messages: the contact; the app name alone is dropped.
        ("Messages", "Alice", "Alice"),
        ("Messages", "Messages", ""),
        ("Messages", "Messages — Alice", "Alice"),
        ("Messages", "Alice (2 unread)", "Alice"),
        ("Messages", "Alice — 3 unread", "Alice"),
        // KakaoTalk: Korean chat names with counters; the Korean app name alone is dropped.
        ("카카오톡", "카카오톡", ""),
        ("KakaoTalk", "김지수 (3)", "김지수"),
        ("KakaoTalk", "[2] 스터디방", "스터디방"),
        ("KakaoTalk", "개발자 모임 (12)", "개발자 모임"),
        // Preview: file names without extension, edit marks and page counters.
        ("Preview", "report.pdf", "report"),
        ("Preview", "Invoice-2026.pdf — Edited", "Invoice-2026"),
        ("Preview", "Annual Report.pdf (page 3 of 10)", "Annual Report"),
        ("Preview", "~/Documents/Taxes/2025 return.pdf", "2025 return"),
        // Xcode: project and file; a modified mark.
        ("Xcode", "Mwoyeo — TranslationService.swift", "Mwoyeo — TranslationService"),
        ("Xcode", "Mwoyeo — TranslationService.swift — Edited", "Mwoyeo — TranslationService"),
        ("TextEdit", "notes.txt *", "notes"),
        ("Visual Studio Code", "● main.py - mwoyeo - Visual Studio Code", "main - mwoyeo"),
        // Games: names kept, FPS counters and loading marks removed.
        ("Steam", "Stardew Valley - 60 FPS", "Stardew Valley"),
        ("Stardew Valley", "Stardew Valley - 60 FPS", ""),
        ("Minecraft", "Minecraft 1.21.4 - Singleplayer", "Minecraft 1.21.4 - Singleplayer"),
        ("ELDEN RING", "ELDEN RING™", "ELDEN RING™"),
        ("Hades II", "Loading…", "Loading"),
        // Whitespace, newlines, zero-width characters.
        ("Notes", "  Meeting \n  notes\u{200B}  ", "Meeting notes"),
        // A name that only looks like a file: example.com is not a known extension.
        ("Safari", "example.com", "example.com"),
    ]

    @Test func normalisesRealLookingTitles() {
        #expect(Self.table.count >= 15)
        for row in Self.table {
            let got = TitleNormalizer.normalize(row.raw, appName: row.app)
            #expect(got == row.want, "[\(row.app)] \(row.raw.debugDescription) → \(got.debugDescription), want \(row.want.debugDescription)")
        }
    }

    @Test func cutsAtTheEndWithAnEllipsis() {
        let latin = String(repeating: "abcdefghij", count: 7)             // 70 Latin characters
        let cutLatin = TitleNormalizer.normalize(latin, appName: "Safari")
        #expect(cutLatin == String(latin.prefix(60)) + "…")
        let cjk = String(repeating: "あいうえお", count: 10)               // 50 CJK characters
        let cutCJK = TitleNormalizer.normalize(cjk, appName: "Safari")
        #expect(cutCJK == String(cjk.prefix(40)) + "…")
        // At the limit: not cut.
        let exact = String(repeating: "x", count: 60)
        #expect(TitleNormalizer.normalize(exact, appName: "Safari") == exact)
        let exactCJK = String(repeating: "あ", count: 40)
        #expect(TitleNormalizer.normalize(exactCJK, appName: "Safari") == exactCJK)
        // Mixed: the budget is shared (a CJK character costs 1.5 of the 60).
        let mixed = String(repeating: "あ", count: 20) + String(repeating: "x", count: 30)
        #expect(TitleNormalizer.normalize(mixed, appName: "Safari") == mixed)
        #expect(TitleNormalizer.normalize(mixed + "y", appName: "Safari").hasSuffix("…"))
    }

    @Test func anAddressNeverSurvivesTheCut() {
        // The address starts before position 60: the e-mail goes first, so no half address is left behind.
        let raw = String(repeating: "word ", count: 11) + "alice.smith@example.com and more text after it"
        let got = TitleNormalizer.normalize(raw, appName: "Mail")
        #expect(!got.contains("@") && !got.contains("alice"))
    }

    @Test func aStableTitleStaysStableWhileCountersChange() {
        let reads = ["(1) Inbox - Mail", "(2) Inbox - Mail", "(17) Inbox - Mail", "Inbox - Mail"]
        #expect(Set(reads.map { TitleNormalizer.normalize($0, appName: "Mail") }) == ["Inbox"])
    }

    // MARK: hysteresis

    @Test func aTitleChangeCountsAfterThreeAgreeingReadsSpanningASecond() {
        var c = TitleConfirmer()
        let o1 = c.observe("A", at: 0)
        #expect(o1 == "A")            // the first title is adopted at once
        let o2 = c.observe("B", at: 1.0)
        #expect(o2 == "A")          // 1st read of B
        let o3 = c.observe("B", at: 1.5)
        #expect(o3 == "A")          // 2nd
        let o4 = c.observe("B", at: 1.9)
        #expect(o4 == "A")          // 3rd, but 0.9 s after the first: not yet
        let o5 = c.observe("B", at: 2.1)
        #expect(o5 == "B")          // spans 1.1 s with ≥ 3 reads: confirmed
    }

    @Test func aFlickerNeverConfirms() {
        var c = TitleConfirmer()
        c.observe("A", at: 0)
        for (i, t) in ["B", "B", "A", "B", "B", "A", "C", "B", "B"].enumerated() { c.observe(t, at: Double(i) * 2) }
        #expect(c.confirmed == "A")                      // A resets the pending change; C restarts it
        c.observe("B", at: 100)                          // the 3rd B in a row after the last reset, spanning 2+ s
        #expect(c.confirmed == "B")
    }

    @Test func aReadWithoutWindowInfoIsIgnored() {
        var c = TitleConfirmer()
        c.observe("A", at: 0)
        c.observe("B", at: 1)
        c.observe(nil, at: 2)
        c.observe("B", at: 2.5)
        c.observe("B", at: 3)
        #expect(c.confirmed == "B")
    }

    // MARK: privacy

    @Test func theTitleGoesOnlyToOnDeviceEnginesOrAfterOptIn() {
        #expect(ContextPrivacy.includesTitle(onDevice: true, optedIn: false))
        #expect(ContextPrivacy.includesTitle(onDevice: false, optedIn: true))
        #expect(ContextPrivacy.includesTitle(onDevice: true, optedIn: true))
        #expect(!ContextPrivacy.includesTitle(onDevice: false, optedIn: false))
    }

    // MARK: category and card

    @Test func categoryMapsToAShortDomainWord() {
        #expect(CategoryDomain.words.count >= 25)
        #expect(CategoryDomain.word(for: "public.app-category.social-networking") == "social")
        #expect(CategoryDomain.word(for: "public.app-category.developer-tools") == "dev")
        #expect(CategoryDomain.word(for: "public.app-category.action-games") == "games")
        #expect(CategoryDomain.word(for: "public.app-category.role-playing-games") == "games")
        #expect(CategoryDomain.word(for: "public.app-category.magazines-newspapers") == "news")
        #expect(CategoryDomain.word(for: "public.app-category.made-up") == nil)
        #expect(CategoryDomain.word(for: nil) == nil)
        #expect(CategoryDomain.words.values.allSatisfy { $0.count <= 15 })
    }

    @Test func theCardRendersWithinItsTokenBudget() {
        let card = DocumentCard.make(appName: "Messages", categoryType: "public.app-category.social-networking", windowTitle: "Alice — 3 unread")
        #expect(card == DocumentCard(appName: "Messages", domain: "social", title: "Alice"))
        #expect(card.rendered(includeTitle: true, maxTokens: 45) == "Document: Messages (social), window \"Alice\".")
        #expect(card.rendered(includeTitle: false, maxTokens: 45) == "Document: Messages (social).")
        let long = DocumentCard(appName: "Safari", domain: "productivity", title: String(repeating: "あ", count: 40) + "…")
        for budget in [45, 20] {
            let text = long.rendered(includeTitle: true, maxTokens: budget)
            #expect(approxTokens(text) <= budget, "\(budget): \(text)")
        }
        #expect(long.rendered(includeTitle: true, maxTokens: 20).hasPrefix("Document: Safari (productivity)"))
        // A quote in a title cannot close the quoted part.
        #expect(DocumentCard(appName: "A", title: "say \"hi\"").rendered(includeTitle: true, maxTokens: 45).contains("window \"say 'hi'\""))
    }
}
