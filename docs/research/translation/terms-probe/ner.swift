import NaturalLanguage
let sents = [
 "Rose draws her sword and attacks the goblin.",
 "Elena",
 "Priya Shah 10:42 AM",
 "Morning all! Yuki Tanaka posted them in the vault.",
 "Flame Tongue Sword",
 "Lord Varkus summoned the Fireball of Elara near Silverwood.",
 "Will you come with me, Rose? Hope is all we have.",
 "The rose in the garden is red.",
 "Press START to enter the Dragon's Lair.",
 "Talk to Mira in Eastgate to start the quest 'The Lost Amulet'.",
 "I kept the key all these years, hoping you would come back.",
 "Kael, Aria and Zed joined the guild Iron Wolves.",
 "ELENA: WE MUST GO NOW",
 "Elena: we must go now",
]
let t = NLTagger(tagSchemes: [.nameType])
for s in sents {
    t.string = s
    t.setLanguage(.english, range: s.startIndex..<s.endIndex)
    var out: [String] = []
    t.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace,.omitPunctuation,.joinNames]) { tag, r in
        if let tag { out.append("\(s[r])/\(tag.rawValue)") }
        return true
    }
    print(s, "=>", out.isEmpty ? "-" : out.joined(separator: " | "))
}
// non-English: does the tagger return anything?
for (l, s) in [(NLLanguage.korean, "하루카는 에이스 길드의 미라를 만났다."), (.japanese, "ハルカはミラに会った。"), (.simplifiedChinese, "艾琳在银月城遇见了米拉。")] {
    t.string = s; t.setLanguage(l, range: s.startIndex..<s.endIndex)
    var out: [String] = []
    t.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace,.omitPunctuation,.joinNames]) { tag, r in
        if let tag { out.append("\(s[r])/\(tag.rawValue)") }; return true }
    print(l.rawValue, s, "=>", out.isEmpty ? "-" : out.joined(separator: " | "))
}
