import Foundation
import AppKit
func hangul(_ s: String) -> String {
    let lat = s.applyingTransform(.toLatin, reverse: false) ?? s
    let plain = lat.applyingTransform(.stripDiacritics, reverse: false) ?? lat
    let nospace = plain.replacingOccurrences(of: " ", with: "")
    return (nospace.applyingTransform(.latinToHangul, reverse: false) ?? nospace)
}
for s in ["ハルカ","ミラ","エレナ","シンジ","ユキ","カイル","ヴァルカス","ガルヴァス","サクラ","タナカ","艾琳","米拉","银月城","Haruka","Rose","Varkus","Elena","Kael"] {
    let lat = s.applyingTransform(.toLatin, reverse: false) ?? s
    print(s, "->", lat, "->", hangul(s))
}
let sc = NSSpellChecker.shared
for w in ["Varkus","Elara","Rose","rose","Silverwood","Kael","Zed","Mira","goblin","Eastgate"] {
    let r = sc.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    print(w, r.location == NSNotFound ? "known" : "UNKNOWN")
}
