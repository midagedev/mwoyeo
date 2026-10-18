import NaturalLanguage
let langs: [NLLanguage] = [.english,.korean,.japanese,.simplifiedChinese,.traditionalChinese,.french,.german,.italian,.spanish,.portuguese,.russian,.turkish,.arabic,.thai,.vietnamese,.indonesian,.dutch,.polish,.hindi]
for l in langs {
    let s = NLTagger.availableTagSchemes(for: .word, language: l).map(\.rawValue).sorted()
    print(l.rawValue, s.contains("NameType") ? "NAME" : "no-name", s.joined(separator: ","))
}
