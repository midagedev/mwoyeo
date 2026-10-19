import Foundation
import Testing
@testable import MwoyeoCore

/// 2026-10-19 language packs: every state of a pair that cannot translate has a line on the lens, one action that works from where the
/// person is, and a way back after a download that ended without the pack.
@Suite struct PackLedgerTests {
    private let ja = PackPair(source: "ja", target: "en")
    private let ko = PackPair(source: "ko", target: "en")

    // MARK: the ledger

    @Test func aRequestedPackIsDownloadingUntilItsSheetEnds() {
        var ledger = PackLedger()
        #expect(ledger.phase(of: ja) == nil)
        ledger.requested(ja)
        #expect(ledger.phase(of: ja) == .downloading)
        #expect(ledger.isDownloading)
        #expect(ledger.phase(of: ko) == nil)   // one pair's sheet says nothing about another's
    }

    @Test func aSheetThatEndedWithoutThePackIsNotFinishedAndAsksAgain() {
        var ledger = PackLedger()
        ledger.requested(ja)
        ledger.ended(ja, installed: false)
        #expect(ledger.phase(of: ja) == .notFinished)
        #expect(!ledger.isDownloading)
        ledger.requested(ja)   // the retry goes back to downloading, not stuck in the failure
        #expect(ledger.phase(of: ja) == .downloading)
    }

    @Test func aPackThatArrivedIsForgotten() {
        var ledger = PackLedger()
        ledger.requested(ja)
        ledger.ended(ja, installed: true)
        #expect(ledger.phase(of: ja) == nil)
        #expect(ledger == PackLedger())
    }

    @Test func packsChangingDropsOldFailuresButNotADownloadOnItsWay() {
        var ledger = PackLedger()
        ledger.requested(ja)
        ledger.ended(ja, installed: false)
        ledger.requested(ko)
        ledger.packsChanged()
        #expect(ledger.phase(of: ja) == nil)
        #expect(ledger.phase(of: ko) == .downloading)
    }

    @Test func aStatusSaysWhetherThePairTranslatesAndWhetherThereIsAPackToGet() {
        #expect(PackStatus.installed.translates && !PackStatus.installed.canDownload)
        // Apple Intelligence stands in for a pack that is not there: nothing is stopped, and the faster pack can still be fetched.
        #expect(PackStatus.viaIntelligence.translates && PackStatus.viaIntelligence.canDownload)
        #expect(!PackStatus.downloadable.translates && PackStatus.downloadable.canDownload)
        #expect(!PackStatus.unsupported.translates && !PackStatus.unsupported.canDownload)
    }

    // MARK: the lens's line

    @Test func theLineFollowsTheLedger() {
        var s = LensSignals(missingPack: ja)
        #expect(s.hint() == .downloadPack(ja))
        s.packPhase = .downloading
        #expect(s.hint() == .downloadingPack(ja))
        s.packPhase = .notFinished
        #expect(s.hint() == .downloadNotFinished(ja))
    }

    @Test func aPhaseWithoutAMissingPackSaysNothing() {
        // The pack came (or the pair never needed it): a stale ledger entry must not put a line on the pill.
        #expect(LensSignals(packPhase: .notFinished).hint() == nil)
        #expect(LensSignals(packPhase: .downloading).hint() == nil)
    }

    @Test func eachPackStateHasTheActionThatWorksFromTheLens() {
        #expect(LensHint.downloadPack(ja).action == .downloadPack(ja))
        // After a failed sheet the click asks again; while it is up the click goes to the window the sheet is in.
        #expect(LensHint.downloadNotFinished(ja).action == .downloadPack(ja))
        #expect(LensHint.downloadingPack(ja).action == .openTranslationSettings)
        #expect(LensHint.pairNotSupported(ja).action == .chooseLanguages)
        for hint in [LensHint.downloadPack(ja), .downloadingPack(ja), .downloadNotFinished(ja), .pairNotSupported(ja)] {
            #expect(hint.showsTabAlways, "\(hint)")
            #expect(hint.isAboutLanguages, "\(hint)")
        }
        #expect(!LensHint.alreadyInTarget(target: "en").isAboutLanguages)
        #expect(!LensHint.preparingRecognition.isAboutLanguages)
    }

    @Test func aPairWithNoTranslationSpeaksWhenNothingIsShown() {
        var s = LensSignals(unsupportedPair: ja)
        #expect(s.hint() == .pairNotSupported(ja))
        s.showsTranslations = true   // Some text was translated: the lens works, the odd block is not its setup
        #expect(s.hint() == nil)
    }

    @Test func screenRecordingAndAMissingPackStillComeFirst() {
        var s = LensSignals(screen: .notAllowed, missingPack: ja, unsupportedPair: ko)
        #expect(s.hint() == .allowScreenRecording)
        s.screen = .fine
        #expect(s.hint() == .downloadPack(ja))
        s.missingPack = nil
        #expect(s.hint() == .pairNotSupported(ko))
        // ... and it beats the recognizer's wait: with no translation possible the wait changes nothing.
        s.recognitionPreparing = true
        #expect(s.hint() == .pairNotSupported(ko))
    }
}
