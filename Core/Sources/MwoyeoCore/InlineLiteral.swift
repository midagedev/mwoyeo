import Foundation

/// Literal parts of a sentence of prose that the translator must carry through as written (a URL, a path, a command, a flag,
/// an identifier, a hash, a version, a config filename, a hotkey, an e-mail address), found from a table of regular
/// expressions and word lists. Offsets are in `Character`s, as `InlineMath.spans` counts them.
///
/// The knowledge is data: one table of `(reason, pattern)` rows, compiled once, plus the word lists below. A token is tried
/// only against the rows whose `Shape` it carries, so a plain prose word costs no regular expression at all.
public enum InlineLiteral {
    public enum Reason: String, CaseIterable, Sendable {
        case url, email, path, cmd, flag, id, hash, version, config, hotkey
    }

    /// The literal spans of `text`, in text order, none overlapping (the longer of two at the same start wins).
    public static func spans(in text: String) -> [(range: Range<Int>, reason: Reason)] {
        let chars = Array(text)
        let tokens = tokenize(chars)
        var hits: [Hit] = []
        for (k, token) in tokens.enumerated() {
            let shape = Shape(Array(chars[token]))
            if let row = table.first(where: { !shape.isDisjoint(with: $0.shape) && $0.matches(chars, token) }) {
                hits.append(Hit(range: token, reason: row.reason, rank: row.rank))
            }
            if let phrase = command(tokens: tokens, at: k, chars: chars) {
                hits.append(Hit(range: phrase, reason: .cmd, rank: 1_000))
            }
            if let split = splitFilename(tokens: tokens, at: k, chars: chars) {
                hits.append(Hit(range: split, reason: .path, rank: 1_001))
            }
        }
        return merge(hits)
    }

    // MARK: - The table

    private struct Row {
        let reason: Reason
        let shape: Shape
        let regex: NSRegularExpression
        let rank: Int

        func matches(_ chars: [Character], _ range: Range<Int>) -> Bool {
            let token = String(chars[range])
            return regex.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) != nil
        }
    }

    private static let extensions: Set<String> = Set(extensionList.split(separator: "|").map(String.init))

    private static let extensionList = "swift|json|jsonl|yml|yaml|toml|plist|xcconfig|ini|cfg|conf|env|md|txt|sh|bash|zsh|py|js|ts|tsx|jsx|html|css|png|jpg|jpeg|gif|pdf|log|xml|csv|tsv|lock|m|mm|h|c|cpp|rs|go|java|kt|rb|php|sql|sqlite|db|dmg|ipa|app|zip|tar|gz|woff|woff2|ttf|otf|svg|mp4|mov|wav|mp3"

    /// Rows are tried in this order, so a more specific reading wins (`settings.json` is config, not a path).
    private static let table: [Row] = {
        let rows: [(Reason, Shape, String)] = [
            (.url, [.colon], #"(?i)^(?:https?|ftp|file)://\S+$"#),
            (.url, [.dot], #"(?i)^www\.[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/[^\s]*)?$"#),
            (.url, [.dot], #"(?i)^[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.(?:com|org|net|io|dev|app|ai|co|kr|jp|cn|uk|de|fr|edu|gov|me|tv|us)(?::\d+)?(?:/[^\s]*)?$"#),
            (.url, [.colon], #"(?i)^localhost(?::\d+)?(?:/\S*)?$"#),
            (.email, [.at], #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#),
            (.hotkey, [.plus, .symbol], #"^(?:Cmd|Command|Ctrl|Control|Alt|Option|Opt|Shift|Fn|⌘|⌥|⌃|⇧)(?:\+(?:Cmd|Command|Ctrl|Control|Alt|Option|Opt|Shift|Fn|Esc|Enter|Tab|Space|Delete|F\d{1,2}|[A-Za-z0-9]|⌘|⌥|⌃|⇧)){1,5}$"#),
            (.hotkey, [.symbol], #"^[⌘⌥⌃⇧]{1,4}[A-Za-z0-9]$"#),
            (.flag, [.dash], #"^--[A-Za-z][A-Za-z0-9-]*$"#),
            (.flag, [.dash], #"^-[A-Za-z0-9]{1,3}$"#),
            (.hash, [.digit], #"(?i)^(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}$"#),
            (.version, [.digit], #"(?i)^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$"#),
            (.version, [.digit], #"(?i)^v\d+(?:\.\d+)+$"#),
            (.config, [.dot], #"(?i)^[A-Za-z0-9._-]+\.(?:json|jsonl|yml|yaml|toml|plist|xcconfig|ini|cfg|conf|env)$"#),
            (.config, [.dot], #"^\.(?:env|gitignore|gitconfig|npmrc|zshrc|bashrc|editorconfig)$"#),
            (.config, [.mixedCase], #"^(?:Makefile|Dockerfile|Package\.resolved|Podfile|Gemfile|Brewfile|Justfile)$"#),
            (.path, [.slash], #"^(?:~|\.{1,2})/[^\s]+$"#),
            (.path, [.slash], #"^/[A-Za-z0-9._~+-]+(?:/[A-Za-z0-9._~+-]+)+$"#),
            (.path, [.colon], #"^[A-Za-z]:[\\/][^\s]+$"#),
            (.path, [.slash], #"(?i)^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._~+-]+)+\.(?:"# + extensionList + ")$"),
            (.path, [.dot], #"(?i)^[A-Za-z0-9._-]+\.(?:"# + extensionList + ")$"),
            (.path, [.slash], #"^/[A-Za-z][A-Za-z0-9._~+-]*$"#),
            (.id, [.underscore], #"^[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+$"#),
            (.id, [.mixedCase], #"^[a-z][a-z0-9]*(?:[A-Z][A-Za-z0-9]*)+$"#),
            (.id, [.mixedCase], #"^[A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)+$"#),
            (.id, [.dot], #"^[A-Za-z_][A-Za-z0-9_]+(?:\.[A-Za-z_][A-Za-z0-9_]*)+$"#),
            (.id, [.paren], #"^[A-Za-z_][A-Za-z0-9_]*\([^()]*\)$"#),
            (.id, [.caps], #"^[A-Z][A-Z0-9]{2,}(?:_[A-Z0-9]+)*$"#),
        ]
        return rows.enumerated().map { rank, row in
            Row(reason: row.0, shape: row.1, regex: try! NSRegularExpression(pattern: row.2), rank: rank)
        }
    }()

    // MARK: - Word lists

    /// A command name, and whether it needs an argument to count as one: `make`, `find`, `cat`, `open` and `test` are
    /// English words too, `git`, `npm`, `xcodebuild` and `kubectl` are not.
    private static let commands: [String: Bool] = [
        "git": false, "npm": false, "npx": false, "yarn": false, "pnpm": false, "brew": false, "kubectl": false,
        "docker": false, "swift": false, "xcodebuild": false, "xcodegen": false, "swiftc": false, "python": false,
        "python3": false, "pip": false, "pip3": false, "cargo": false, "rustc": false, "curl": false, "wget": false,
        "ssh": false, "scp": false, "rsync": false, "grep": false, "egrep": false, "sed": false, "awk": false,
        "chmod": false, "chown": false, "sudo": false, "xcrun": false, "ffmpeg": false, "jq": false, "plutil": false,
        "codesign": false, "notarytool": false, "gh": false, "defaults": false, "pod": false, "carthage": false,
        "bazel": false, "gradle": false, "mvn": false, "bundle": false, "gem": false, "clang": false, "gcc": false,
        "cmake": false, "ninja": false, "unzip": false, "diskutil": false, "launchctl": false, "sysctl": false,
        "sw_vers": false, "whereis": false, "whoami": false, "uname": false, "lsof": false,
        "netstat": false, "tcpdump": false, "dig": false, "ping": false, "traceroute": false, "openssl": false,
        "sftp": false, "mysql": false, "psql": false, "redis-cli": false, "mongosh": false, "sqlite3": false,
        "make": true, "find": true, "cat": true, "head": true, "tail": true,
        "sort": true, "touch": true, "test": true, "time": true, "date": true, "watch": true, "top": true, "ps": true,
        "df": true, "du": true, "kill": true, "cd": true, "ls": true, "cp": true, "mv": true, "rm": true, "ln": true,
        "echo": true, "install": true, "export": true, "unset": true, "source": true, "alias": true,
        "clear": true, "reset": true, "run": true, "build": true, "show": true, "zip": true, "tar": true,
        "node": true, "go": true, "java": true, "ruby": true,
    ]

    /// The words that follow a command name as its verb or its option (`git log`, `swift build`, `npm install`).
    private static let subcommands: Set<String> = [
        "build", "test", "run", "status", "diff", "log", "show", "add", "commit", "push", "pull", "fetch", "checkout",
        "branch", "merge", "rebase", "clone", "init", "get", "apply", "delete", "describe", "exec", "version", "deploy",
        "publish", "update", "upgrade", "list", "rm", "cp", "mv", "mkdir", "lock", "clean", "start", "stop", "restart",
        "previews", "scheme", "destination", "archive", "export", "help", "config", "set", "unset", "serve", "dev",
        "release", "bench", "score", "check", "format", "lint", "watch", "new", "mcp", "resume", "install", "uninstall",
        "link", "unlink", "outdated", "search", "info", "inspect", "logs", "images", "container", "compose", "down", "up",
        "attach", "tag", "generate", "resolve", "dump", "feed", "regen",
    ]

    // MARK: - Tokens

    private static let edgePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "'", "“", "”", "‘", "’", "•", "·", "…", "—", "–"]

    private static func tokenize(_ chars: [Character]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            let cjk = isCJKText(chars[i])
            var j = i
            while j < chars.count, !chars[j].isWhitespace, isCJKText(chars[j]) == cjk { j += 1 }
            var a = i, b = j
            while a < b, edgePunctuation.contains(chars[a]) { a += 1 }
            while b > a, edgePunctuation.contains(chars[b - 1]) { b -= 1 }
            var opens = 0, closes = 0
            for k in a..<b {
                if "([{".contains(chars[k]) { opens += 1 }
                else if ")]}".contains(chars[k]) { closes += 1 }
            }
            while a < b, "([{".contains(chars[a]), opens > closes { a += 1; opens -= 1 }
            while b > a, ")]}".contains(chars[b - 1]), closes > opens { b -= 1; closes -= 1 }
            if a < b { out.append(a..<b) }
            i = j
        }
        return out
    }

    /// Kana, han, hangul and the punctuation block of CJK text. The composition of `TranslationFilter.isCJK` and
    /// `InlineMath`'s private test, which is the same edge rule (a CJK letter ends a Latin token).
    private static func isCJKText(_ c: Character) -> Bool {
        c.unicodeScalars.contains { TranslationFilter.isCJK($0) || (0x3000...0x303F).contains($0.value) }
    }

    private struct Shape: OptionSet {
        let rawValue: Int
        static let slash = Shape(rawValue: 1 << 0)
        static let dot = Shape(rawValue: 1 << 1)
        static let colon = Shape(rawValue: 1 << 2)
        static let at = Shape(rawValue: 1 << 3)
        static let underscore = Shape(rawValue: 1 << 4)
        static let dash = Shape(rawValue: 1 << 5)
        static let digit = Shape(rawValue: 1 << 6)
        static let plus = Shape(rawValue: 1 << 7)
        static let paren = Shape(rawValue: 1 << 8)
        static let symbol = Shape(rawValue: 1 << 9)
        static let mixedCase = Shape(rawValue: 1 << 10)
        static let caps = Shape(rawValue: 1 << 11)

        init(rawValue: Int) { self.rawValue = rawValue }

        init(_ chars: [Character]) {
            var r = 0
            var upper = false, lower = false, letter = false
            for c in chars {
                switch c {
                case "/", "\\": r |= Self.slash.rawValue
                case ".": r |= Self.dot.rawValue
                case ":": r |= Self.colon.rawValue
                case "@": r |= Self.at.rawValue
                case "_": r |= Self.underscore.rawValue
                case "-": r |= Self.dash.rawValue
                case "+": r |= Self.plus.rawValue
                case "(", ")", "[", "]", "{", "}": r |= Self.paren.rawValue
                case "⌘", "⌥", "⌃", "⇧": r |= Self.symbol.rawValue
                case "0"..."9": r |= Self.digit.rawValue
                case "A"..."Z": upper = true; letter = true
                case "a"..."z": lower = true; letter = true
                default: break
                }
            }
            if letter, upper { r |= Self.mixedCase.rawValue }
            if letter, upper, !lower { r |= Self.caps.rawValue }
            self.init(rawValue: r)
        }
    }

    /// A filename the OCR read with a space at its dot ("ReadWait. swift", "tools/ane-env. sh"): the stem carries a mark of
    /// code (a separator or a capital), the next token is a known file extension.
    private static func splitFilename(tokens: [Range<Int>], at k: Int, chars: [Character]) -> Range<Int>? {
        guard k + 1 < tokens.count else { return nil }
        let stem = tokens[k], rest = tokens[k + 1]
        guard stem.upperBound < chars.count, chars[stem.upperBound] == "." else { return nil }
        guard String(chars[stem]).contains(where: { $0 == "/" || $0 == "-" || $0 == "_" || $0.isUppercase }) else { return nil }
        guard extensions.contains(String(chars[rest]).lowercased()) else { return nil }
        return stem.lowerBound..<rest.upperBound
    }

    // MARK: - Commands

    private static func command(tokens: [Range<Int>], at k: Int, chars: [Character]) -> Range<Int>? {
        guard let needsArgument = commands[String(chars[tokens[k]]).lowercased()] else { return nil }
        var end = tokens[k].upperBound
        var arguments = 0, strong = 0
        var j = k + 1
        while j < tokens.count, argumentish(String(chars[tokens[j]])) {
            let argument = String(chars[tokens[j]])
            if strongArgumentish(argument) { strong += 1 }
            end = tokens[j].upperBound
            arguments += 1
            j += 1
        }
        if needsArgument, arguments == 0 || strong == 0 { return nil }
        return tokens[k].lowerBound..<end
    }

    /// A flag or a subcommand: the argument that makes an English word (`open`, `make`, `test`) a command.
    private static func strongArgumentish(_ token: String) -> Bool {
        Shape(Array(token)).contains(.dash) || subcommands.contains(token.lowercased())
    }

    private static func argumentish(_ token: String) -> Bool {
        let chars = Array(token)
        let shape = Shape(chars)
        if !shape.isDisjoint(with: [.dash, .at, .colon, .slash, .dot]) { return true }
        if subcommands.contains(token.lowercased()) { return true }
        if shape.contains(.digit), token.allSatisfy({ $0.isNumber || ".:-".contains($0) }) { return true }
        return false
    }

    // MARK: - Ordering

    private struct Hit {
        let range: Range<Int>
        let reason: Reason
        let rank: Int
    }

    private static func merge(_ hits: [Hit]) -> [(range: Range<Int>, reason: Reason)] {
        let sorted = hits.sorted { a, b in
            if a.range.lowerBound != b.range.lowerBound { return a.range.lowerBound < b.range.lowerBound }
            if a.range.count != b.range.count { return a.range.count > b.range.count }
            return a.rank < b.rank
        }
        var out: [(range: Range<Int>, reason: Reason)] = []
        var end = 0
        for hit in sorted where hit.range.lowerBound >= end {
            out.append((hit.range, hit.reason))
            end = hit.range.upperBound
        }
        return out
    }
}
