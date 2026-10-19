import CoreGraphics
import Foundation

/// A language pack a lens waits for: translating `source` to `target` needs it.
public struct PackPair: Equatable, Hashable, Sendable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// Why a capture failed, as far as the lens can tell the user what to do about it.
public enum CaptureFailure: Equatable, Sendable {
    /// ScreenCaptureKit refused: the process has no usable Screen Recording grant (`SCStreamError.userDeclined`).
    case permission
    /// Anything else (no such display, the user stopped sharing…): the menu panel has the message; the lens says nothing.
    case other

    public static let screenCaptureKitDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
    public static let userDeclinedCode = -3801

    public static func classify(domain: String, code: Int) -> CaptureFailure {
        domain == screenCaptureKitDomain && code == userDeclinedCode ? .permission : .other
    }
}

/// What a lens that shows nothing can say about itself, at most one line, by priority (`LensSignals.hint`).
///
/// Every first-run failure ends the same way for a new user: the lens pill reads "Auto → English" and nothing happens, and the
/// reason lives only in the menu panel, which is not open. This is the one owner that maps the lens's state to the line on its
/// pill; the words and the actions are the app's (`LensHintText`).
public enum LensHint: Equatable, Sendable {
    /// Screen Recording is not allowed (never, or revoked since).
    case allowScreenRecording
    /// It is allowed, but this process still cannot capture: a grant takes effect in a process started after it.
    case restartToFinish
    /// The language pack for the pair is not installed.
    case downloadPack(PackPair)
    /// The system's sheet for the pack is up: nothing to ask for again, but the sheet is in a window the person may not see.
    case downloadingPack(PackPair)
    /// The sheet ended and the pair still does not translate (declined, interrupted, or no connection): the same ask, said so.
    case downloadNotFinished(PackPair)
    /// The pair has no translation at all (the same language twice): only other languages help.
    case pairNotSupported(PackPair)
    /// The text recognizer is compiling its models the first time (65 to 119 s on a new build).
    case preparingRecognition
    /// A recognition worker was stuck for minutes, was restarted, and was stuck again (`RecognitionWait.notResponding`).
    case recognitionNotResponding
    /// The lens read text and the translator keeps failing it: two batches in a row, none translated (`TranslationWait`).
    /// `engine` is the name the user knows it by; `addedEngine`: it is one they added, so its settings are where to look.
    case translationNotAnswering(engine: String, addedEngine: Bool)
    /// The same, but the engine keeps hitting its deadline instead of failing.
    case translationSlow(engine: String)
    /// Everything the lens read is already in the target language (`target` is its code).
    case alreadyInTarget(target: String)

    public enum Action: Equatable, Sendable {
        case openScreenRecordingSettings
        case restart
        case downloadPack(PackPair)
        /// Settings on Translation, where an added engine is chosen and edited, and a pack's sheet is up.
        case openTranslationSettings
        /// Settings on General, where the languages are chosen.
        case chooseLanguages
    }

    /// The one thing the user can do about it, nil where there is nothing to do (waiting, or nothing to translate).
    public var action: Action? {
        switch self {
        case .allowScreenRecording: .openScreenRecordingSettings
        case .restartToFinish: .restart
        case let .downloadPack(pair), let .downloadNotFinished(pair): .downloadPack(pair)
        case .downloadingPack: .openTranslationSettings
        case .pairNotSupported: .chooseLanguages
        case let .translationNotAnswering(_, addedEngine): addedEngine ? .openTranslationSettings : nil
        case .preparingRecognition, .recognitionNotResponding, .translationSlow, .alreadyInTarget: nil
        }
    }

    /// The hint is about the language pair's pack or support (what the menu panel's lens row repeats and Settings can fix).
    public var isAboutLanguages: Bool {
        switch self {
        case .downloadPack, .downloadingPack, .downloadNotFinished, .pairNotSupported: true
        default: false
        }
    }

    /// A hint the lens cannot work without shows the pill even where the look keeps it hidden; "already in" is only news.
    public var showsTabAlways: Bool {
        if case .alreadyInTarget = self { false } else { true }
    }
}

/// A lens's translation trouble (`TranslationWait.trouble`), with the engine to name.
public struct TranslationTrouble: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The newest failed group threw.
        case notAnswering
        /// The newest failed group hit its deadline.
        case slow
    }

    public var kind: Kind
    public var engine: String
    public var addedEngine: Bool

    public init(kind: Kind, engine: String, addedEngine: Bool) {
        self.kind = kind
        self.engine = engine
        self.addedEngine = addedEngine
    }
}

/// Everything the hint depends on, for one lens.
public struct LensSignals: Equatable, Sendable {
    public enum Screen: Equatable, Sendable {
        case fine
        /// No Screen Recording grant.
        case notAllowed
        /// Granted, and capture still says no.
        case notActive

        public init(allowed: Bool, failure: CaptureFailure?) {
            if !allowed { self = .notAllowed } else if failure == .permission { self = .notActive } else { self = .fine }
        }
    }

    public var screen = Screen.fine
    /// The pack the translator is missing for this lens's pair.
    public var missingPack: PackPair?
    /// What became of the download of that pack (`PackLedger`); nil when it was not asked for yet.
    public var packPhase: PackLedger.Phase?
    /// The pair this lens translates has no translation at all. Set only for a lens whose source is chosen: on Detect an unsupported
    /// group is one block the detector got wrong, not the lens's setup.
    public var unsupportedPair: PackPair?
    /// The text recognizer is in its first-time setup (the menu panel's "Preparing text recognition…"). App-wide; the lens's own
    /// state is `recognition`, which says more and wins over it.
    public var recognitionPreparing = false
    /// What this lens's own read waits for (`ReadWait.hint`): no reader ready, none responding, or the worker switched off.
    public var recognition: RecognitionWait?
    /// The lens shows something translated: it is evidently working, so waiting for the setup needs no line, and some text
    /// was not in the target language after all.
    public var showsTranslations = false
    /// The target language, once enough reads agreed that all the text is in it (`TargetLanguageStreak`).
    public var alreadyInTarget: String?
    /// The translator keeps failing the text this lens read (`TranslationWait`).
    public var translation: TranslationTrouble?

    public init(screen: Screen = .fine, missingPack: PackPair? = nil, recognitionPreparing: Bool = false,
                recognition: RecognitionWait? = nil, showsTranslations: Bool = false, alreadyInTarget: String? = nil,
                translation: TranslationTrouble? = nil, packPhase: PackLedger.Phase? = nil, unsupportedPair: PackPair? = nil) {
        self.screen = screen
        self.missingPack = missingPack
        self.packPhase = packPhase
        self.unsupportedPair = unsupportedPair
        self.recognitionPreparing = recognitionPreparing
        self.recognition = recognition
        self.showsTranslations = showsTranslations
        self.alreadyInTarget = alreadyInTarget
        self.translation = translation
    }

    /// The line for the pill: Screen Recording first (nothing works without it), then the language pack (what stops every
    /// translation; said as asking, downloading or not finished) and a pair that cannot be translated, then recognition (the lens's own wait for a reader, else the app's first-time setup: both end by themselves
    /// except "not responding" and "restart"), then the translator's trouble (text was read and nothing comes back translated),
    /// then "already in" (news, not a fault); nil when all is well.
    public func hint() -> LensHint? {
        switch screen {
        case .notAllowed: return .allowScreenRecording
        case .notActive: return .restartToFinish
        case .fine: break
        }
        if let missingPack {
            switch packPhase {
            case .downloading?: return .downloadingPack(missingPack)
            case .notFinished?: return .downloadNotFinished(missingPack)
            case nil: return .downloadPack(missingPack)
            }
        }
        // A lens that translates nothing and whose pair cannot be translated: the language pickers are the only way out.
        if let unsupportedPair, !showsTranslations { return .pairNotSupported(unsupportedPair) }
        if !showsTranslations {
            switch recognition {
            case .notResponding: return .recognitionNotResponding
            // A worker that is switched off for this run: the one thing to do is the restart the Screen Recording grant also needs.
            case .restartApp: return .restartToFinish
            case .preparing: return .preparingRecognition
            case nil: if recognitionPreparing { return .preparingRecognition }
            }
            if let translation {
                switch translation.kind {
                case .notAnswering: return .translationNotAnswering(engine: translation.engine, addedEngine: translation.addedEngine)
                case .slow: return .translationSlow(engine: translation.engine)
                }
            }
        }
        if let alreadyInTarget, !showsTranslations { return .alreadyInTarget(target: alreadyInTarget) }
        return nil
    }
}

/// What a lens translates now, to tell which of the translator's batches are its own (`TranslationRoute.serves`).
public struct LensPair: Equatable, Sendable {
    /// A language code, or "auto".
    public var source: String
    public var target: String
    /// The added engine the lens has chosen; nil is Apple.
    public var engine: UUID?

    public init(source: String, target: String, engine: UUID?) {
        self.source = source
        self.target = target
        self.engine = engine
    }
}

/// Where one language group of a batch went: its pair and the engine that really answered or failed it. Not the engine the user chose:
/// while a chosen engine rests after a failure, Apple translates in its place, and it is Apple that fails then.
public struct TranslationRoute: Equatable, Sendable {
    /// The group's language code (the one detected in its text when the lens is on Detect; "und" when none was).
    public var source: String
    public var target: String
    /// The added engine that was asked, nil for Apple.
    public var engineID: UUID?
    /// The name the user knows the engine by.
    public var engineName: String

    public init(source: String, target: String, engineID: UUID?, engineName: String) {
        self.source = source
        self.target = target
        self.engineID = engineID
        self.engineName = engineName
    }

    /// This is the lens's own translation: its target, its source (or any on Detect), and the engine it chose or Apple standing in for
    /// it. Another added engine is not: a batch that began before the lens changed engine says nothing about the new one.
    public func serves(_ lens: LensPair) -> Bool {
        Self.sameLanguage(target, lens.target) && (lens.source == "auto" || Self.sameLanguage(source, lens.source))
            && (engineID == nil || engineID == lens.engine)
    }

    private static func sameLanguage(_ a: String, _ b: String) -> Bool {
        Locale.Language(identifier: a).languageCode == Locale.Language(identifier: b).languageCode
    }
}

/// What the translator did with one batch of lines (one `translate` call, at most three lines), as a lens's hint hears it: one event
/// per batch, with a result per language group inside it. A batch that splits in two groups, whose deadlines of 7 s and 9 s run one after
/// the other, is one slow batch, and each lens reads the groups that are its own (`TranslationWait.apply`).
public struct TranslationEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Some line of the group came back translated.
        case answered
        /// None did, and the engine threw (a missing pack or an unsupported pair is not this: the pack has its own hint).
        case failed
        /// None did, and the engine hit its deadline: 5 s + 2 s a line for Apple, 10 s + 2 s a line for an added engine.
        case timedOut
    }

    public struct Group: Equatable, Sendable {
        public var route: TranslationRoute
        public var kind: Kind

        public init(route: TranslationRoute, kind: Kind) {
            self.route = route
            self.kind = kind
        }
    }

    public var groups: [Group]

    public init(groups: [Group]) { self.groups = groups }
    public init(_ kind: Kind, _ route: TranslationRoute) { groups = [Group(route: route, kind: kind)] }
}

/// "Translation isn't answering" / "Translation is slow": said once this lens has read text that needs translating and
/// `streak` batches of its own in a row have failed or timed out with none translated in between, each within `window` of the last, the
/// newest not longer ago than `window` (a lens that reads later is not told about failures from before).
/// One failure never says it: a single slow batch (it has already waited its deadlines, 11 s for three lines in one group) is retried
/// by the queue after 2 s, and the second failure is what tells the engine is not just slow once. Ended by the first translated
/// batch, by a full read that finds nothing to translate (the blank lens beside a failing one stays quiet), or by `reset()`.
///
/// `window` is the longest gap inside one run of failures: a batch through an added engine that times out (10 + 2·3 = 16 s) and then
/// Apple (5 + 2·3 = 11 s), then the queue's longest rest (30 s), is 57 s; a batch split in language groups adds the deadlines of the
/// others (three groups of one line, 7 s each, are 21 s), about 70 s at most. Failing at once, the gaps are the rests: 2 s, 4 s, 8 s…
public struct TranslationWait: Equatable, Sendable {
    public static let streak = 2
    public static let window: TimeInterval = 90

    /// When the newest `streak` failures of this run arrived (any monotonic clock, in seconds), and the newest group.
    private var times: [TimeInterval] = []
    private var newest: TranslationEvent.Group?
    /// This lens has read text that needs translating and not seen it all translated.
    private var wanting = false

    public init() {}

    /// Feeds what became of one batch of the translator's. `now` is the arrival time. Only the groups that are `lens`'s own count: one
    /// of them translated ends the run, otherwise the batch is one more failure and the last of its own groups is the one named.
    public mutating func apply(_ event: TranslationEvent, at now: TimeInterval, lens: LensPair) {
        let own = event.groups.filter { $0.route.serves(lens) }
        guard let last = own.last else { return }
        if own.contains(where: { $0.kind == .answered }) {
            reset()
            return
        }
        if let previous = times.last, now - previous > Self.window { times = [] }
        times = Array((times + [now]).suffix(Self.streak))
        newest = last
    }

    /// Feeds one read of the lens: text that needs translating makes the lens wait for it; a read of the whole lens that finds none
    /// ends the wait, and a partial one (a strip a scroll uncovered) says nothing either way, as for `TargetLanguageStreak`.
    public mutating func read(_ tally: ReadTally) {
        if tally.needing > 0 { wanting = true } else if !tally.partial { wanting = false }
    }

    /// The engine or the language pair changed: what failed before says nothing about the new one. The wait for text stays.
    public mutating func reset() {
        times = []
        newest = nil
    }

    /// The trouble to say at `now`, or nil, naming the engine that failed last: Apple while a chosen engine rests.
    public func trouble(at now: TimeInterval) -> TranslationTrouble? {
        guard wanting, times.count >= Self.streak, let last = times.last, now - last <= Self.window, let newest else { return nil }
        return TranslationTrouble(kind: newest.kind == .timedOut ? .slow : .notAnswering, engine: newest.route.engineName,
                                  addedEngine: newest.route.engineID != nil)
    }

    /// When a run that has been raised stops counting if no newer failure comes (the same clock as `now`), nil without a run.
    public var lapse: TimeInterval? { times.count >= Self.streak ? times.last.map { $0 + Self.window } : nil }
}

/// What one read of a lens found, counted over its blocks of text worth a look (letters in them, and not a time stamp, a link
/// or a formula that stays as written).
public struct ReadTally: Equatable, Sendable {
    /// Blocks already in the target language.
    public var inTarget: Int
    /// Blocks that need translating.
    public var needing: Int

    /// The read covered only a part of the lens's capture (the strip a scroll uncovered, the rows that changed).
    public var partial: Bool

    public init(inTarget: Int, needing: Int, partial: Bool = false) {
        self.inTarget = inTarget
        self.needing = needing
        self.partial = partial
    }
}

/// "Already in <target language>": said only after `reads` consecutive reads agreed that there was text and all of it was in the
/// target language, and dropped as soon as one read finds a block to translate or, reading the whole lens, no text at all (a blank
/// lens on an empty area is fine, and says nothing). A partial read that finds no text (a gap between paragraphs in the strip a
/// scroll uncovered) says nothing either way.
public struct TargetLanguageStreak: Equatable, Sendable {
    public static let reads = 2

    public private(set) var run = 0

    public init() {}

    public var shown: Bool { run >= Self.reads }

    /// Feeds one read; returns whether the line is up afterwards.
    @discardableResult
    public mutating func read(_ tally: ReadTally) -> Bool {
        if tally.needing == 0, tally.inTarget > 0 { run += 1 } else if tally.needing > 0 || !tally.partial { run = 0 }
        return shown
    }

    public mutating func reset() { run = 0 }
}

/// A lens whose window is covered, closed or minimized reads nothing: the capture shows the window above, not the one it
/// follows, so reading it would translate (and with a cloud engine send away) text the user cannot even see.
public struct ReadingGate: Equatable, Sendable {
    public enum Change: Equatable, Sendable { case none, paused, resumed }

    public private(set) var occluded = false

    public init() {}

    /// Frames reach the pipeline only while the lens is uncovered.
    public var admitsFrames: Bool { !occluded }

    /// `.paused` when the lens just got covered; `.resumed` when it just got uncovered, which is when to ask for one read
    /// (no frame comes for content that did not change).
    public mutating func setOccluded(_ on: Bool) -> Change {
        guard on != occluded else { return .none }
        occluded = on
        return on ? .paused : .resumed
    }
}

/// Vision's region of interest: a rectangle in normalized coordinates of the picture, origin at its bottom left.
public enum VisionRegion {
    /// `r` in picture pixels (origin top left) as Vision's region of interest, or nil when no pixel of it lies in the picture.
    ///
    /// An empty intersection has no origin (CoreGraphics gives `.null`, whose origin is infinite), and Vision traps on it
    /// (`createRegionOfInterestCrop`, the v1.0.0 crash report): the caller skips the request instead.
    public static func normalized(_ r: CGRect, in size: CGSize) -> CGRect? {
        guard size.width >= 1, size.height >= 1, !r.isNull, r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return nil }
        let c = r.intersection(CGRect(origin: .zero, size: size))
        guard !c.isNull, c.width >= 1, c.height >= 1 else { return nil }
        return CGRect(x: c.minX / size.width, y: 1 - c.maxY / size.height, width: c.width / size.width, height: c.height / size.height)
    }
}
