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
    /// The text recognizer is compiling its models the first time (65 to 119 s on a new build).
    case preparingRecognition
    /// Everything the lens read is already in the target language (`target` is its code).
    case alreadyInTarget(target: String)

    public enum Action: Equatable, Sendable {
        case openScreenRecordingSettings
        case restart
        case downloadPack(PackPair)
    }

    /// The one thing the user can do about it, nil where there is nothing to do (waiting, or nothing to translate).
    public var action: Action? {
        switch self {
        case .allowScreenRecording: .openScreenRecordingSettings
        case .restartToFinish: .restart
        case let .downloadPack(pair): .downloadPack(pair)
        case .preparingRecognition, .alreadyInTarget: nil
        }
    }

    /// A hint the lens cannot work without shows the pill even where the look keeps it hidden; "already in" is only news.
    public var showsTabAlways: Bool {
        if case .alreadyInTarget = self { false } else { true }
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
    /// The text recognizer is in its first-time setup (the menu panel's "Preparing text recognition…").
    public var recognitionPreparing = false
    /// The lens shows something translated: it is evidently working, so waiting for the setup needs no line, and some text
    /// was not in the target language after all.
    public var showsTranslations = false
    /// The target language, once enough reads agreed that all the text is in it (`TargetLanguageStreak`).
    public var alreadyInTarget: String?

    public init(screen: Screen = .fine, missingPack: PackPair? = nil, recognitionPreparing: Bool = false,
                showsTranslations: Bool = false, alreadyInTarget: String? = nil) {
        self.screen = screen
        self.missingPack = missingPack
        self.recognitionPreparing = recognitionPreparing
        self.showsTranslations = showsTranslations
        self.alreadyInTarget = alreadyInTarget
    }

    /// The line for the pill: Screen Recording first (nothing works without it), then the language pack (what stops every
    /// translation), then the setup (it ends by itself), then "already in" (news, not a fault); nil when all is well.
    public func hint() -> LensHint? {
        switch screen {
        case .notAllowed: return .allowScreenRecording
        case .notActive: return .restartToFinish
        case .fine: break
        }
        if let missingPack { return .downloadPack(missingPack) }
        if recognitionPreparing, !showsTranslations { return .preparingRecognition }
        if let alreadyInTarget, !showsTranslations { return .alreadyInTarget(target: alreadyInTarget) }
        return nil
    }
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
