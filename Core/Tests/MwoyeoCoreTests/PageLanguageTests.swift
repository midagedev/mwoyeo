import Testing
@testable import MwoyeoCore

struct PageLanguageTests {
    @Test func theLinesReadLatelyMakeThePagesLanguage() {
        var page = PageLanguage()
        #expect(page.language == nil)
        for _ in 0..<5 { page.learn("ja") }
        #expect(page.language == "ja")
        // A lens moved onto an English article: a few of its lines turn the page (a running count needed six).
        for _ in 0..<3 { page.learn("en") }
        #expect(page.language == "en")
    }

    @Test func aBatchOfConfidentLinesIsReadInTheirLanguage_onAPageOfAnother() {
        var page = PageLanguage()
        for _ in 0..<20 { page.learn("ja") }
        // The film5 defect: English lines on a "Japanese" page were names to leave alone.
        #expect(page.source(ofBatch: ["en", "en", "en"]) == "en")
        #expect(!PageLanguage.isCJK(page.source(ofBatch: ["en", "en"])))
        // Mostly Japanese with an English line: Japanese, and the English name in it stays a name.
        #expect(page.source(ofBatch: ["ja", "ja", "en"]) == "ja")
        // Nothing confident in the batch (short labels): the page's.
        #expect(page.source(ofBatch: []) == "ja")
        #expect(PageLanguage.isCJK(page.source(ofBatch: [])))
    }
}
