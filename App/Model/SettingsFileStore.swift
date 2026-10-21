import Foundation
import os

/// What the one-time import changed: the keys applied and the issues the file had.
struct SettingsImport: Equatable {
    var applied: [String]
    var issues: [SettingsFileIssue]
    var parsed: Bool
}

/// settings.json in Application Support (the container's, inside the sandbox: the same code), the source of truth of the
/// settings. The app writes it on every change, watches it, and applies what a person or an agent saves in it.
/// `MWOYEO_SETTINGS_FILE=<path>` names another file (captures and tests must, never the real one). The App Store build has no
/// such switch: the captures and the self-test it serves are not in it.
@MainActor
final class SettingsFileStore {
    let url: URL
    private(set) var issues: [SettingsFileIssue] = []
    /// The bytes last written by the app or last read from the file; an event that finds the same bytes is our own echo.
    private var lastSeen: Data?
    /// The file on disk has problems a person typed: the next save copies it to settings.json.broken first. Only a read
    /// of the file sets it (the "was replaced" notice in `issues` must not copy the repaired file over the typed one).
    private var needsBackup = false
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "settings")

    nonisolated static var defaultURL: URL {
        #if !MAS
        if let path = ProcessInfo.processInfo.environment["MWOYEO_SETTINGS_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Mwoyeo/settings.json")
    }

    private var brokenURL: URL { url.appendingPathExtension("broken") }
    /// Where the file of Mwoyeo 1.1.4 is kept before the first save in the new shape (design §5.2).
    static let oldShapeName = "settings-1.1.4.json"
    private var oldShapeURL: URL { url.deletingLastPathComponent().appendingPathComponent(Self.oldShapeName) }
    private var schemaURL: URL { url.deletingLastPathComponent().appendingPathComponent(SettingsFileFormat.schemaName) }

    init(url: URL = SettingsFileStore.defaultURL) { self.url = url }

    // MARK: launch

    /// The settings at launch: the file over `fallback` (the preferences' copy) when the file exists, else `fallback`,
    /// which is then written as the file (the migration). The schema is written next to it either way.
    func startup(fallback: AppSettings) -> AppSettings {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writeIfChanged(SettingsSchema.data(), to: schemaURL)
        guard let data = try? Data(contentsOf: url) else {
            let fresh = SettingsFileFormat.render(fallback)
            write(fresh)
            return fallback
        }
        lastSeen = data
        let result = SettingsFileCheck.read(data, over: fallback)
        issues = result.issues
        needsBackup = !result.issues.isEmpty
        return result.settings
    }

    // MARK: importing

    /// A settings.json from another install (the GitHub version's, chosen in a panel), read the way the app's own is: over
    /// `current`, issues reported. Nothing is written back here and the app's file keeps its own backup rules.
    /// `keepsExportFolder`: the other install's folder path means nothing inside the sandbox, so the folder stays as it is.
    nonisolated static func importResult(_ data: Data, over current: AppSettings,
                                         keepsExportFolder: Bool = Distribution.isAppStore) -> SettingsFileResult {
        var result = SettingsFileCheck.read(data, over: current)
        if keepsExportFolder, result.parsed {
            result.settings.exportFolder = current.exportFolder
            result.changed.removeAll { $0 == "exportFolder" }
        }
        return result
    }

    // MARK: writing

    /// Writes `settings` as the file. While the file has problems it is first kept as settings.json.broken: this write
    /// replaces it, and what a person typed in it must not vanish.
    func save(_ settings: AppSettings) {
        let data = SettingsFileFormat.render(settings)
        guard data != lastSeen else { return }
        keepOldShape()
        var notice: [SettingsFileIssue] = []
        if needsBackup, FileManager.default.fileExists(atPath: url.path) {
            needsBackup = false
            try? FileManager.default.removeItem(at: brokenURL)
            do {
                try FileManager.default.copyItem(at: url, to: brokenURL)
                notice = [.init(line: nil, message: "\(url.lastPathComponent) had problems and was replaced; the old file is \(brokenURL.lastPathComponent)")]
            } catch {
                log.error("settings.json.broken could not be written: \(error.localizedDescription, privacy: .public)")
            }
        }
        write(data)
        issues = notice
    }

    /// The first save in the new shape copies a file in 1.1.4's shape beside it, once: `settings-1.1.4.json` is never overwritten, so a
    /// downgrade has the file it left. A file already in the new shape, or no file, copies nothing.
    private func keepOldShape() {
        guard let existing = try? Data(contentsOf: url), SettingsFileCheck.isOldShape(existing),
              !FileManager.default.fileExists(atPath: oldShapeURL.path) else { return }
        do {
            try FileManager.default.copyItem(at: url, to: oldShapeURL)
        } catch {
            log.error("settings-1.1.4.json could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(_ data: Data) {
        do {
            try data.write(to: url, options: .atomic)
            lastSeen = data
        } catch {
            log.error("settings.json could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeIfChanged(_ data: Data, to target: URL) {
        if (try? Data(contentsOf: target)) != data { try? data.write(to: target, options: .atomic) }
    }

    // MARK: reading changes

    /// Reads the file after a change on disk. nil when there is nothing to apply: the bytes are the ones last written or
    /// read, or the text is not JSON (the settings stay, the file is left alone, the issue is kept for the Settings window).
    func fileChanged(current: AppSettings) -> SettingsFileResult? {
        guard let data = try? Data(contentsOf: url) else {
            // Deleted: written again from what the app holds.
            lastSeen = nil
            issues = []
            needsBackup = false
            save(current)
            return nil
        }
        guard data != lastSeen else { return nil }
        lastSeen = data
        let result = SettingsFileCheck.read(data, over: current)
        issues = result.issues
        needsBackup = !result.issues.isEmpty
        return result.parsed ? result : nil
    }

    // MARK: watching

    /// Calls `onChange` (after 0.3 s without further events) when the folder or the file changes. The folder is watched
    /// so an editor that replaces the file atomically is seen, the file itself so one that writes in place is too.
    func startWatching(_ onChange: @escaping @MainActor () -> Void) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirSource = Self.source(path: dir.path, mask: .write) { [weak self] in self?.scheduled(onChange) }
        armFile(onChange)
    }

    private func armFile(_ onChange: @escaping @MainActor () -> Void) {
        fileSource?.cancel()
        fileSource = Self.source(path: url.path, mask: [.write, .extend, .delete, .rename]) { [weak self] in self?.scheduled(onChange) }
    }

    private func scheduled(_ onChange: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                // The file may be a new one (atomic replace): watch that one.
                self?.armFile(onChange)
                onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private static func source(path: String, mask: DispatchSource.FileSystemEvent,
                               _ handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { handler() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }
}
