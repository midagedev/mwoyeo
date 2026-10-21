import Foundation
import MwoyeoCore

// `bench-run run --apply hint|both|both-names` (round both-bench, 2026-10-21): how the user memory's rows are applied (design
// names-and-context §10). A row is a hint (it goes to the engine as a row), a replacement (its target is written into the SOURCE
// line before translation) or both. The product writes into the line being translated only: the context lines stay as the screen
// showed them. Matching and insertion are Core's (`ContextMemory.replaceRows`, `ApplePreinsertion`); nothing is matched here.

public enum ApplyMode: String, Sendable, CaseIterable {
    /// Every row is a hint: today's request, byte for byte.
    case hint
    /// Every row, entities and terms, is `.both`.
    case both
    /// Entities (people, places) are `.both`; terms stay hints. `both` and `both-names` differ only by the term rows.
    case bothNames = "both-names"

    public var entityApply: EntryApply { self == .hint ? .hint : .both }
    public var termApply: EntryApply { self == .both ? .both : .hint }
    /// Whether any row of this mode is written into a source line.
    public var rewrites: Bool { self != .hint }
}

/// One item line as the engine saw it after the rows were written into it, with the places it was written (`[matched, target]`).
public struct ItemRewrite: Codable, Sendable, Equatable {
    public var id: Int
    public var text: String
    public var spans: [[String]]
}

public enum SourceRewrite {
    /// The item lines that change: for each, `ApplePreinsertion.insert` over the rows `ContextMemory.replaceRows` keeps (user rows
    /// whose `apply` is not `.hint`). An item the rows do not touch is not listed. Order of the items.
    public static func rewrites(items: [BenchLine], rows: [MemoryEntry]) -> [ItemRewrite] {
        let replace = ContextMemory.replaceRows(rows: rows, glossary: [], glossaryApply: .hint)
        guard !replace.isEmpty else { return [] }
        return items.compactMap { item in
            let p = ApplePreinsertion.insert(into: item.text, entries: replace)
            return p.isEmpty ? nil : ItemRewrite(id: item.id, text: p.text, spans: p.spans.map { [$0.matched, $0.target] })
        }
    }

    /// A finished request body with the `translate` texts of its last user message replaced by `items` (the rows were selected on the
    /// original lines: `RequestLayout.selectRows` matches a row's source against the items, and a written target no longer holds it, so
    /// the hint of a replaced name would be dropped if the lines were rewritten first). Re-encoded the way Core encodes it (sorted keys,
    /// no escaped slashes); `items` equal to the original texts give back the same bytes. nil when the body is not a chat or Messages body
    /// whose last user message is Core's `{"translate": [{"id", "text"}], ...}`.
    public static func substituting(items: [String], intoBody body: Data) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var messages = root["messages"] as? [[String: Any]],
              let at = messages.lastIndex(where: { $0["role"] as? String == "user" }),
              let content = messages[at]["content"] as? String,
              var user = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
              let translate = user["translate"] as? [[String: Any]], translate.count == items.count
        else { return nil }
        user["translate"] = zip(translate, items).map { entry, text -> [String: Any] in
            var e = entry
            e["text"] = text
            return e
        }
        messages[at]["content"] = String(decoding: Wiring.encode(user), as: UTF8.self)
        root["messages"] = messages
        return Wiring.encode(root)
    }
}
