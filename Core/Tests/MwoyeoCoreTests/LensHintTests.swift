import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// 2026-10-18 first run: a new user is never left with a silent lens (the priority of the one line on the pill, "already in",
/// the pause while covered, Vision's region of interest).
@Suite struct LensHintTests {
    private let ja = PackPair(source: "ja", target: "en")

    // MARK: priority

    @Test func allWellSaysNothing() {
        #expect(LensSignals().hint() == nil)
    }

    @Test func screenRecordingBeatsEverything() {
        var s = LensSignals(screen: .notAllowed, missingPack: ja, recognitionPreparing: true, alreadyInTarget: "en")
        #expect(s.hint() == .allowScreenRecording)
        s.screen = .notActive
        #expect(s.hint() == .restartToFinish)
    }

    @Test func packBeatsSetupAndAlreadyIn() {
        let s = LensSignals(missingPack: ja, recognitionPreparing: true, alreadyInTarget: "en")
        #expect(s.hint() == .downloadPack(ja))
    }

    @Test func setupBeatsAlreadyIn() {
        let s = LensSignals(recognitionPreparing: true, alreadyInTarget: "en")
        #expect(s.hint() == .preparingRecognition)
    }

    // MARK: the lens's own wait for a reader (R2 reader-core, 2026-10-18)

    @Test func recognitionNotRespondingSitsBetweenThePackAndAlreadyIn() {
        // priority: screen > pack > recognition > already-in
        var s = LensSignals(recognition: .notResponding, alreadyInTarget: "en")
        #expect(s.hint() == .recognitionNotResponding)
        s.missingPack = ja
        #expect(s.hint() == .downloadPack(ja))
        s.missingPack = nil
        s.screen = .notAllowed
        #expect(s.hint() == .allowScreenRecording)
        #expect(LensSignals(recognition: .notResponding, alreadyInTarget: "en").hint() != .alreadyInTarget(target: "en"))
    }

    @Test func theLensOwnWaitSaysMoreThanTheAppsSetup() {
        #expect(LensSignals(recognition: .preparing).hint() == .preparingRecognition)
        #expect(LensSignals(recognitionPreparing: true, recognition: .notResponding).hint() == .recognitionNotResponding)
        #expect(LensSignals(recognitionPreparing: true, recognition: .restartApp).hint() == .restartToFinish)
        #expect(LensSignals(recognitionPreparing: true).hint() == .preparingRecognition)     // the app-wide flag still works alone
        #expect(LensSignals(recognition: .restartApp).hint()?.action == .restart)
    }

    @Test func aWaitSaysNothingOnceTheLensShowsTranslations() {
        for wait in [RecognitionWait.preparing, .notResponding, .restartApp] {
            #expect(LensSignals(recognition: wait, showsTranslations: true).hint() == nil, "\(wait)")
        }
    }

    @Test func alreadyInComesLast() {
        #expect(LensSignals(alreadyInTarget: "ko").hint() == .alreadyInTarget(target: "ko"))
    }

    @Test func setupSaysNothingOnceTheLensShowsTranslations() {
        let s = LensSignals(recognitionPreparing: true, showsTranslations: true)
        #expect(s.hint() == nil)
        // A fault still shows: a lens that translated before the pack went away has nothing more to say about the setup only.
        #expect(LensSignals(missingPack: ja, showsTranslations: true).hint() == .downloadPack(ja))
    }

    @Test func alreadyInIsDroppedWhenSomethingOnTheLensIsTranslated() {
        #expect(LensSignals(showsTranslations: true, alreadyInTarget: "en").hint() == nil)
    }

    @Test func screenStateFollowsTheGrantAndTheFailure() {
        #expect(LensSignals.Screen(allowed: false, failure: nil) == .notAllowed)
        #expect(LensSignals.Screen(allowed: false, failure: .permission) == .notAllowed)
        #expect(LensSignals.Screen(allowed: true, failure: .permission) == .notActive)
        #expect(LensSignals.Screen(allowed: true, failure: .other) == .fine)
        #expect(LensSignals.Screen(allowed: true, failure: nil) == .fine)
    }

    @Test func onlyScreenCaptureKitsDeclinedCodeIsAPermissionFailure() {
        let d = CaptureFailure.screenCaptureKitDomain
        #expect(CaptureFailure.classify(domain: d, code: -3801) == .permission)
        #expect(CaptureFailure.classify(domain: d, code: -3817) == .other)   // the user stopped sharing
        #expect(CaptureFailure.classify(domain: "NSCocoaErrorDomain", code: -3801) == .other)
    }

    @Test func actionsAreWhatTheUserCanDo() {
        #expect(LensHint.allowScreenRecording.action == .openScreenRecordingSettings)
        #expect(LensHint.restartToFinish.action == .restart)
        #expect(LensHint.downloadPack(ja).action == .downloadPack(ja))
        #expect(LensHint.preparingRecognition.action == nil)
        #expect(LensHint.recognitionNotResponding.action == nil)
        #expect(LensHint.alreadyInTarget(target: "en").action == nil)
    }

    @Test func onlyNewsLeavesTheTabToTheUsersLook() {
        #expect(LensHint.allowScreenRecording.showsTabAlways)
        #expect(LensHint.downloadPack(ja).showsTabAlways)
        #expect(LensHint.preparingRecognition.showsTabAlways)
        #expect(LensHint.recognitionNotResponding.showsTabAlways)
        #expect(!LensHint.alreadyInTarget(target: "en").showsTabAlways)
    }

    // MARK: already in the target language

    private let allIn = ReadTally(inTarget: 3, needing: 0)

    @Test func alreadyInNeedsTwoReadsThatAgree() {
        var s = TargetLanguageStreak()
        let first = s.read(allIn), second = s.read(allIn), third = s.read(allIn)
        #expect(!first)
        #expect(second)
        #expect(third)
    }

    @Test func oneBlockToTranslateDropsItAtOnce() {
        var s = TargetLanguageStreak()
        s.read(allIn); s.read(allIn)
        #expect(s.shown)
        let dropped = s.read(ReadTally(inTarget: 2, needing: 1))
        let startsOver = s.read(allIn)   // one read is not two
        let again = s.read(allIn)
        #expect(!dropped)
        #expect(!startsOver)
        #expect(again)
    }

    @Test func noTextIsNotAgreementAndEndsIt() {
        var s = TargetLanguageStreak()
        let none = ReadTally(inTarget: 0, needing: 0)
        let a = s.read(none), b = s.read(none)
        #expect(!a && !b)
        s.read(allIn); s.read(allIn)
        #expect(s.shown)
        let ended = s.read(none)
        #expect(!ended)
    }

    @Test func aBlankStripOfAScrollDoesNotEndIt() {
        // Scrolling reads the strip that came into view: a gap between paragraphs finds no text there, which says nothing about the lens.
        var s = TargetLanguageStreak()
        s.read(allIn); s.read(allIn)
        let gap = s.read(ReadTally(inTarget: 0, needing: 0, partial: true))
        #expect(gap)
        let more = s.read(ReadTally(inTarget: 1, needing: 0, partial: true))
        #expect(more)
        // A strip with a block to translate does end it, and a read of the whole lens that finds no text too.
        let needs = s.read(ReadTally(inTarget: 1, needing: 1, partial: true))
        #expect(!needs)
        s.read(allIn); s.read(allIn)
        let empty = s.read(ReadTally(inTarget: 0, needing: 0))
        #expect(!empty)
    }

    @Test func resetForgetsTheRun() {
        var s = TargetLanguageStreak()
        s.read(allIn); s.read(allIn)
        s.reset()
        #expect(!s.shown)
    }

    // MARK: pausing while covered

    @Test func framesStopWhileCoveredAndOneReadIsAskedWhenUncovered() {
        var g = ReadingGate()
        #expect(g.admitsFrames)
        let covered = g.setOccluded(true)
        #expect(covered == .paused)
        #expect(!g.admitsFrames)
        let again = g.setOccluded(true)             // the tracker repeats itself every 0.2 s: counted once
        #expect(again == .none)
        let uncovered = g.setOccluded(false)
        #expect(uncovered == .resumed)
        #expect(g.admitsFrames)
        let twice = g.setOccluded(false)
        #expect(twice == .none)
    }

    @Test func aLensNeverCoveredNeverAsksForAReadOfItsOwn() {
        var g = ReadingGate()
        var changes: [ReadingGate.Change] = []
        for _ in 0..<10 { changes.append(g.setOccluded(false)) }
        #expect(changes.allSatisfy { $0 == .none })
    }

    // MARK: Vision's region of interest

    private let size = CGSize(width: 1000, height: 500)

    private func same(_ a: CGRect?, _ b: CGRect) -> Bool {
        guard let a else { return false }
        return abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test func insideBecomesNormalizedWithAFlippedOrigin() {
        let r = VisionRegion.normalized(CGRect(x: 100, y: 50, width: 200, height: 100), in: size)
        #expect(same(r, CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)))
    }

    @Test func aRegionPartlyOutsideIsCutToThePicture() {
        let r = VisionRegion.normalized(CGRect(x: 900, y: 450, width: 400, height: 400), in: size)
        #expect(same(r, CGRect(x: 0.9, y: 0, width: 0.1, height: 0.1)))
    }

    @Test func aRegionOutsideThePictureHasNoRegionOfInterest() {
        // The suspect of the v1.0.0 crash: `intersection` is `.null`, whose origin is infinite.
        #expect(VisionRegion.normalized(CGRect(x: 2000, y: 100, width: 50, height: 50), in: size) == nil)
        #expect(VisionRegion.normalized(CGRect(x: 100, y: -300, width: 50, height: 50), in: size) == nil)
    }

    @Test func lessThanOnePixelHasNoRegionOfInterest() {
        #expect(VisionRegion.normalized(CGRect(x: 100, y: 100, width: 0.4, height: 50), in: size) == nil)
        #expect(VisionRegion.normalized(CGRect(x: 100, y: 100, width: 50, height: 0), in: size) == nil)
        #expect(VisionRegion.normalized(CGRect(x: 999.5, y: 10, width: 40, height: 10), in: size) == nil)
    }

    @Test func nothingFiniteHasNoRegionOfInterest() {
        #expect(VisionRegion.normalized(.null, in: size) == nil)
        #expect(VisionRegion.normalized(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), in: size) == nil)
        #expect(VisionRegion.normalized(CGRect(x: 0, y: 0, width: 10, height: 10), in: .zero) == nil)
    }

    @Test func theWholePictureIsTheFullRegion() {
        #expect(same(VisionRegion.normalized(CGRect(origin: .zero, size: size), in: size), CGRect(x: 0, y: 0, width: 1, height: 1)))
    }
}
