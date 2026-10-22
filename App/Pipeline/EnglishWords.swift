import AppKit
import Foundation
import os

/// The system's English dictionary, asked one thing: is this string a word (`LineJoin.Hyphens.word`: "nothing" is, "sequencealigned" is
/// not). The spell checker is local and sandbox-safe; the language is named, not the user's, so the answer is the same on every Mac that has
/// the dictionary, and a Mac that has none says no to everything (no hyphen is dropped, as before). A word of another language is no
/// English word, so its hyphen stays too. The checker is asked one caller at a time: it is the app's one shared instance.
enum EnglishWords {
    private struct Memory {
        var known: [String: Bool] = [:]
        var available: Bool?
    }
    private static let memory = OSAllocatedUnfairLock(initialState: Memory())

    /// A pass asks the same few words again and again; the memory is cleared when it holds this many.
    private static let capacity = 4096

    static func contains(_ word: String) -> Bool {
        memory.withLock { state in
            if let known = state.known[word] { return known }
            let checker = NSSpellChecker.shared
            let available = state.available ?? checker.availableLanguages.contains("en")
            state.available = available
            let found = available && checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0,
                                                           wordCount: nil).location == NSNotFound
            if state.known.count >= capacity { state.known.removeAll() }
            state.known[word] = found
            return found
        }
    }
}
