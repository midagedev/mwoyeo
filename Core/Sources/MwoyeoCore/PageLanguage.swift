import Foundation

/// The language of what is read, for a source set to auto: the page's (the lines read lately, the latest weighing most) and one batch's (the
/// language most of its confident lines are in). A Japanese chat read first does not make every later page Japanese: before 2026-10-23 (film5)
/// the page's language was a running count over the whole session, so a lens moved from a Japanese chat onto an English article took its lines
/// for Latin names on a Japanese page (`TranslationFilter.needsTranslation` with `cjkSource`) and never translated them, and since those lines
/// were never detected the count never turned.
public struct PageLanguage: Sendable, Equatable {
    /// How much of its weight a language keeps each time a line of any language is learned.
    public static let keep = 0.8
    private var weights: [String: Double] = [:]

    public init() {}

    /// The language the lines read lately are mostly in; nil before any.
    public var language: String? { weights.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key }

    /// A confidently detected line in `code`.
    public mutating func learn(_ code: String) {
        for k in weights.keys { weights[k]! *= Self.keep }
        weights[code, default: 0] += 1
    }

    /// The source of one batch: the language most of its confident lines are in (`confident`, one code a line), else the page's.
    public func source(ofBatch confident: [String]) -> String? {
        var counts: [String: Int] = [:]
        for c in confident { counts[c, default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? language
    }

    /// Japanese, Chinese or Korean: what `TranslationFilter.needsTranslation` asks of every line of such a source.
    public static func isCJK(_ code: String?) -> Bool { ["ja", "zh-Hans", "zh-Hant", "ko"].contains(code ?? "") }
}
