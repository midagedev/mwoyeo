#if !MAS
import AppKit
import MwoyeoCore

/// The checks of the App Store build's data handling, run by `--capture-ui … check-logic` (PASS/FAIL lines): the export folder
/// bookmark, the ask-once rule for a stale one, the one-time settings import and the engine list under the command gate.
/// The DMG build is not sandboxed, so the bookmark checks prove the app's side (create, resolve, write inside, never in the
/// file); the sandbox's own grant needs a signed build (the checklist in the round report).
@MainActor
enum SandboxDataChecks {
    static func run() -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print("check-logic: \(ok ? "PASS" : "FAIL") sandbox data: \(what)")
            if !ok { failed += 1 }
        }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-sandbox-checks-\(getpid())")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // The bookmark round trip: create from a folder, resolve, write a transcript inside it.
        let folder = dir.appendingPathComponent("chosen")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var s = AppSettings()
        s.exportFolder = ""
        s.exportBookmark = ExportFolder.makeBookmark(for: folder)
        check("a bookmark is made from a chosen folder", s.exportBookmark?.isEmpty == false)
        var wrote = false
        if case let .ok(url, refreshed) = ExportFolder.resolve(s, allowsPath: false), refreshed == nil,
           url.standardizedFileURL.resolvingSymlinksInPath().path == folder.standardizedFileURL.resolvingSymlinksInPath().path,
           let access = ExportFolder.begin(.ok(url, refreshed: nil)) {
            let writer = TranscriptWriter(directory: LensExport.transcriptsFolder(access.url), access: access, lens: "Sandbox", sourceCode: "ja",
                                          targetCode: "ko", formats: [.markdown], onError: {})
            writer.observe(time: 1, lines: [.init(source: "こんにちは", translation: "안녕하세요", inLens: true)])
            writer.finishAndWait(time: 2)
            let files = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("Transcripts").path)) ?? []
            wrote = files.contains { $0.hasSuffix(".md") }
        }
        check("the bookmark resolves to the folder and a transcript is written inside it", wrote)

        // Run-time state: in the preferences' copy, never in settings.json, and the file cannot drop it.
        let encoded = (try? JSONEncoder().encode(s)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        let fileText = String(decoding: SettingsFileFormat.render(s), as: UTF8.self)
        let afterFile = SettingsFileCheck.read(Data("{\"targetLanguage\": \"ko\"}".utf8), over: s).settings
        check("the bookmark survives the preferences copy, is not in settings.json, and a file read keeps it",
              encoded?.exportBookmark == s.exportBookmark && !fileText.contains("exportBookmark") && afterFile.exportBookmark == s.exportBookmark)

        // Without a bookmark: the DMG keeps its path, the App Store build has no folder.
        var plain = AppSettings()
        plain.exportFolder = folder.path
        check("no bookmark: the DMG uses the path, the App Store build needs a choice",
              ExportFolder.resolve(plain, allowsPath: true) == .path(URL(fileURLWithPath: folder.path))
              && ExportFolder.resolve(plain, allowsPath: false) == .needsChoice(stale: false))

        // A bookmark that no longer opens a folder asks once, and again only after the person chose in Settings.
        let gone = dir.appendingPathComponent("gone")
        try? fm.createDirectory(at: gone, withIntermediateDirectories: true)
        var staleSettings = AppSettings()
        staleSettings.exportFolder = ""
        staleSettings.exportBookmark = ExportFolder.makeBookmark(for: gone)
        try? fm.removeItem(at: gone)
        check("a bookmark of a removed folder needs a new choice", ExportFolder.resolve(staleSettings, allowsPath: false) == .needsChoice(stale: true))
        let gate = ExportFolderGate()
        var asked = 0, stores = 0
        gate.asker = { _ in asked += 1; return nil }
        for _ in 0..<3 { _ = gate.access(for: staleSettings) { _, _ in stores += 1 } }
        check("a stale bookmark asks once, and a declined panel is not shown again", asked == 1 && stores == 0)
        gate.reset()
        gate.asker = { _ in asked += 1; return folder }
        var chosen: Data?
        let access = gate.access(for: staleSettings) { data, _ in stores += 1; chosen = data }
        _ = gate.access(for: staleSettings) { _, _ in stores += 1 }
        check("after a reset it asks again; the choice is stored as a bookmark and the access is open",
              asked == 2 && stores == 1 && chosen?.isEmpty == false && access?.url.lastPathComponent == "chosen")
        access?.end()

        // The one-time import reads the GitHub version's file through the settings file checks.
        let fixture = dir.appendingPathComponent("github-settings.json")
        try? Data("""
        {
          "targetLanguage": "fr",
          "lensStyle": "minimal",
          "exportFolder": "/Users/test/Documents/Mwoyeo",
          "glossary": 5
        }

        """.utf8).write(to: fixture)
        var base = AppSettings()
        base.exportFolder = ""
        base.exportBookmark = s.exportBookmark
        base.hasCompletedOnboarding = true
        let imported = SettingsFileStore.importResult((try? Data(contentsOf: fixture)) ?? Data(), over: base, keepsExportFolder: true)
        check("import: valid keys apply, a wrong key is reported with its line and left, the folder and run-time state stay",
              imported.settings.targetLanguage == "fr" && base.targetLanguage != "fr" && imported.settings.lensStyle == .minimal && imported.settings.glossary == base.glossary
              && imported.issues.count == 1 && imported.issues[0].line == 5 && imported.settings.exportFolder == ""
              && imported.settings.exportBookmark == base.exportBookmark && imported.settings.hasCompletedOnboarding
              && imported.changed.sorted() == ["lensStyle", "targetLanguage"])
        let notJSON = SettingsFileStore.importResult(Data("nope".utf8), over: base, keepsExportFolder: true)
        check("import: text that is not JSON changes nothing", !notJSON.parsed && notJSON.settings == base)

        // The command gate in the engine list.
        let command = EngineConfig(name: "Mine", kind: .command(CommandSpec(executable: "/usr/bin/python3")))
        let http = EngineConfig(name: "Local", kind: .openAICompatible(baseURL: URL(string: "http://localhost:8765/v1")!, model: "m", thinking: .off, extraHeaders: [:]))
        let label = String(localized: "Not available in this version")
        check("the engine list marks a command engine as not available when commands are not allowed, and otherwise as before",
              !command.isAvailable(reach: .thisMac) && command.listSubtitle(reach: .thisMac) == label
              && command.isAvailable(reach: .anywhere) && command.listSubtitle(reach: .anywhere) == command.subtitle
              && http.isAvailable(reach: .thisMac) && http.listSubtitle(reach: .thisMac) == http.subtitle)

        // The App Store build's reach (review-2026-10-27): an engine off this Mac is listed as not available and can never be added.
        let cloud = EngineConfig(name: "Cloud", kind: .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil))
        check("the engine list marks an engine off this Mac as not available on this Mac's reach, and the sheet cannot add it",
              !cloud.isAvailable(reach: .thisMac) && cloud.listSubtitle(reach: .thisMac) == label && !cloud.needsPermission(EnginePermissions(), reach: .thisMac)
              && !EnginePermissions.mayCommit(cloud, ticked: EnginePermissions.host(of: cloud), reach: .thisMac)
              && EnginePermissions.mayCommit(http, ticked: nil, reach: .thisMac)
              && EnginePermissions.mayCommit(cloud, ticked: EnginePermissions.host(of: cloud), reach: .anywhere))

        // Paste: a Finder file the sandbox cannot read falls back to the image data; with neither it says so.
        let file = URL(fileURLWithPath: "/tmp/copied.png"), pixels = Data([1, 2, 3])
        check("paste: a readable file opens, an unreadable one falls back to the pasteboard's image data, with neither it says so",
              ImageTranslation.pasteSource(urls: [file], imageData: pixels, canRead: { _ in true }) == .file(file)
              && ImageTranslation.pasteSource(urls: [file], imageData: pixels, canRead: { _ in false }) == .data(pixels)
              && ImageTranslation.pasteSource(urls: [file], imageData: nil, canRead: { _ in false }) == .unreadable
              && ImageTranslation.pasteSource(urls: [], imageData: nil, canRead: { _ in false }) == .nothing
              && ImageTranslation.pasteSource(urls: [], imageData: pixels, canRead: { _ in false }) == .data(pixels)
              && ImageTranslation.canRead(fixture) && !ImageTranslation.canRead(dir.appendingPathComponent("missing.png")))
        return failed
    }
}
#endif
