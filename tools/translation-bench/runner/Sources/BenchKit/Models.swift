import Foundation

public struct BenchLine: Codable, Sendable, Equatable {
    public var id: Int
    public var speaker: String?
    public var to: String?
    public var text: String
    public var ref: String
    public var noise: String?

    public init(id: Int, speaker: String? = nil, to: String? = nil, text: String, ref: String = "", noise: String? = nil) {
        self.id = id
        self.speaker = speaker
        self.to = to
        self.text = text
        self.ref = ref
        self.noise = noise
    }
}

/// One sequence file. Probes stay with the scorer; the runner needs only the lines and the screens.
public struct BenchSequence: Codable, Sendable {
    public var id: String
    public var kind: String
    public var source: String
    public var target: String
    public var speakerVisible: Bool
    public var lines: [BenchLine]
    public var screens: [[Int]]

    enum CodingKeys: String, CodingKey { case id, kind, source, target, lines, screens, speakerVisible = "speaker_visible" }

    public init(id: String, kind: String, source: String, target: String, speakerVisible: Bool = true,
                lines: [BenchLine], screens: [[Int]]) {
        self.id = id
        self.kind = kind
        self.source = source
        self.target = target
        self.speakerVisible = speakerVisible
        self.lines = lines
        self.screens = screens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        source = try c.decode(String.self, forKey: .source)
        target = try c.decode(String.self, forKey: .target)
        speakerVisible = try c.decodeIfPresent(Bool.self, forKey: .speakerVisible) ?? true
        lines = try c.decode([BenchLine].self, forKey: .lines)
        screens = try c.decode([[Int]].self, forKey: .screens)
    }
}

public struct MemoryEntity: Codable, Sendable, Equatable {
    public var name: String
    public var reading: String?
    public var dst: String?
    public var gender: String?
    public var role: String?
    public var speaksTo: [String: String]?
    enum CodingKeys: String, CodingKey { case name, reading, dst, gender, role, speaksTo = "speaks_to" }
}

public struct MemoryDocument: Codable, Sendable, Equatable {
    public var title: String?
    public var domain: String?
    public var summary: String?
}

public struct MemoryWindow: Codable, Sendable, Equatable {
    public var title: String?
    public var app: String?
    public var category: String?
}

public struct MemoryTerm: Codable, Sendable, Equatable {
    public var src: String
    public var dst: String
}

/// The user memory of a sequence (`memory/<id>.json`).
public struct Memory: Codable, Sendable, Equatable {
    public var entities: [MemoryEntity]
    public var document: MemoryDocument?
    public var window: MemoryWindow?
    public var terms: [MemoryTerm]

    public static let empty = Memory(entities: [], document: nil, window: nil, terms: [])

    public init(entities: [MemoryEntity] = [], document: MemoryDocument? = nil, window: MemoryWindow? = nil, terms: [MemoryTerm] = []) {
        self.entities = entities
        self.document = document
        self.window = window
        self.terms = terms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entities = try c.decodeIfPresent([MemoryEntity].self, forKey: .entities) ?? []
        document = try c.decodeIfPresent(MemoryDocument.self, forKey: .document)
        window = try c.decodeIfPresent(MemoryWindow.self, forKey: .window)
        terms = try c.decodeIfPresent([MemoryTerm].self, forKey: .terms) ?? []
    }

    public enum Section: String, Sendable, CaseIterable { case window, document, entities, terms }

    /// The notes block of a prompt; `score.render_memory` renders the same text (tests/check_render.py compares them).
    /// One line per part, empty parts left out. Entities are `name (reading) = dst`, gender, role, `speaks to A: level,
    /// B: level` (addressees in code point order, left out when `speech` is false), joined by "; ".
    public func render(sections: Set<Section> = Set(Section.allCases), speech: Bool = true) -> String {
        var lines: [String] = []
        if sections.contains(.window), let w = window {
            let parts = [w.title, w.app.map { "app: " + $0 }, w.category.map { "category: " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { lines.append("Window: " + parts.joined(separator: " | ")) }
        }
        if sections.contains(.document), let d = document {
            let parts = [d.title, d.domain, d.summary].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { lines.append("Document: " + parts.joined(separator: "; ")) }
        }
        if sections.contains(.entities), !entities.isEmpty {
            lines.append("People:")
            for e in entities {
                var name = e.name
                if let r = e.reading, !r.isEmpty { name += " (\(r))" }
                if let d = e.dst, !d.isEmpty { name += " = \(d)" }
                var parts = [name, e.gender ?? "", e.role ?? ""]
                if speech, let s = e.speaksTo, !s.isEmpty {
                    let pairs = s.sorted { Array($0.key.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.key.unicodeScalars.map(\.value)) }
                    parts.append("speaks to " + pairs.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
                }
                lines.append("- " + parts.filter { !$0.isEmpty }.joined(separator: "; "))
            }
        }
        if sections.contains(.terms), !terms.isEmpty {
            lines.append("Terms: " + terms.map { "\($0.src) = \($0.dst)" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

/// Language codes the bench files use mapped to the codes the app passes to the engines.
public func coreLanguage(_ code: String) -> String { code == "zh" ? "zh-Hans" : code }

public enum Corpus {
    public static func loadSequence(_ url: URL) throws -> BenchSequence {
        try JSONDecoder().decode(BenchSequence.self, from: Data(contentsOf: url))
    }

    public static func loadMemory(_ url: URL) throws -> Memory {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(Memory.self, from: Data(contentsOf: url))
    }

    /// Every `sequences/*.json` of the bench directory with its memory (`<memoryDir>/<id>.json`, `memory` by default), sorted by id;
    /// `only` keeps the named ones.
    public static func load(root: URL, only: Set<String>? = nil, memoryDir: String = "memory") throws -> [(BenchSequence, Memory)] {
        let dir = root.appendingPathComponent("sequences")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [(BenchSequence, Memory)] = []
        for f in files {
            let seq = try loadSequence(f)
            if let only, !only.contains(seq.id) { continue }
            out.append((seq, try loadMemory(root.appendingPathComponent("\(memoryDir)/\(seq.id).json"))))
        }
        return out
    }
}
