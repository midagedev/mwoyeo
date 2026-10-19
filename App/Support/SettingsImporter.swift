import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The App Store build's one-time import of the GitHub version's settings (its own bundle id has its own preferences, and the
/// DMG copy's files are never moved or deleted). The person picks `settings.json` in a panel; the read goes through
/// `SettingsFileStore.importResult`, the same checks as the app's file.
@MainActor
enum SettingsImporter {
    /// `~/Library/Application Support/Mwoyeo/settings.json` of the real home (inside the sandbox `NSHomeDirectory()` is the container).
    static var githubVersionFile: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Mwoyeo/settings.json")
    }

    /// Shows the panel; nil when the person cancels.
    static func chooseFile() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = githubVersionFile.deletingLastPathComponent()
        panel.nameFieldStringValue = githubVersionFile.lastPathComponent
        panel.message = String(localized: "Choose settings.json of the GitHub version")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Whether the import brought engines that cannot send text until the person allows them: an import never grants (`EnginePermissions`).
    static func needsAllowing(_ r: SettingsImport, in s: AppSettings) -> Bool {
        r.parsed && r.applied.contains("engines") && s.engines.contains { !s.enginePermissions.allows($0) }
    }

    /// One line for the result: what was applied, or the first problem. `askingToAllow`: the engines it brought wait for the person.
    static func summary(_ r: SettingsImport, askingToAllow: Bool = false) -> String {
        if !r.parsed { return r.issues.first.map { String(localized: "Nothing was imported: \($0.message)") } ?? String(localized: "Nothing was imported.") }
        let n = r.applied.count
        var text = n == 0 ? String(localized: "Nothing to change; these settings are already here.") : String(localized: "Imported \(n) settings.")
        if askingToAllow { text += " " + String(localized: "Allow each online engine in Settings.") }
        if let first = r.issues.first {
            let line = first.line.map { String(localized: "Line \($0): \(first.message)") } ?? first.message
            text += " " + (r.issues.count > 1 ? String(localized: "\(line) · \(r.issues.count - 1) more") : line)
        }
        return text
    }
}

/// "Import settings from the GitHub version…": a button with the result under it. API keys are Keychain items of the other app and
/// cannot be read, so the row says they stay behind.
struct ImportSettingsRow: View {
    @Environment(AppModel.self) private var model
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Import settings from the GitHub version…") {
                guard let url = SettingsImporter.chooseFile() else { return }
                let imported = model.importSettings(from: url)
                result = SettingsImporter.summary(imported, askingToAllow: SettingsImporter.needsAllowing(imported, in: model.settings))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            Text(result ?? String(localized: "API keys are not carried over; add them again."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
