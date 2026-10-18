import Foundation
import Translation
// usage: tr <in.json: [string]> <out.json> [hf]
let args = CommandLine.arguments
let items = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let hf = args.count > 3
let src = Locale.Language(identifier: "en"), dst = Locale.Language(identifier: "ko")
let session = TranslationSession(installedSource: src, target: dst, preferredStrategy: hf ? .highFidelity : .lowLatency)
var out = [String](repeating: "", count: items.count)
let reqs = items.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
do {
  for try await r in session.translate(batch: reqs) {
    if let id = r.clientIdentifier, let i = Int(id) { out[i] = r.targetText }
  }
} catch { FileHandle.standardError.write(Data("ERR \(error)\n".utf8)) }
try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: args[2]))
