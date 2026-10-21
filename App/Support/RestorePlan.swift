import Foundation

/// Restore Defaults for one tab of Settings (design names-and-context §9, A1): what that tab's "Restore Defaults…" sheet lists, what MCP
/// `reset_settings` reports, and the one place that applies and undoes it. Pure over the settings and the §9 table (`SettingSpec.columns`):
/// - a **preference** that differs from its default is a change `(key, now, default)`;
/// - a **consent** or **data** key of the tab is kept: never in `changes`, never written by `apply` (consent is turned off only by hand,
///   data is deleted per item with its own confirmation).
/// A key the file does not hold (`enginePermissions`, `exportBookmark`, `engineRejections`, `hasCompletedOnboarding`) is in no tab and so in no plan.
///
/// The surface is the UI round's contract (Settings' Restore sheet) and MCP's; add to it, never change a signature.
struct RestorePlan: Equatable {
    /// One preference that differs from its default. `now` and `default` are the JSON values the file holds under `key` (`NSNull` for none).
    struct Change: Equatable {
        let key: String
        let now: NSObject
        let `default`: NSObject
    }

    let tab: SettingSpec.Tab
    /// The preferences of the tab that differ from their defaults, in the order of `SettingSpec.all`.
    let changes: [Change]
    /// The consent and data keys of the tab, in the order of `SettingSpec.all`: shown as "kept", whatever their values.
    let kept: [String]

    /// Nothing to restore: the tab is at its defaults (the button is hidden then, §9).
    var isEmpty: Bool { changes.isEmpty }

    /// The plan for `tab` over `settings`, against `defaults` (a fresh `AppSettings`: the defaults of this Mac).
    static func make(tab: SettingSpec.Tab, now settings: AppSettings, defaults: AppSettings = AppSettings()) -> RestorePlan {
        let current = SettingsFileCheck.fileValues(settings, omittingUnset: false), original = SettingsFileCheck.fileValues(defaults, omittingUnset: false)
        var changes: [Change] = [], kept: [String] = []
        for spec in SettingSpec.all where spec.tab == tab {
            switch spec.nature {
            case .preference?:
                let now = value(spec.key, in: current), standard = value(spec.key, in: original)
                if !now.isEqual(standard) { changes.append(Change(key: spec.key, now: now, default: standard)) }
            case .consent?, .data?:
                kept.append(spec.key)
            case nil:
                break
            }
        }
        return RestorePlan(tab: tab, changes: changes, kept: kept)
    }

    /// The value a settings file holds under `key`, `NSNull` when it holds none (nil optionals, `customEngineID`, `profilePin`).
    private static func value(_ key: String, in values: [String: Any]) -> NSObject {
        (values[key] as? NSObject) ?? NSNull()
    }

    /// The value of `key` in `settings` as the file holds it, for a sheet row that shows a kept key ("on — kept").
    static func value(of key: String, in settings: AppSettings) -> NSObject {
        value(key, in: SettingsFileCheck.fileValues(settings, omittingUnset: false))
    }

    // MARK: applying and undoing

    /// `settings.json.before-restore`: where the file is copied before a restore.
    static func backupURL(for file: URL) -> URL { file.appendingPathExtension("before-restore") }

    /// Restores the plan: copies `file` (settings.json) to `settings.json.before-restore`, replacing an older copy, then writes the default
    /// of each changed key into `settings` and nothing else. The copy comes first and a failed copy stops the restore: it is the way back
    /// when `undo` is not at hand. A missing file copies nothing (the settings were never saved).
    func apply(to settings: inout AppSettings, file: URL) throws {
        let backup = Self.backupURL(for: file)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: file, to: backup)
        }
        settings = Self.writing(changes.map { ($0.key, $0.default) }, to: settings)
    }

    /// Undo: writes back the `now` of each changed key and nothing else (what was changed since stays).
    func undo(_ settings: inout AppSettings) {
        settings = Self.writing(changes.map { ($0.key, $0.now) }, to: settings)
    }

    /// `settings` with `values` written under their keys (`NSNull` clears), through the JSON the file holds, the way `SettingsFileCheck.read`
    /// lays a file over the settings.
    private static func writing(_ values: [(key: String, value: NSObject)], to settings: AppSettings) -> AppSettings {
        guard var object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) as? [String: Any] else { return settings }
        for (key, value) in values { object[key] = value is NSNull ? nil : value }
        guard let data = try? JSONSerialization.data(withJSONObject: object), let written = try? JSONDecoder().decode(AppSettings.self, from: data) else { return settings }
        return written
    }
}
