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

    @Test func theDiskSitsAboveTheOtherWaitsAndBelowThePackAndTheGrant() {
        // priority: screen > pack > pair > the disk > not responding > restart > preparing (the app's setup) > translation > already-in
        var s = LensSignals(recognitionPreparing: true, recognition: .needsDiskSpace)
        #expect(s.hint() == .recognitionNeedsDiskSpace, "above the app's own setup, which would say 'preparing' for ever")
        s.translation = TranslationTrouble(kind: .notAnswering, engine: "Apple", addedEngine: false)
        s.alreadyInTarget = "en"
        #expect(s.hint() == .recognitionNeedsDiskSpace, "and above the translator's trouble and 'already in'")
        s.unsupportedPair = PackPair(source: "ko", target: "ko")
        #expect(s.hint() == .pairNotSupported(PackPair(source: "ko", target: "ko")))
        s.unsupportedPair = nil
        s.missingPack = ja
        #expect(s.hint() == .downloadPack(ja), "the pack is what stops every translation")
        s.missingPack = nil
        s.screen = .notActive
        #expect(s.hint() == .restartToFinish)
        s.screen = .notAllowed
        #expect(s.hint() == .allowScreenRecording)
        s.screen = .fine
        s.showsTranslations = true
        #expect(s.hint() == nil, "a lens that translates needs no line")
    }

    @Test func theDiskHintOpensStorageAndIsNotAboutLanguages() {
        let hint = LensHint.recognitionNeedsDiskSpace
        #expect(hint.action == .openStorageSettings && !hint.isAboutLanguages && hint.showsTabAlways)
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
        // H1 translation-wait: Settings is where an added engine is looked at; Apple has nothing to open.
        #expect(LensHint.translationNotAnswering(engine: "OpenAI", addedEngine: true).action == .openTranslationSettings)
        #expect(LensHint.translationNotAnswering(engine: "Apple", addedEngine: false).action == nil)
        #expect(LensHint.translationSlow(engine: "OpenAI").action == nil)
    }

    @Test func onlyNewsLeavesTheTabToTheUsersLook() {
        #expect(LensHint.allowScreenRecording.showsTabAlways)
        #expect(LensHint.downloadPack(ja).showsTabAlways)
        #expect(LensHint.preparingRecognition.showsTabAlways)
        #expect(LensHint.recognitionNotResponding.showsTabAlways)
        #expect(LensHint.translationNotAnswering(engine: "Apple", addedEngine: false).showsTabAlways)
        #expect(LensHint.translationSlow(engine: "Apple").showsTabAlways)
        #expect(!LensHint.alreadyInTarget(target: "en").showsTabAlways)
    }

    // MARK: the translator keeps failing (H1 translation-wait, 2026-10-18)

    private let needing = ReadTally(inTarget: 0, needing: 3)
    private let apple = TranslationTrouble(kind: .notAnswering, engine: "Apple", addedEngine: false)
    private let gemini = UUID(), openAI = UUID()
    /// A lens on Detect → Korean, on Apple; and the route of a group Apple translated for it.
    private let koLens = LensPair(source: "auto", target: "ko", engine: nil)
    private let appleKo = TranslationRoute(source: "en", target: "ko", engineID: nil, engineName: "Apple")

    private func route(_ source: String = "en", _ target: String = "ko", via engine: UUID? = nil, _ name: String = "Apple") -> TranslationRoute {
        TranslationRoute(source: source, target: target, engineID: engine, engineName: name)
    }

    /// A lens that read three lines, then these events (a kind at a time) for `route`, which `lens` hears or not.
    private func wait(_ events: [(TranslationEvent.Kind, TimeInterval)], route: TranslationRoute? = nil, lens: LensPair? = nil,
                      read tally: ReadTally? = nil) -> TranslationWait {
        var w = TranslationWait()
        w.read(tally ?? needing)
        for (kind, at) in events { w.apply(TranslationEvent(kind, route ?? appleKo), at: at, lens: lens ?? koLens) }
        return w
    }

    private func trouble(_ w: TranslationWait, at now: TimeInterval) -> TranslationTrouble? { w.trouble(at: now) }

    @Test func troubleSitsBetweenRecognitionAndAlreadyIn() {
        // priority: screen > pack > recognition > translation trouble > already-in
        var s = LensSignals(alreadyInTarget: "en", translation: apple)
        #expect(s.hint() == .translationNotAnswering(engine: "Apple", addedEngine: false))
        s.recognition = .notResponding
        #expect(s.hint() == .recognitionNotResponding)
        s.recognition = nil
        s.recognitionPreparing = true
        #expect(s.hint() == .preparingRecognition)
        s.recognitionPreparing = false
        s.missingPack = ja
        #expect(s.hint() == .downloadPack(ja))
        s.missingPack = nil
        s.screen = .notActive
        #expect(s.hint() == .restartToFinish)
        s.screen = .notAllowed
        #expect(s.hint() == .allowScreenRecording)
        #expect(LensSignals(alreadyInTarget: "en", translation: apple).hint() != .alreadyInTarget(target: "en"))
    }

    @Test func troubleNamesTheEngineAndHowItFailed() {
        let slow = TranslationTrouble(kind: .slow, engine: "Gemini", addedEngine: true)
        #expect(LensSignals(translation: slow).hint() == .translationSlow(engine: "Gemini"))
        let added = TranslationTrouble(kind: .notAnswering, engine: "Gemini", addedEngine: true)
        #expect(LensSignals(translation: added).hint() == .translationNotAnswering(engine: "Gemini", addedEngine: true))
    }

    @Test func troubleSaysNothingOnceTheLensShowsTranslations() {
        #expect(LensSignals(showsTranslations: true, translation: apple).hint() == nil)
    }

    @Test func oneSlowBatchNeverRaisesIt() {
        // 0.8 s: the read; 16.9 s: the first batch of three lines, in two language groups, hit both deadlines (7 s + 9 s): one event.
        let both = TranslationEvent(groups: [.init(route: route("ja"), kind: .timedOut), .init(route: route("en"), kind: .timedOut)])
        var w = TranslationWait()
        w.read(needing)
        w.apply(both, at: 16.9, lens: koLens)
        #expect(trouble(w, at: 16.9) == nil)
        #expect(trouble(wait([(.timedOut, 16.9)]), at: 16.9) == nil)
        #expect(trouble(wait([(.failed, 0.7)]), at: 0.7) == nil)
    }

    @Test func twoInARowRaiseItWithTheNewestKind() {
        // slow:20000 on chat.png: batch timeouts at 16.9 s and 29.9 s (the queue rests 2 s between).
        #expect(trouble(wait([(.timedOut, 16.9), (.timedOut, 29.9)]), at: 29.9)?.kind == .slow)
        #expect(trouble(wait([(.failed, 0.7), (.failed, 2.8)]), at: 2.8)?.kind == .notAnswering)
        // A mix says what the newest did.
        #expect(trouble(wait([(.failed, 0.7), (.timedOut, 14)]), at: 14)?.kind == .slow)
        #expect(trouble(wait([(.timedOut, 16.9), (.failed, 19)]), at: 19)?.kind == .notAnswering)
    }

    @Test func aTranslatedGroupBetweenEndsTheRun() {
        // fail-once: one failure, then the engine answers.
        #expect(trouble(wait([(.failed, 0.7), (.answered, 2.9)]), at: 2.9) == nil)
        #expect(trouble(wait([(.failed, 0.7), (.answered, 2.9), (.failed, 5)]), at: 5) == nil)
        // And it ends a raised one at once.
        var w = wait([(.failed, 0.7), (.failed, 2.8)])
        #expect(trouble(w, at: 2.8) != nil)
        w.apply(TranslationEvent(.answered, appleKo), at: 6.9, lens: koLens)
        #expect(trouble(w, at: 6.9) == nil)
        w.apply(TranslationEvent(.failed, appleKo), at: 9, lens: koLens)
        #expect(trouble(w, at: 9) == nil)
        w.apply(TranslationEvent(.failed, appleKo), at: 13, lens: koLens)
        #expect(trouble(w, at: 13) != nil)
    }

    @Test func failuresFarApartAreNotARun() {
        let gap = TranslationWait.window + 1
        #expect(trouble(wait([(.failed, 10), (.failed, 10 + gap)]), at: 10 + gap) == nil)
        // The longest rest inside a run is 30 s after a batch of 16 + 11 s: it stays one run.
        #expect(trouble(wait([(.timedOut, 10), (.timedOut, 10 + 16 + 11 + 30)]), at: 67) != nil)
        // A third failure after the stale one starts from that one: it takes two again.
        var w = wait([(.failed, 10), (.failed, 10 + gap)])
        w.apply(TranslationEvent(.failed, appleKo), at: 10 + gap + 4, lens: koLens)
        #expect(trouble(w, at: 10 + gap + 4) != nil)
    }

    @Test func aLensThatReadNothingToTranslateIsQuiet() {
        // The blank lens beside a failing one: the translator's trouble is not this lens's.
        var w = TranslationWait()
        w.apply(TranslationEvent(.failed, appleKo), at: 1, lens: koLens)
        w.apply(TranslationEvent(.failed, appleKo), at: 3, lens: koLens)
        #expect(trouble(w, at: 3) == nil)
        w.read(needing)
        #expect(trouble(w, at: 3) != nil)
        w.read(ReadTally(inTarget: 2, needing: 0))
        #expect(trouble(w, at: 3) == nil)
        w.read(needing)
        #expect(trouble(w, at: 3) != nil)
        // A strip with no text says nothing about the lens, as for "already in".
        w.read(ReadTally(inTarget: 0, needing: 0, partial: true))
        #expect(trouble(w, at: 3) != nil)
        w.read(ReadTally(inTarget: 0, needing: 0))
        #expect(trouble(w, at: 3) == nil)
    }

    @Test func aNewEngineOrPairStartsOver() {
        var w = wait([(.timedOut, 16.9), (.timedOut, 29.9)])
        #expect(trouble(w, at: 29.9) != nil)
        w.reset()
        #expect(trouble(w, at: 29.9) == nil)
        w.apply(TranslationEvent(.timedOut, appleKo), at: 40, lens: koLens)
        #expect(trouble(w, at: 40) == nil)               // one is not two
        w.apply(TranslationEvent(.timedOut, appleKo), at: 52, lens: koLens)
        #expect(trouble(w, at: 52) != nil)               // and the lens still waits for its text
    }

    @Test func theRunKeepsOnlyWhatItNeeds() {
        var w = TranslationWait()
        w.read(needing)
        for i in 0..<1000 { w.apply(TranslationEvent(.failed, appleKo), at: Double(i), lens: koLens) }
        #expect(trouble(w, at: 999)?.kind == .notAnswering)
        w.apply(TranslationEvent(.answered, appleKo), at: 1001, lens: koLens)
        #expect(trouble(w, at: 1001) == nil)
    }

    // MARK: which engine it names (a chosen engine rests and Apple stands in)

    @Test func theHintNamesTheEngineThatFailed() {
        let lens = LensPair(source: "auto", target: "ko", engine: gemini)
        let viaGemini = route(via: gemini, "Gemini")
        var w = wait([(.failed, 20), (.failed, 40)], route: viaGemini, lens: lens)
        let added = trouble(w, at: 40)
        #expect(added == TranslationTrouble(kind: .notAnswering, engine: "Gemini", addedEngine: true))
        #expect(LensSignals(translation: added).hint()?.action == .openTranslationSettings)
        // Gemini rests (the queue goes on, Apple takes the batches) and Apple fails them: the hint is Apple's, and has nothing to open.
        w.apply(TranslationEvent(.failed, appleKo), at: 55, lens: lens)
        let standIn = trouble(w, at: 55)
        #expect(standIn == TranslationTrouble(kind: .notAnswering, engine: "Apple", addedEngine: false))
        #expect(LensSignals(translation: standIn).hint() == .translationNotAnswering(engine: "Apple", addedEngine: false))
        #expect(LensSignals(translation: standIn).hint()?.action == nil)
    }

    @Test func theLastOfTheLensOwnGroupsIsTheOneNamed() {
        let event = TranslationEvent(groups: [.init(route: route("ja", via: gemini, "Gemini"), kind: .failed),
                                              .init(route: route("en"), kind: .timedOut)])
        var w = TranslationWait()
        w.read(needing)
        w.apply(event, at: 5, lens: LensPair(source: "auto", target: "ko", engine: gemini))
        w.apply(event, at: 25, lens: LensPair(source: "auto", target: "ko", engine: gemini))
        #expect(trouble(w, at: 25) == TranslationTrouble(kind: .slow, engine: "Apple", addedEngine: false))
    }

    // MARK: failures from before the lens read (a lens that starts later, or whose trouble is over)

    @Test func failuresFromBeforeTheWindowDoNotCount() {
        // Two failures at 10 s and 12 s; this lens read its first text at 500 s.
        var w = TranslationWait()
        w.apply(TranslationEvent(.failed, appleKo), at: 10, lens: koLens)
        w.apply(TranslationEvent(.failed, appleKo), at: 12, lens: koLens)
        w.read(needing)
        #expect(trouble(w, at: 13) != nil)
        #expect(trouble(w, at: 12 + TranslationWait.window) != nil)
        #expect(trouble(w, at: 12 + TranslationWait.window + 0.1) == nil)
        #expect(trouble(w, at: 500) == nil)
        // A new failure brings the run back to life.
        w.apply(TranslationEvent(.failed, appleKo), at: 501, lens: koLens)
        #expect(trouble(w, at: 501) == nil)       // 12 s is too long ago for it to be two
        w.apply(TranslationEvent(.failed, appleKo), at: 503, lens: koLens)
        #expect(trouble(w, at: 503) != nil)
    }

    @Test func aRaisedRunSaysWhenItLapses() {
        var w = wait([(.failed, 10)])
        #expect(w.lapse == nil)                    // one failure is no run
        w.apply(TranslationEvent(.failed, appleKo), at: 12, lens: koLens)
        #expect(w.lapse == 12 + TranslationWait.window)
        w.reset()
        #expect(w.lapse == nil)
    }

    @Test func aSteadyRetryKeepsItUp() {
        // slow:20000 retries on the queue's backoff (2, 4, 8, 16, 30 s of rest, 11 s of deadline each): the gaps never reach the window.
        var w = TranslationWait()
        w.read(needing)
        var at = 17.0
        w.apply(TranslationEvent(.timedOut, appleKo), at: at, lens: koLens)
        for rest in [2.0, 4, 8, 16, 30, 30, 30] {
            let next = at + rest + 11
            // Up all the way to the next failure, which comes before the run would lapse.
            #expect(trouble(w, at: next - 0.01) != nil || w.lapse == nil, "gap \(next - at)")
            w.apply(TranslationEvent(.timedOut, appleKo), at: next, lens: koLens)
            #expect(trouble(w, at: next) != nil)
            at = next
        }
    }

    // MARK: another lens's pair (the translator is one for all)

    @Test func anotherTargetIsNotThisLensTrouble() {
        // The lens translates to Korean; a batch to English failed twice.
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: route("ja", "en")), at: 3) == nil)
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: route("ja", "ko")), at: 3) != nil)
        // A region code is the same language.
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: route("en", "ko-KR")), at: 3) != nil)
    }

    @Test func aLensOnOneSourceHearsOnlyThatSource() {
        let ja = LensPair(source: "ja", target: "ko", engine: nil)
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: route("en"), lens: ja), at: 3) == nil)
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: route("ja"), lens: ja), at: 3) != nil)
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: route("zh-Hans"), lens: LensPair(source: "zh-Hant", target: "ko", engine: nil)), at: 3) != nil)
        // On Detect every source is its own, the one nothing could tell included.
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: route("und")), at: 3) != nil)
    }

    @Test func aTranslatedBatchOfAnotherPairDoesNotEndIt() {
        var w = wait([(.failed, 1), (.failed, 3)], route: route("ja"))
        #expect(trouble(w, at: 3) != nil)
        w.apply(TranslationEvent(.answered, route("en", "ja")), at: 4, lens: koLens)       // into Japanese: not this lens's
        #expect(trouble(w, at: 4) != nil)
        w.apply(TranslationEvent(.answered, route("ja")), at: 5, lens: koLens)
        #expect(trouble(w, at: 5) == nil)
    }

    @Test func aBatchOfTwoPairsIsReadByEachLensForItsOwn() {
        let event = TranslationEvent(groups: [.init(route: route("ja"), kind: .answered), .init(route: route("en"), kind: .failed)])
        // The en lens: one failure. Fed twice it is trouble; the ja lens and the Detect lens heard an answer and never are.
        func run(_ lens: LensPair) -> TranslationWait {
            var w = TranslationWait()
            w.read(needing)
            w.apply(event, at: 1, lens: lens)
            w.apply(event, at: 3, lens: lens)
            return w
        }
        #expect(trouble(run(LensPair(source: "en", target: "ko", engine: nil)), at: 3) != nil)
        #expect(trouble(run(LensPair(source: "ja", target: "ko", engine: nil)), at: 3) == nil)
        #expect(trouble(run(koLens), at: 3) == nil)
    }

    @Test func aBatchOfAnotherEngineIsNotThisLensTrouble() {
        // A batch that began under Gemini and ends after the lens went to OpenAI, or to Apple.
        let viaGemini = route(via: gemini, "Gemini")
        let openAILens = LensPair(source: "auto", target: "ko", engine: openAI)
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: viaGemini, lens: openAILens), at: 3) == nil)
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: viaGemini, lens: koLens), at: 3) == nil)
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: viaGemini, lens: LensPair(source: "auto", target: "ko", engine: gemini)), at: 3) != nil)
        // Apple's batches are every lens's: it stands in for the one that rests.
        #expect(trouble(wait([(.failed, 1), (.failed, 3)], route: appleKo, lens: openAILens), at: 3) != nil)
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
