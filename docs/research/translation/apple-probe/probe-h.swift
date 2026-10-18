import Foundation
import Translation
let s = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ko"), preferredStrategy: CommandLine.arguments[1] == "hf" ? .highFidelity : .lowLatency)
for t in ["We use trans-lation models to eval-uate the quality of the output.","The atten-tion mechanism allows the net-work to focus on rele-vant tokens.","Pre-trained models are widely used.","We use translation models to evaluate the quality of the output."] {
  print(((try? await s.translate(t))?.targetText ?? "ERR"))
}
