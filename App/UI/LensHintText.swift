import MwoyeoCore

/// The words of a lens's hint (`LensHint`), as the pill and the image window say them. Short: the pill truncates at the lens's
/// width, and a click does what the line offers.
enum LensHintText {
    static func line(_ hint: LensHint) -> String {
        switch hint {
        case .allowScreenRecording: String(localized: "Allow screen recording")
        case .restartToFinish: String(localized: "Restart Mwoyeo to finish")
        case let .downloadPack(pair): downloadPack(pair)
        case let .downloadingPack(pair): downloading(pair)
        case let .downloadNotFinished(pair): notFinished(pair)
        case let .pairNotSupported(pair): notSupported(pair)
        case .preparingRecognition: String(localized: "Preparing text recognition — first time only")
        case .recognitionNotResponding: String(localized: "Text recognition isn’t responding")
        case .recognitionNeedsDiskSpace: String(localized: "Not enough free space for text recognition")
        case let .translationNotAnswering(engine, _): String(localized: "Translation isn’t answering (\(engine))")
        case let .translationSlow(engine): String(localized: "Translation is slow (\(engine)) — retrying")
        case let .alreadyInTarget(target): String(localized: "Already in \(Languages.name(target))")
        }
    }

    /// The language the pack is for: with the source on Detect, the one the translator found in the text.
    static func downloadPack(_ pair: PackPair) -> String { String(localized: "Download \(Languages.name(pair.source)) (once)") }

    /// The sheet for the pack is up (in Settings, or over the picture): nothing to ask for again; a click goes to the window it is in.
    static func downloading(_ pair: PackPair) -> String { String(localized: "Downloading \(Languages.name(pair.source))…") }

    /// The sheet ended and the pack is not there: declined, interrupted, or no connection. The click asks again.
    static func notFinished(_ pair: PackPair) -> String { String(localized: "\(Languages.name(pair.source)) download didn’t finish — try again") }

    /// The same, as the state only, where a button beside it already says "Try again" (the panel's banner, the image window, a row's line).
    static func notFinishedState(_ pair: PackPair) -> String { String(localized: "\(Languages.name(pair.source)) download didn’t finish") }

    /// The line in the menu panel's lens row, which has room for a short one: the pill's words, the state only for a download that ended.
    static func rowLine(_ hint: LensHint) -> String {
        if case let .downloadNotFinished(pair) = hint { return notFinishedState(pair) }
        return line(hint)
    }

    /// The pair has no translation (the same language twice): the languages are the thing to change.
    static func notSupported(_ pair: PackPair) -> String { String(localized: "\(Languages.name(pair.source)) → \(Languages.name(pair.target)) isn’t supported") }
}
