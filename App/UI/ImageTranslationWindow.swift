import AppKit
import MwoyeoCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// "Translate Image…": a picture from a file, the clipboard or a drop, read and translated like a lens does it
/// (`StillTranslation`), shown filling in, with the actions a lens image has.
@MainActor
@Observable
final class ImageTranslationModel {
    /// `needsPack`: the picture was read, and the translation waits for a language pack.
    enum Phase: Equatable { case empty, working, done(lines: Int), needsPack(PackPair), failed(String) }

    private(set) var title = ""
    private(set) var phase = Phase.empty
    private(set) var original: NSImage?
    private(set) var translated: NSImage?
    private(set) var texts: [BlockText] = []
    var showOriginal = false

    @ObservationIgnored private var still: StillTranslation?
    /// Opens the picture again (after a language pack came down).
    @ObservationIgnored private var reload: (() -> Void)?
    /// A new picture sizes the window to itself; opening the same one again does not.
    @ObservationIgnored private var fitting = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queued: OverlaySnapshot?
    @ObservationIgnored private var compositing = false
    /// Called when a new picture has been loaded (the window sizes itself to it).
    @ObservationIgnored var onLoaded: ((NSSize) -> Void)?
    /// Called once the translation has settled, with this model.
    @ObservationIgnored var onSettled: (() -> Void)?

    var isWorking: Bool { phase == .working }

    /// A settled window without reading anything, for UI captures when the text recognizer is not answering.
    func showSettled(_ picture: NSImage, lines: Int) {
        title = "Sample"
        original = picture
        translated = picture
        phase = .done(lines: lines)
    }

    func open(url: URL) {
        let data = try? Data(contentsOf: url)
        reload = { [weak self] in self?.open(url: url) }
        start(title: url.lastPathComponent) { try data.map { try StillTranslation.decode($0) } ?? { throw StillTranslation.Unreadable(description: "Can’t read \(url.lastPathComponent).") }() }
    }

    /// Shows `message` in the window's status line instead of a picture's result.
    func fail(_ message: String) { phase = .failed(message) }

    func open(data: Data, title: String) {
        reload = { [weak self] in self?.open(data: data, title: title) }
        start(title: title) { try StillTranslation.decode(data) }
    }

    /// The picture again, once the pack it waited for is installed; the window stays as the person left it.
    func retry() {
        fitting = false
        reload?()
        fitting = true
    }

    /// "Download <language> (once)": the system's sheet over this window (`packDownload(in: .image)`).
    func downloadPack(_ pair: PackPair) { PackDownload.shared.request(pair, in: .image) }

    /// An issue the translator cannot get past by itself: waiting on retries would only spin until the ceiling.
    private static func blocksTranslating(_ issue: TranslationIssue?) -> Bool {
        switch issue {
        case .languagePackMissing?, .unsupportedPair?: true
        default: false
        }
    }

    private func start(title: String, decode: () throws -> StillTranslation.Decoded) {
        generation += 1
        let mine = generation
        self.title = title
        let decoded: StillTranslation.Decoded
        do { decoded = try decode() } catch {
            phase = .failed(String(describing: error))
            return
        }
        let size = NSSize(width: CGFloat(decoded.image.width) / decoded.scale, height: CGFloat(decoded.image.height) / decoded.scale)
        original = NSImage(cgImage: decoded.image, size: size)
        translated = nil
        texts = []
        showOriginal = false
        phase = .working
        if fitting { onLoaded?(size) }

        let app = AppModel.shared
        var settings = app.effectiveSettings
        // A still has no motion to wait out: the finished rewrite, unless the user asked for boxes.
        if settings.renderMode == .adaptive { settings.renderMode = .seamless }
        let still = StillTranslation(decoded, settings: settings, translator: app.translator, inpainter: app.inpainter,
                                     onSnapshot: { [weak self] s in Task { @MainActor in self?.received(s, of: mine) } })
        self.still = still
        Task {
            await still.ingest()
            // A missing pack is no reason to wait out the ceiling: the translator fails the same way on every retry.
            try? await still.settle(from: Date(), maxWait: 180, giveUpWhenPaused: { await MainActor.run { Self.blocksTranslating(AppModel.shared.issue) } })
            guard mine == generation else { return }
            let snapshot = still.latest
            texts = ReadingOrder.sorted(snapshot?.texts ?? [], frame: \.frame)
            if let snapshot { await show(snapshot, of: still, generation: mine) }
            guard mine == generation else { return }
            // "No text found" would be wrong when the recognizer could not read at all, and "N lines translated" when the
            // picture is still in its own language.
            if texts.isEmpty, let issue = app.issue, issue.isTextRecognition {
                phase = .failed(issue.message)
            } else if texts.contains(where: { $0.translation == nil }), Self.blocksTranslating(app.issue), let issue = app.issue {
                if case let .languagePackMissing(source, target) = issue {
                    phase = .needsPack(PackPair(source: source, target: target))
                } else {
                    phase = .failed(issue.message)
                }
            } else {
                phase = .done(lines: texts.count)
            }
            onSettled?()
        }
    }

    /// Snapshots arrive faster than a picture can be composed: only the newest is drawn.
    private func received(_ s: OverlaySnapshot, of g: Int) {
        guard g == generation, let still else { return }
        queued = s
        guard !compositing else { return }
        compositing = true
        Task {
            while let next = queued, g == generation {
                queued = nil
                await show(next, of: still, generation: g)
            }
            compositing = false
        }
    }

    private func show(_ s: OverlaySnapshot, of still: StillTranslation, generation g: Int) async {
        let image = await Task.detached(priority: .userInitiated) { still.composite(s) }.value
        guard g == generation, let image else { return }
        translated = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / still.scale, height: CGFloat(image.height) / still.scale))
    }

    // MARK: Actions

    var shown: NSImage? { showOriginal ? original : (translated ?? original) }

    /// Each line as read, then what it says, in reading order, a blank line between lines.
    var copyText: String {
        texts.map { t in [t.source, t.translation].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    func copyImage() {
        guard let translated else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([translated])
    }

    func copyTextToPasteboard() { LensText.copy([copyText]) }

    func save() {
        guard let cg = translated?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ((title as NSString).deletingPathExtension + " translated").trimmingCharacters(in: .whitespaces) + ".png"
        // Only where the panel opens; the panel itself grants the write to the chosen file.
        if let shown = ExportFolder.shownPath(AppModel.shared.settings) { panel.directoryURL = URL(fileURLWithPath: shown) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LensImage.writePNG(cg, to: url) } catch { phase = .failed("Couldn’t save the image.") }
    }
}

struct ImageTranslationView: View {
    @Bindable var model: ImageTranslationModel
    let onDrop: ([URL]) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image = model.shown {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .overlay { if model.isWorking { LensRing(cornerRadius: 4, lineWidth: 2, glow: 4, spinning: true).allowsHitTesting(false) } }
                        .padding(16)
                        // The picture is named, and its text is what a screen reader reads: the translation, or the original with Show Original.
                        .accessibilityLabel(model.title)
                        .accessibilityValue(model.texts.compactMap { model.showOriginal ? $0.source : LensText.usable($0) }.joined(separator: "\n"))
                } else {
                    Text("Drop a picture here, or press ⌘V to paste one.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.4))
            Divider()
            bar
        }
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in onDrop(urls) }
        // The pack the picture waits for comes down in a sheet over this window; then the picture is translated again.
        .packDownload(in: .image) { model.retry() }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 8)
            Toggle("Show Original", isOn: $model.showOriginal)
                .toggleStyle(.button)
                .foregroundStyle(model.showOriginal ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .disabled(model.translated == nil)
            Button("Copy Image") { model.copyImage() }.disabled(model.translated == nil)
            Button("Copy Text") { model.copyTextToPasteboard() }.disabled(model.texts.isEmpty)
            Button("Save…") { model.save() }.disabled(model.translated == nil)
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .empty: EmptyView()
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading and translating…").font(.caption).foregroundStyle(.secondary)
            }
        case .done(let n):
            Text(n == 0 ? String(localized: "No text found") : String(localized: "\(n) lines translated")).font(.caption).foregroundStyle(.secondary)
        case .needsPack(let pair):
            HStack(spacing: 8) {
                Label("Language pack needed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                Button(LensHintText.downloadPack(pair)) { model.downloadPack(pair) }.controlSize(.small)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// Owns the image window; one at a time, a new picture replaces the one shown.
@MainActor
final class ImageTranslation: NSObject, NSWindowDelegate {
    static let shared = ImageTranslation()

    let model = ImageTranslationModel()
    private var window: NSWindow?
    private var keyMonitor: Any?

    private override init() { super.init() }

    /// The menu item: pick a picture, then show it.
    func chooseImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a picture to translate")
        panel.begin { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.show { $0.open(url: url) } }
        }
    }

    func open(urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        show { $0.open(url: url) }
        return true
    }

    /// What ⌘V opens. A file URL copied in Finder may not be readable inside the sandbox; the picture's own data on the
    /// pasteboard (Finder puts it there too) is the fallback, and with neither the window says what to do instead.
    enum PasteSource: Equatable {
        case file(URL), data(Data), unreadable, nothing
    }

    static func pasteSource(urls: [URL], imageData: Data?, canRead: (URL) -> Bool = ImageTranslation.canRead) -> PasteSource {
        if let url = urls.first, canRead(url) { return .file(url) }
        if let imageData { return .data(imageData) }
        return urls.isEmpty ? .nothing : .unreadable
    }

    nonisolated static func canRead(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    /// ⌘V while the window is open: a picture on the pasteboard (a file or image data).
    @discardableResult
    func paste() -> Bool {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL]) ?? []
        let data = [NSPasteboard.PasteboardType.png, .tiff].lazy.compactMap { pb.data(forType: $0) }.first
        switch Self.pasteSource(urls: urls, imageData: data) {
        case let .file(url): return open(urls: [url])
        case let .data(data): show { $0.open(data: data, title: String(localized: "Pasted Image")) }; return true
        case .unreadable:
            show { $0.fail(String(localized: "Mwoyeo can’t read the copied file. Open the file with Open… instead.")) }
            return true
        case .nothing: return false
        }
    }

    private func show(_ load: (ImageTranslationModel) -> Void) {
        let w = window ?? makeWindow()
        load(model)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: ImageTranslationView(model: model, onDrop: { [weak self] in self?.open(urls: $0) ?? false }))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 360)
        w.delegate = self
        w.setContentSize(NSSize(width: 760, height: 560))
        w.center()
        model.onLoaded = { [weak self] size in self?.fit(size) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, window?.isKeyWindow == true, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers == "v" else { return e }
            return paste() ? nil : e
        }
        window = w
        return w
    }

    /// The window grows to the picture (at most 80 % of the screen); `title` follows the file.
    private func fit(_ picture: NSSize) {
        guard let w = window else { return }
        w.title = model.title
        let screen = w.screen?.visibleFrame.size ?? NSSize(width: 1400, height: 900)
        let chrome = NSSize(width: 32, height: 32 + 53)
        let room = NSSize(width: screen.width * 0.8 - chrome.width, height: screen.height * 0.8 - chrome.height)
        let f = min(1, room.width / picture.width, room.height / picture.height)
        let size = NSSize(width: max(520, picture.width * f + chrome.width), height: max(360, picture.height * f + chrome.height))
        w.setContentSize(size)
        w.center()
    }

    func windowWillClose(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        window = nil
    }

    #if !MAS
    // MARK: Debug launch (screenshots and gates)

    /// `-translateImage <path>` opens the window with that picture. With `-translateImageOut <dir>` it also writes
    /// `original.png`, `translated.png`, `window-translated.png`, `window-original.png` and `copy-text.txt` once the
    /// translation has settled, then quits.
    func openFromLaunchArguments() {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let path = value("-translateImage") else { return }
        let out = value("-translateImageOut").map { URL(fileURLWithPath: $0) }
        show { $0.open(url: URL(fileURLWithPath: path)) }
        guard let out else { return }
        model.onSettled = { [weak self] in Task { @MainActor in await self?.dump(to: out) } }
    }

    private func dump(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func png(_ image: NSImage?, _ name: String) {
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            try? LensImage.writePNG(cg, to: dir.appendingPathComponent(name))
        }
        func shot(_ name: String) {
            // Just this window, by id (`screencapture -l`), shadow off.
            guard let w = window else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(w.windowNumber), dir.appendingPathComponent(name).path]
            try? p.run()
            p.waitUntilExit()
        }
        png(model.original, "original.png")
        png(model.translated, "translated.png")
        try? model.copyText.write(to: dir.appendingPathComponent("copy-text.txt"), atomically: true, encoding: .utf8)
        print("copy-text: \(model.texts.count) originals, \(model.texts.filter { $0.translation != nil }.count) translations")
        try? await Task.sleep(for: .milliseconds(500))
        shot("window-translated.png")
        model.showOriginal = true
        try? await Task.sleep(for: .milliseconds(400))
        shot("window-original.png")
        exit(0)
    }
    #endif
}
