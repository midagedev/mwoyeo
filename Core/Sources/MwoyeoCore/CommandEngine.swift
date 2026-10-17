import Foundation

public struct CommandSpec: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
    }
}

/// The protocol for a user's own program, which the app runs with `Process`.
///
/// For each batch the app starts nothing new: it writes one JSON line to the program's stdin,
///
///     {"source": "ja", "target": "ko", "lines": ["…", "…"]}
///
/// (`source` is `null` when unknown) and reads stdout until the program exits. The program answers with one JSON line,
///
///     {"translations": ["…", "…"]}      one string per input line, in order
///     {"error": "what went wrong"}      shown to the user as is
///
/// Anything else the program prints before that (log lines, warnings) is ignored: the last stdout line that parses as
/// a JSON object wins. stderr is not part of the protocol.
public enum CommandEngine {
    public static func encodeRequest(lines: [String], source: String?, target: String) -> Data {
        let obj: [String: Any] = ["source": source.map { $0 as Any } ?? NSNull(), "target": target, "lines": lines]
        var data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decodeResponse(_ stdout: Data, count: Int) throws(ChatTranslationError) -> [String] {
        let text = String(decoding: stdout, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let e = obj["error"] as? String { throw .server(e) }
            guard let list = obj["translations"] as? [String] else { throw .malformed("translations is not an array of strings") }
            guard list.count == count else { throw .countMismatch(expected: count, got: list.count) }
            return list
        }
        throw .malformed("no JSON line on stdout")
    }
}
