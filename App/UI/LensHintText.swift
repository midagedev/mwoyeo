import MwoyeoCore

/// The words of a lens's hint (`LensHint`), as the pill and the image window say them. Short: the pill truncates at the lens's
/// width, and a click does what the line offers.
enum LensHintText {
    static func line(_ hint: LensHint) -> String {
        switch hint {
        case .allowScreenRecording: String(localized: "Allow screen recording")
        case .restartToFinish: String(localized: "Restart Mwoyeo to finish")
        case let .downloadPack(pair): downloadPack(pair)
        case .preparingRecognition: String(localized: "Preparing text recognition — first time only")
        case .recognitionNotResponding: String(localized: "Text recognition isn’t responding")
        case let .alreadyInTarget(target): String(localized: "Already in \(Languages.name(target))")
        }
    }

    /// The language the pack is for: with the source on Detect, the one the translator found in the text.
    static func downloadPack(_ pair: PackPair) -> String { String(localized: "Download \(Languages.name(pair.source)) (once)") }
}
