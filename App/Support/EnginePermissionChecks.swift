#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines
import SwiftUI

/// The checks of the permission to send the lens's text to an engine off this Mac, run by `--capture-ui … check-logic` (PASS/FAIL lines):
/// the record keyed by engine and host, the one gate in front of every call (end to end through `TranslationService`, against
/// `tools/mock-openai`), the sheet's box, the upgrade step of each flavour (the flavour is a parameter), and that an import, a paste or a
/// file edit never grants. The mock listens on 127.0.0.1; an engine at `127.000.000.001` (or `[::ffff:127.0.0.1]`) reaches it too and counts
/// as off this Mac, because only `localhost`, `127.0.0.1` and `::1` are on this Mac (`ChatTranslation.isOnThisMac`), while App Transport
/// Security lets these plain-http loopback spellings through (`127.1` and `0.0.0.0` it blocks).
@MainActor
enum EnginePermissionChecks {
    /// What a service told the lens about its engine, in order: a reason, or nil when the notice ended.
    final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String?] = []
        func add(_ issue: TranslationIssue?) {
            let reason: String?
            if case let .engineUnavailable(_, r)? = issue { reason = r } else if issue == nil { reason = nil } else { return }
            lock.withLock { items.append(reason) }
        }
        var all: [String?] { lock.withLock { items } }
        /// The newest event ended the notice.
        var ended: Bool { lock.withLock { items.last.map { $0 == nil } ?? false } }
    }

    static func chat(_ url: String, id: UUID = UUID(), context: EngineContext? = nil) -> EngineConfig {
        EngineConfig(id: id, name: "Test", kind: .openAICompatible(baseURL: URL(string: url)!, model: "m1", thinking: .off, extraHeaders: [:]), context: context)
    }

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") engine permission: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }

        // The record: keyed by engine and host; an engine on this Mac needs none; a changed host no longer matches.
        let id = UUID()
        let cloud = chat("https://api.example.com/v1", id: id)
        let moved = chat("https://api.other.example/v1", id: id)
        let local = chat("http://localhost:11434/v1"), loopback = chat("http://127.0.0.1:8080/v1")
        let command = EngineConfig(name: "Mine", kind: .command(CommandSpec(executable: "/usr/bin/python3")))
        var p = EnginePermissions()
        check("a local engine needs no record", p.allows(local) && p.allows(loopback) && p.allows(command) && EnginePermissions.host(of: local) == nil)
        check("a remote engine without a record is not allowed", !p.allows(cloud) && EnginePermissions.host(of: cloud) == "api.example.com")
        p.set(true, for: cloud)
        check("ticking the box for an engine allows it, and nothing else", p.allows(cloud) && !p.allows(chat("https://api.example.com/v1")))
        check("a host change voids the record, and the old host matches again when it comes back",
              !p.allows(moved) && p.allows(cloud) && p.allows(chat("https://API.Example.COM/v1", id: id)))
        p.set(true, for: local)
        check("a local engine keeps no record", p.hosts.count == 1)
        p.set(false, for: cloud)
        check("clearing the box takes the record away", !p.allows(cloud) && p.hosts.isEmpty)
        p.set(true, for: cloud)
        p.forget(id)
        check("removing an engine forgets its record", !p.allows(cloud))
        check("the sheet's Add and Save open only with the box ticked for the host the engine has now",
              !EnginePermissions.mayCommit(cloud, ticked: nil) && !EnginePermissions.mayCommit(moved, ticked: "api.example.com")
              && EnginePermissions.mayCommit(cloud, ticked: "api.example.com") && EnginePermissions.mayCommit(local, ticked: nil))

        // The upgrade step: the DMG grants what it already has, once; the App Store build grants nothing; a later arrival is never granted.
        let other = chat("https://api.second.example/v1"), later = chat("https://api.third.example/v1")
        var dmg = EnginePermissions()
        dmg.launch(engines: [cloud, other, local], grantsExisting: true)
        check("DMG, first launch: every engine already in settings.json is allowed", dmg.allows(cloud) && dmg.allows(other) && dmg.hosts.count == 2 && dmg.migrated)
        let kept = (try? JSONDecoder().decode(EnginePermissions.self, from: JSONEncoder().encode(dmg))) ?? EnginePermissions()
        var second = kept
        second.launch(engines: [cloud, other, local, later], grantsExisting: true)
        check("DMG, second launch: an engine that arrived since is not allowed, and the first two stay", kept == dmg && !second.allows(later) && second.allows(cloud) && second.allows(other))
        var fresh = EnginePermissions()
        fresh.launch(engines: [], grantsExisting: true)
        fresh.launch(engines: [later], grantsExisting: true)
        check("DMG, a fresh install: an engine from a file edit or a paste later is not allowed", !fresh.allows(later) && fresh.hosts.isEmpty)
        var gone = dmg
        gone.launch(engines: [cloud], grantsExisting: true)
        check("a record whose engine is gone from settings.json is dropped at launch", gone.allows(cloud) && !gone.allows(other) && gone.hosts.count == 1)
        var mas = EnginePermissions()
        mas.launch(engines: [cloud, other, local], grantsExisting: false)
        mas.launch(engines: [cloud, other, local], grantsExisting: true)
        check("App Store build: nothing is allowed on the first launch, nor on a later one", mas.hosts.isEmpty && mas.migrated && !mas.allows(cloud) && !mas.allows(other))

        // Run-time state: in the preferences' copy, never in settings.json; a file read, an import or a settings blob from before cannot move it.
        var s = AppSettings()
        s.engines = [cloud]
        s.enginePermissions = dmg
        let roundTrip = (try? JSONEncoder().encode(s)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        let fileText = String(decoding: SettingsFileFormat.render(s), as: UTF8.self)
        check("the record survives the preferences' copy and is not in settings.json", roundTrip?.enginePermissions == dmg && !fileText.contains("enginePermissions"))
        var blob = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s))) as? [String: Any] ?? [:]
        blob["enginePermissions"] = nil
        let before = (try? JSONSerialization.data(withJSONObject: blob)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        blob["enginePermissions"] = 5
        let broken = (try? JSONSerialization.data(withJSONObject: blob)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        check("settings from before this version, or with an unreadable record, grant nothing",
              before?.enginePermissions == EnginePermissions() && broken?.enginePermissions == EnginePermissions())
        let engineJSON = #"{"id": "\#(UUID().uuidString)", "kind": "openAICompatible", "name": "Imported", "baseURL": "https://api.imported.example/v1", "model": "m"}"#
        func file(_ extra: String = "") -> Data {
            Data("{\n\"engines\": [\(engineJSON)]\(extra)\n}\n".utf8)
        }
        var base = AppSettings()
        base.engines = [cloud]
        base.enginePermissions = dmg
        let edited = SettingsFileCheck.read(file(), over: base)
        let importedEngine = edited.settings.engines.first { $0.name == "Imported" }
        check("a settings.json edit that brings an engine does not allow it, and the others keep their record",
              importedEngine.map { !edited.settings.enginePermissions.allows($0) } == true && edited.settings.enginePermissions == dmg
              && edited.settings.enginePermissions.allows(cloud) && edited.changed.contains("engines"))
        let forged = SettingsFileCheck.read(file(", \"enginePermissions\": {\"hosts\": {\"\(importedEngine?.id.uuidString ?? "")\": \"api.imported.example\"}, \"migrated\": true}"), over: base)
        check("a settings.json that writes the record itself is told the key is unknown and allows nothing",
              forged.settings.enginePermissions == dmg && forged.issues.contains { $0.message.contains("unknown key enginePermissions") })
        let imported = SettingsFileStore.importResult(file(), over: base, keepsExportFolder: true)
        let importedAfter = SettingsImport(applied: imported.changed, issues: imported.issues, parsed: imported.parsed)
        check("an import from the GitHub version does not allow its engines, and says to allow each online engine",
              imported.settings.engines.contains { !imported.settings.enginePermissions.allows($0) } && imported.settings.enginePermissions == dmg
              && SettingsImporter.needsAllowing(importedAfter, in: imported.settings)
              && SettingsImporter.summary(importedAfter, askingToAllow: true).contains(String(localized: "Allow each online engine in Settings."))
              && !SettingsImporter.summary(importedAfter).contains(String(localized: "Allow each online engine in Settings.")))
        let notEngines = SettingsFileStore.importResult(Data("{\"targetLanguage\": \"fr\"}".utf8), over: base, keepsExportFolder: true)
        check("an import that brings no engine, or only allowed ones, adds no such line",
              !SettingsImporter.needsAllowing(SettingsImport(applied: notEngines.changed, issues: [], parsed: true), in: notEngines.settings)
              && !SettingsImporter.needsAllowing(SettingsImport(applied: ["engines"], issues: [], parsed: true), in: base)
              && !SettingsImporter.needsAllowing(SettingsImport(applied: ["engines"], issues: [], parsed: false), in: imported.settings))
        let copy = (try? EngineShare.decode(EngineShare.encode(cloud))) ?? chat("https://x.invalid/v1")
        check("a pasted setup is a new engine: a copy of an allowed engine is not allowed", copy.id != cloud.id && !dmg.allows(copy) && dmg.allows(cloud))

        // The engine list says so while the person has not allowed it.
        let needs = String(localized: "Needs your permission"), unavailable = String(localized: "Not available in this version")
        check("the engine list: a remote engine without a record reads \"Needs your permission\", with one its host and model, a local one as before",
              cloud.listSubtitle(permissions: EnginePermissions()) == needs && cloud.needsPermission(EnginePermissions())
              && cloud.listSubtitle(permissions: dmg) == cloud.subtitle && !cloud.needsPermission(dmg)
              && local.listSubtitle() == local.subtitle && !local.needsPermission(EnginePermissions())
              && moved.listSubtitle(permissions: dmg) == needs)
        check("the engine list: a command engine this build cannot run says so first, and never asks",
              command.listSubtitle(allowsCommands: false, permissions: EnginePermissions()) == unavailable && !command.needsPermission(EnginePermissions(), allowsCommands: false))

        // "Recent lines are sent too" shows where context could be on for the engine.
        let nearby = AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "en", target: "ko", context: AppContextOverride(mode: .nearby))
        let template = EngineConfig(name: "T", kind: .httpTemplate(HTTPTemplate(url: "https://t.example/x", body: "{}", resultPath: "t", batching: .jsonArray)),
                                    context: EngineContext(enabled: true))
        check("the context line: shown when the engine's switch or an app's override can turn context on, not otherwise",
              !EnginePermissions.sendsContext(cloud, profiles: []) && EnginePermissions.sendsContext(chat("https://api.example.com/v1", context: EngineContext(enabled: true)), profiles: [])
              && EnginePermissions.sendsContext(cloud, profiles: [nearby]) && !EnginePermissions.sendsContext(template, profiles: [nearby]))

        // The gate, end to end: the request is not sent, the lens is told with the new error, Apple answers, and a record opens it.
        setenv("MWOYEO_FAKE_ENGINE", "slow:5", 1)
        defer { unsetenv("MWOYEO_FAKE_ENGINE") }
        let text = "Hello there, welcome back"
        let apple = "⟦ko⟧ \(text)"
        for (path, context) in [("plain", nil), ("context", EngineContext(enabled: true, previousLines: 2))] as [(String, EngineContext?)] {
            guard let mock = ContextChecks.Mock(mode: "ok") else { check("\(path): the mock server starts", false); continue }
            defer { mock.stop() }
            let host = "127.000.000.001"
            let remote = ContextChecks.engine("openai", base: URL(string: "http://\(host):\(mock.port)")!, context: context)
            let lens = ContextChecks.lens(screen: [text])
            let message = EngineError.needsPermission(host: host).localizedMessage

            var closed = ContextChecks.settings(remote)
            closed.enginePermissions = EnginePermissions()
            let service = ContextChecks.service(closed)
            let notices = Notices()
            await service.setIssueHandler { notices.add($0) }
            let denied = await service.translate([text], context: lens)
            check("\(path): a remote engine without a record is not called, and the lens is told to allow it",
                  mock.bodies.isEmpty && notices.all.contains(message) && EngineError.needsPermission(host: host).userMessage == "Allow sending to \(host) in Settings",
                  "requests \(mock.bodies.count), notices \(notices.all)")
            check("\(path): no other engine stands in silently: Apple answers and the notice stays", denied.translations[text] == apple && notices.all.last == message)

            var open = closed
            open.enginePermissions.set(true, for: remote)
            await service.update(settings: open)
            let allowed = await service.translate(["See you tomorrow at nine"], context: lens)
            check("\(path): allowing the engine ends its rest at once: the request goes out and the notice ends",
                  mock.bodies.count == 1 && notices.ended && allowed.translations["See you tomorrow at nine"] != "⟦ko⟧ See you tomorrow at nine",
                  "requests \(mock.bodies.count), notices \(notices.all)")

            let movedHost = ContextChecks.engine("openai", base: URL(string: "http://[::ffff:127.0.0.1]:\(mock.port)")!, context: context)
            var changed = open
            changed.engines = [movedHost]
            changed.customEngineID = movedHost.id
            let changedService = ContextChecks.service(changed)
            let changedNotices = Notices()
            await changedService.setIssueHandler { changedNotices.add($0) }
            _ = await changedService.translate(["The meeting is moved to noon"], context: lens)
            check("\(path): a host change voids the record: the same engine at another host is not called",
                  mock.bodies.count == 1 && changedNotices.all.contains(EngineError.needsPermission(host: movedHost.endpointName).localizedMessage),
                  "requests \(mock.bodies.count), notices \(changedNotices.all)")

            let onThisMac = ContextChecks.engine("openai", base: mock.base, context: context)
            let localService = ContextChecks.service(ContextChecks.settings(onThisMac))
            _ = await localService.translate(["Nothing leaves this Mac"], context: lens)
            check("\(path): an engine on this Mac needs no record and is called", mock.bodies.count == 2, "requests \(mock.bodies.count)")
        }
        let applePath = await ContextChecks.service(AppSettings()).translate([text], context: nil)
        check("Apple Translation needs no record", applePath.translations[text] == apple)

        // The sheet: a pasted setup is added without the permission unless the box is ticked, and ticking it writes the record.
        if let mock = ContextChecks.Mock(mode: "ok") {
            defer { mock.stop() }
            let saved = model.settings
            defer { model.settings = saved }
            model.settings.engines = []
            model.settings.customEngineID = nil
            model.settings.enginePermissions = EnginePermissions()
            let setup = EngineShare.encode(ContextChecks.engine("openai", base: URL(string: "http://127.000.000.001:\(mock.port)")!))
            for ticked in [false, true] {
                let added = await addThroughSheet(model, setup: setup, allow: ticked)
                check("the sheet, box \(ticked ? "ticked" : "not ticked"): the engine is added and \(ticked ? "allowed for its host" : "not allowed")",
                      added.map { model.settings.enginePermissions.allows($0) == ticked && ($0.listSubtitle(permissions: model.settings.enginePermissions) == needs) == !ticked } == true
                      && model.settings.enginePermissions.hosts.count == (ticked ? 1 : 0),
                      "engine \(added?.endpointName ?? "none"), records \(model.settings.enginePermissions.hosts)")
                if let added { model.removeEngine(added.id) }
                check("removing the engine takes its record away", model.settings.enginePermissions.hosts.isEmpty)
            }
        } else {
            check("the sheet: the mock server starts", false)
        }
        return failed
    }

    /// The Add flow of the capture harness: the sheet pastes the setup and a key, runs its sample and presses Add. Returns the engine added.
    private static func addThroughSheet(_ model: AppModel, setup: String, allow: Bool) async -> EngineConfig? {
        let before = model.settings.engines.count
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: EngineSheet(autopilot: .init(setup: setup, key: "sk-test-permission", allow: allow, commit: true)).environment(model))
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        let end = Date().addingTimeInterval(20)
        while model.settings.engines.count == before, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        return model.settings.engines.count > before ? model.settings.engines.last : nil
    }
}
#endif
