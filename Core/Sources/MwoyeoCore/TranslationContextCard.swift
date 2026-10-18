import Foundation

// The document card (design §2, §8.4, §8.5): app name, a short domain word from the app's category, and the
// normalised window title. The title is the part that needs care: it must stay the same while the document stays
// the same (a cached prefix and a thread key depend on it), and it must not carry anything private.

/// `LSApplicationCategoryType` → a short domain word (research-memory §9.3).
public enum CategoryDomain {
    /// The suffix of `public.app-category.<suffix>` → the word we send. About 25 entries; `*-games` all map to "games".
    public static let words: [String: String] = [
        "business": "business", "developer-tools": "dev", "education": "education", "entertainment": "entertainment",
        "finance": "finance", "graphics-design": "design", "healthcare-fitness": "health", "lifestyle": "lifestyle",
        "medical": "medical", "music": "music", "news": "news", "photography": "photo", "productivity": "productivity",
        "reference": "reference", "social-networking": "social", "sports": "sports", "travel": "travel",
        "utilities": "utilities", "video": "video", "weather": "weather", "books": "books", "food-drink": "food",
        "magazines-newspapers": "news", "navigation": "maps", "shopping": "shopping", "games": "games",
    ]

    /// The domain word for a category type string, or nil for none or an unknown one.
    public static func word(for category: String?) -> String? {
        guard var c = category?.lowercased().trimmingCharacters(in: .whitespaces), !c.isEmpty else { return nil }
        let prefix = "public.app-category."
        if c.hasPrefix(prefix) { c.removeFirst(prefix.count) }
        if c.hasSuffix("-games") { return "games" }
        return words[c]
    }
}

/// Window-title clean-up. One pure function; the table of examples is in the tests.
public enum TitleNormalizer {
    /// Latin 60, CJK 40 (a CJK character counts 1.5 of 60).
    public static let maxUnits = 60.0

    static let separators = [" — ", " – ", " ― ", " - ", " | ", " · ", " • "]

    static let knownExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "pages", "numbers", "key", "epub", "csv",
        "swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "toml", "xml", "html", "css", "c", "h", "m", "mm",
        "cpp", "hpp", "java", "kt", "rs", "go", "rb", "php", "sh", "zsh", "sql", "ipynb", "log", "tex", "plist",
        "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "psd", "mov", "mp4", "mkv", "mp3", "m4a", "wav", "flac",
        "zip", "dmg", "app",
    ]

    /// The window title as it goes in the card, or "" when nothing is left. In order:
    /// 1. control characters, newlines and runs of spaces cleaned; e-mail addresses and URL queries removed (done first
    ///    so that the cut below cannot leave half an address);
    /// 2. the app's name stripped from the end and the start;
    /// 3. unread, page and FPS counters, loading marks and edit marks stripped;
    /// 4. a path cut to its last component, a known file extension removed;
    /// 5. spaces collapsed; cut at the end with "…" (CJK 40, Latin 60);
    /// 6. "" when what is left is the app's name; e-mails and queries removed once more.
    public static func normalize(_ raw: String, appName: String) -> String {
        // Privacy first, per segment: a segment that is only an address disappears with its separator.
        var segments = split(ContextText.collapse(raw)).compactMap { seg -> Segment? in
            let text = removePrivate(seg.text)
            return text.isEmpty ? nil : Segment(text: text, sepAfter: seg.sepAfter)
        }

        // 2. the app name at the ends
        while segments.count > 1, matchesApp(segments[segments.count - 1].text, appName) { segments.removeLast() }
        while segments.count > 1, matchesApp(segments[0].text, appName) { segments.removeFirst() }

        // 3 and 4, segment by segment
        segments = segments.compactMap { seg in
            var text = seg.text
            for _ in 0..<4 {
                let before = text
                text = stripCounters(text)
                if text == before { break }
            }
            if isDroppedSegment(text) { return nil }
            text = basename(text)
            text = ContextText.collapse(text)
            return text.isEmpty ? nil : Segment(text: text, sepAfter: seg.sepAfter)
        }
        var title = join(segments)

        // 5.
        title = cut(ContextText.collapse(title))

        // 6.
        if ContextText.foldedKey(title) == ContextText.foldedKey(appName) { return "" }
        return removePrivate(title)
    }

    // MARK: pieces

    struct Segment {
        var text: String
        var sepAfter: String?
    }

    static func split(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var current = ""
        var i = s.startIndex
        while i < s.endIndex {
            if let sep = separators.first(where: { s[i...].hasPrefix($0) }) {
                out.append(Segment(text: current, sepAfter: sep))
                current = ""
                i = s.index(i, offsetBy: sep.count)
            } else {
                current.append(s[i])
                i = s.index(after: i)
            }
        }
        out.append(Segment(text: current, sepAfter: nil))
        return out.filter { !ContextText.collapse($0.text).isEmpty }.map { Segment(text: ContextText.collapse($0.text), sepAfter: $0.sepAfter) }
    }

    static func join(_ segments: [Segment]) -> String {
        var out = ""
        for (i, seg) in segments.enumerated() {
            out += seg.text
            if i < segments.count - 1 { out += seg.sepAfter ?? " - " }
        }
        return out
    }

    /// The segment is the app's name, or the app's name with one word of vendor in front ("Google Chrome" for "Chrome")
    /// or behind it ("Chrome" for "Google Chrome").
    static func matchesApp(_ segment: String, _ app: String) -> Bool {
        let s = ContextText.foldedKey(segment), a = ContextText.foldedKey(app)
        guard !s.isEmpty, !a.isEmpty else { return false }
        if s == a { return true }
        let sWords = s.split(separator: " "), aWords = a.split(separator: " ")
        if s.hasSuffix(" " + a), sWords.count == aWords.count + 1 { return true }
        if a.hasSuffix(" " + s) { return true }
        return false
    }

    static func stripCounters(_ text: String) -> String {
        var s = text
        s = s.replacing(/^(?:\(\d+\+?\)|\[\d+\+?\])\s*/, with: "")
        s = s.replacing(/^[•●*]\s+/, with: "")
        s = s.replacing(/\s*(?:\(\d+\+?\)|\[\d+\+?\])$/, with: "")
        s = s.replacing(/\s*\(\d+\+?\s*(?:unread|new)(?:\s+(?:messages?|items?))?\)$/.ignoresCase(), with: "")
        s = s.replacing(/\s*\(?\bpage\s+\d+\s*(?:of|\/)\s*\d+\)?$/.ignoresCase(), with: "")
        s = s.replacing(/\s*[\[(](?:edited|modified|unsaved|편집됨|수정됨|編集済み)[\])]$/.ignoresCase(), with: "")
        s = s.replacing(/\s+[*•●]$/, with: "")
        s = s.replacing(/\s*(?:…|\.\.\.)$/, with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A whole segment that is only a counter or an edit mark.
    static func isDroppedSegment(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        let patterns: [Regex<Substring>] = [
            /\d+\+?\s*(?:new\s+)?(?:items?|messages?|unread(?:\s+messages?)?|notifications?|updates?|mentions?)/.ignoresCase(),
            /\d+(?:\.\d+)?\s*fps/.ignoresCase(),
            /page\s+\d+(?:\s*(?:of|\/)\s*\d+)?/.ignoresCase(),
            /(?:edited|modified|unsaved|locked|saved|편집됨|수정됨|編集済み|変更済み)/.ignoresCase(),
            /읽지 않은 메시지 \d+개/,
            /\d+개의 새 (?:메시지|알림)/,
        ]
        return patterns.contains { t.wholeMatch(of: $0) != nil }
    }

    static func basename(_ segment: String) -> String {
        var s = segment
        if s.hasPrefix("/") || s.hasPrefix("~/") {
            if let last = s.split(separator: "/").last { s = String(last) }
        }
        if let dot = s.lastIndex(of: "."), dot != s.startIndex, s.index(after: dot) != s.endIndex,
           knownExtensions.contains(s[s.index(after: dot)...].lowercased()) {
            s = String(s[..<dot])
        }
        return s
    }

    static func cut(_ s: String) -> String {
        var units = 0.0
        var out = ""
        for ch in s {
            let u = ContextText.isCJK(ch) ? 1.5 : 1.0
            if units + u > maxUnits {
                return out.trimmingCharacters(in: .whitespaces) + "…"
            }
            units += u
            out.append(ch)
        }
        return out
    }

    /// E-mail addresses and the user-info, query and fragment of URLs. Nothing else about a URL is touched.
    static func removePrivate(_ s: String) -> String {
        var t = s
        t = t.replacing(/:\/\/[^\/@\s]+@/, with: "://")
        t = t.replacing(/[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}/, with: "")
        t = t.replacing(/(\S*?(?::\/\/|\/)\S*?)[?#]\S*/, with: { $0.1 })
        return ContextText.collapse(t)
    }
}

/// Title hysteresis (design §8.4): the confirmed title changes only after the same new title was read 3 times,
/// spanning at least 1 s. A read that equals the confirmed title cancels the pending change; a different new title
/// restarts it. The first title read is adopted at once (there is nothing yet to be stable against).
/// One value per app; `time` is any monotonic clock in seconds.
public struct TitleConfirmer: Equatable, Sendable {
    public let reads: Int
    public let span: TimeInterval
    public private(set) var confirmed: String?
    private var candidate: String?
    private var candidateReads = 0
    private var candidateSince: TimeInterval = 0

    public init(reads: Int = 3, span: TimeInterval = 1.0) {
        self.reads = reads
        self.span = span
    }

    /// Feeds one read of the normalised title (`nil` = no window info this time: ignored). Returns the confirmed title.
    @discardableResult
    public mutating func observe(_ title: String?, at time: TimeInterval) -> String? {
        guard let title else { return confirmed }
        guard let current = confirmed else {
            confirmed = title
            return confirmed
        }
        if title == current {
            candidate = nil
            candidateReads = 0
            return confirmed
        }
        if candidate == title {
            candidateReads += 1
        } else {
            candidate = title
            candidateReads = 1
            candidateSince = time
        }
        if candidateReads >= reads, time - candidateSince >= span {
            confirmed = title
            candidate = nil
            candidateReads = 0
        }
        return confirmed
    }
}

/// What may leave the Mac (design §2, §8.5).
public enum ContextPrivacy {
    /// The window title goes only to an on-device engine, or to any engine when the user opted in.
    /// The app name and the category are not title data: they are always sent.
    public static func includesTitle(onDevice: Bool, optedIn: Bool) -> Bool { onDevice || optedIn }
}

public struct DocumentCard: Equatable, Sendable {
    public var appName: String
    /// The short domain word ("social", "dev", "games"), or nil.
    public var domain: String?
    /// The normalised window title, or "" for none.
    public var title: String

    public init(appName: String, domain: String? = nil, title: String = "") {
        self.appName = ContextText.collapse(appName)
        self.domain = domain
        self.title = title
    }

    /// Builds the card from what the OS gives: the app's name, its `LSApplicationCategoryType` and the raw window title.
    public static func make(appName: String, categoryType: String?, windowTitle: String?) -> DocumentCard {
        DocumentCard(appName: appName, domain: CategoryDomain.word(for: categoryType),
                     title: windowTitle.map { TitleNormalizer.normalize($0, appName: appName) } ?? "")
    }

    /// `Document: Messages (social), window "Alice".` within `maxTokens` (by `approxTokens`): the title is cut first,
    /// then dropped, then the app name is cut. Without `includeTitle` the window part is left out.
    public func rendered(includeTitle: Bool, maxTokens: Int) -> String {
        let head = "Document: " + appName + (domain.map { " (\($0))" } ?? "")
        var title = includeTitle ? self.title.replacingOccurrences(of: "\"", with: "'") : ""
        if !title.isEmpty {
            let overhead = approxTokens(head + ", window \"\"" + ".")
            let room = maxTokens - overhead
            if room >= 3 { title = ContextText.truncated(title, toTokens: room) } else { title = "" }
        }
        let text = head + (title.isEmpty ? "" : ", window \"\(title)\"") + "."
        return approxTokens(text) <= maxTokens ? text : ContextText.truncated(text, toTokens: maxTokens)
    }
}
