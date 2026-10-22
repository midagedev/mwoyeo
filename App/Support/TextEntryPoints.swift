import AppIntents
import AppKit
import MwoyeoCore

/// The ways into Translate Text from outside the app (docs/design/text-translation.md §3): the Services menu of every app, and the Shortcuts
/// action (which Spotlight lists too). The window and the menu rows are `TextTranslationWindow`'s.

/// "Translate with Mwoyeo" in the Services menu. The `NSServices` entry is in Info.plist (project.yml); AppKit calls `translateSelection` on
/// `NSApp.servicesProvider` with a pasteboard holding the selection. The service answers nothing: it opens the window and translates there.
final class ServicesProvider: NSObject {
    static let shared = ServicesProvider()

    /// The `NSMessage` of the Info.plist entry.
    static let message = "translateSelection"

    @objc func translateSelection(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let text = pasteboard.string(forType: .string) ?? ""
        Task { @MainActor in TextTranslationWindow.shared.show(text: text, translating: true) }
    }

    /// Registers the provider; the system lists a service once an app that declares it has run.
    @MainActor static func register() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }
}

/// "Translate Text" in Shortcuts: text in, the translation out, in the settings file's own pair and engine (no app is in front of a
/// shortcut, so no profile but All apps), or into the language the shortcut names.
struct TranslateTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate Text"
    static let description = IntentDescription("Translates text with the languages and the engine you set in Mwoyeo.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Translate To", description: "A language name or code, such as Korean or ko. Empty uses the target language in Mwoyeo.",
               optionsProvider: TargetLanguageOptions())
    var target: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Translate \(\.$text)") { \.$target }
    }

    /// Why a shortcut got no translation, in words the Shortcuts app shows.
    struct Failure: Error, LocalizedError {
        var errorDescription: String?
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await Self.translate(text, into: target))
    }

    /// The path of `perform`, without the intent around it (the checks run it).
    @MainActor
    static func translate(_ text: String, into target: String?, with translator: TextTranslator = .shared) async throws -> String {
        var request = TextTranslation.Request()
        if let target, !target.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let code = Languages.code(for: target) else {
                throw Failure(errorDescription: String(localized: "Mwoyeo doesn’t know the language “\(target)”."))
            }
            request.target = code
        }
        let result: TextTranslator.Result
        do { result = try await translator.translate(text, request) } catch TextTranslator.Failure.tooLong(let count) {
            throw Failure(errorDescription: String(localized: "The text is too long: \(count) characters. Up to \(TextParagraphs.maxCharacters) at a time."))
        }
        guard result.translated else {
            throw Failure(errorDescription: result.issue?.message ?? String(localized: "No engine answered."))
        }
        return result.text
    }
}

/// The names of the languages a shortcut can translate into, as Mwoyeo shows them.
struct TargetLanguageOptions: DynamicOptionsProvider {
    func results() async throws -> [String] { Languages.targets.map(Languages.name) }
}

/// What Spotlight and the Shortcuts app list without the person adding anything.
struct MwoyeoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TranslateTextIntent(), phrases: ["Translate text with \(.applicationName)"],
                    shortTitle: "Translate Text", systemImageName: "character.bubble")
    }
}
