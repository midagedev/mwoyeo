#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple Foundation Models, as `IntelligenceTranslator` in the app uses it: one session per line (a fresh 4k window),
/// greedy sampling, up to three lines at a time, the same instructions and the same "Translate into X:" ask. A CLI can
/// use the model (no app bundle needed) when Apple Intelligence is on. It takes no JSON, so a layout's context lines,
/// the speaker and the notes go in as plain text. Token usage is not reported by the API: `Usage` carries the estimate.
public struct AppleFMEngine: BenchEngine {
    public var name: String
    public var label: String { name }
    public var model: String { "apple-foundation-model" }
    public var kindName: String { "appleFoundationModels" }
    public var price: String? { nil }

    public func preflight() -> String? {
        let m = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        if case let .unavailable(reason) = m.availability { return "Apple Intelligence is unavailable: \(reason)" }
        return nil
    }

    static func instructions(source: String, target: String, additions: String) -> String {
        let en = Locale(identifier: "en")
        let targetName = en.localizedString(forIdentifier: coreLanguage(target)) ?? target
        let sourceName = en.localizedString(forIdentifier: coreLanguage(source)) ?? "the source language"
        var s = """
        You translate text captured from a computer screen — apps, games, web pages, comics, video subtitles — \
        from \(sourceName) into natural, fluent \(targetName).
        Rules:
        - Reply with the translation only: no quotes, labels, explanations, romanization or notes.
        - Keep it about as short as the original; it replaces UI labels and captions in place. Match the original's register.
        - Keep numbers, units, names, product names, keyboard shortcuts and placeholders like %@ or {0} unchanged.
        """
        if !additions.isEmpty { s += "\n" + additions }
        return s
    }

    /// The app's `clean`: wrapping quotes and a second line the model sometimes adds.
    static func clean(_ s: String, source: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("「", "」"), ("“", "”")] where t.hasPrefix(open) && t.hasSuffix(close) && t.count > 2
            && !(source.hasPrefix(open) && source.hasSuffix(close)) {
            t = String(t.dropFirst().dropLast())
        }
        if !source.contains("\n") { t = t.components(separatedBy: .newlines).first ?? t }
        return t
    }

    public func translate(_ r: EngineRequest) async -> EngineReply {
        let en = Locale(identifier: "en")
        let targetName = en.localizedString(forIdentifier: coreLanguage(r.target)) ?? r.target
        // A layout's system addition names the JSON fields (context, speakers); here they are plain text instead.
        var additions: [String] = []
        if !r.prompt.memoryText.isEmpty {
            additions.append(ReferenceLayout.notesHeader + "\n" + r.prompt.memoryText)
            if r.target == "ko", r.prompt.memoryText.contains("speaks to") { additions.append(ReferenceLayout.speechLegend) }
        }
        let instructions = Self.instructions(source: r.source, target: r.target, additions: additions.joined(separator: "\n"))
        let context = r.prompt.contextLines.isEmpty ? "" : "Earlier lines of the same text, for reference only (do not translate or repeat them):\n"
            + r.prompt.contextLines.joined(separator: "\n") + "\n\n"
        let ask = "Translate into \(targetName):\n"
        let prompts: [String] = r.items.enumerated().map { i, item in
            let who = i < r.prompt.itemSpeakers.count ? r.prompt.itemSpeakers[i] : nil
            return context + (who.map { "\($0) says:\n" } ?? "") + ask + item.text
        }
        let wire = Wire(system: instructions, user: prompts.joined(separator: "\n---\n"))

        let clock = ContinuousClock()
        let start = clock.now
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        var outputs = [String?](repeating: nil, count: r.items.count)
        var firstError: String?
        await withTaskGroup(of: (Int, String?, String?).self) { group in
            for (i, item) in r.items.enumerated() {
                group.addTask {
                    do {
                        let session = LanguageModelSession(model: model, instructions: instructions)
                        let reply = try await session.respond(to: prompts[i], options: GenerationOptions(samplingMode: .greedy))
                        return (i, Self.clean(reply.content, source: item.text), nil)
                    } catch {
                        return (i, nil, "\(error)")
                    }
                }
            }
            for await (i, text, err) in group {
                outputs[i] = text
                if let err, firstError == nil { firstError = err }
            }
        }
        let ms = Int((clock.now - start) / .milliseconds(1))
        let ok = outputs.allSatisfy { $0 != nil }
        let translations = outputs.map { $0 ?? "" }
        let usage = Usage(input: Int(Tokens.estimate(wire.system + wire.user).rounded()),
                          output: Int(Tokens.estimate(translations.joined()).rounded()), estimated: true)
        return EngineReply(translations: ok ? translations : nil, text: translations.joined(separator: "\n"), usage: usage,
                           latencyMs: ms, retries: 0, error: ok ? nil : firstError, wire: wire)
    }
}
#endif
