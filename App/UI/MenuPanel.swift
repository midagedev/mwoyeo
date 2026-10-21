import MwoyeoCore
import SwiftUI

struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    /// `--capture-ui` shows the initialization state from a gate of its own (no real recognition).
    nonisolated(unsafe) static var fakeSetup: (gate: SwiftVisionGate, now: TimeInterval)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let issue = model.shownIssue {
                if case .engineUnavailable = issue {
                    EngineNotice(headline: issue.headline, reason: issue.detail, useApple: { model.selectEngine(nil) }, dismiss: { model.dismissIssue() })
                } else if issue.isTextRecognition {
                    RecognitionNotice(message: issue.message)
                } else if let languages = LanguageNotice(issue), !model.lensesSayLanguageTrouble {
                    // A lens that says it in its own row (RegionRow) is not told twice; this is for a trouble no lens shows (all off, or
                    // the image window's).
                    IssueBanner(message: languages.message(PackDownload.shared.ledger), action: languages.action(PackDownload.shared.ledger),
                                busy: languages.isDownloading(PackDownload.shared.ledger)) { languages.perform(model) }
                } else if LanguageNotice(issue) == nil {
                    IssueBanner(message: issue.message) { open() }
                }
            }
            SetupIssue()
            if !model.hasScreenPermission {
                IssueBanner(message: String(localized: "Mwoyeo needs Screen Recording permission."), action: String(localized: "Allow…")) {
                    WindowPresenter.shared.showOnboarding()
                }
            }
            #if !MAS
            if case .available(let version, let page) = Updates.shared.state {
                UpdateBanner(version: version) { NSWorkspace.shared.open(page) }
            }
            #endif
            HStack(spacing: 8) {
                LanguageBar(source: Binding(get: { model.barPair.source }, set: { model.setBarLanguages(source: $0) }),
                            target: Binding(get: { model.barPair.target }, set: { model.setBarLanguages(target: $0) }))
                if !model.settings.engines.isEmpty { EngineMenu() }
            }
            // L1 (design §6.5): once a profile exists the caption is a menu that pins every lens; at L0 there is no caption at all.
            if !model.settings.appProfiles.isEmpty { ProfileCaption().padding(.top, -6) }
            regionList
            addButton
            Divider().padding(.horizontal, -4)
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.recheckPermission() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mwoyeo").font(.system(.headline, design: .rounded))
                StatusLine(base: statusLine)
            }
            Spacer()
            Button {
                Task { await model.togglePause() }
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .help(withShortcut(model.isPaused ? String(localized: "Resume") : String(localized: "Pause all"), .pause))
            .accessibilityLabel(model.isPaused ? String(localized: "Resume") : String(localized: "Pause all"))
            .disabled(model.regions.isEmpty)
        }
    }

    /// Empty with no lens at all: the body says "No lenses yet" (ui-audit-1-1-5 1.4). "No lenses on" is for lenses that exist and are off.
    private var statusLine: String {
        let active = model.regions.filter(\.isEnabled).count
        if model.regions.isEmpty { return "" }
        if model.isPaused { return String(localized: "Paused") }
        if active == 0 { return String(localized: "No lenses on") }
        if model.isBusy { return String(localized: "\(active) lenses · reading…") }
        return String(localized: "\(active) lenses · translating")
    }

    @ViewBuilder private var regionList: some View {
        if model.regions.isEmpty {
            VStack(spacing: 10) {
                EmptyLens().frame(width: 132, height: 64)
                Text("No lenses yet")
                    .font(.callout.weight(.semibold))
                Text("Put a lens over anything you want to read\nand it translates right there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else {
            VStack(spacing: 6) {
                ForEach(model.regions) { region in
                    RegionRow(region: region)
                }
            }
            .id(model.sessionTick)
        }
    }

    private var addButton: some View {
        Button {
            Task { await model.addRegion() }
        } label: {
            HStack {
                Image(systemName: "plus.viewfinder")
                Text("Add Lens")
                Spacer()
                if let k = model.shortcut(.addLens) { KeyCap(k) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                model.toggleTranslations()
            } label: {
                Label(model.translationsVisible ? String(localized: "Show Original") : String(localized: "Show Translation"),
                      systemImage: model.translationsVisible ? "eye" : "eye.slash")
            }
            .help(withShortcut(String(localized: "Hide translations and show the original"), .toggleOriginal))
            .disabled(!canToggleOriginal)
            .foregroundStyle(canToggleOriginal ? HierarchicalShapeStyle.secondary : .tertiary)
            .layoutPriority(1)
            Button {
                model.toggleLensesHidden()
            } label: {
                Label(model.lensesHidden ? String(localized: "Show Lenses") : String(localized: "Hide Lenses"),
                      systemImage: model.lensesHidden ? "rectangle.slash" : "viewfinder")
            }
            .help(withShortcut(String(localized: "Hide every lens until you press this again. A lens you add shows them again."), .hideLenses))
            .disabled(!canToggleLenses)
            .foregroundStyle(canToggleLenses ? HierarchicalShapeStyle.secondary : .tertiary)
            // 4 + 16 = 20 pt between the two labelled buttons, twice a label's icon-to-text gap, so each icon reads as its own button's.
            .padding(.leading, 16)
            .layoutPriority(1)
            Spacer(minLength: 0)
            // 22 × 22 pt hit areas, the glyphs as they were (ui-audit-1-1-5 X1); ⌘, and ⌘Q as every Mac app has them (1.2). The icons keep
            // their room first and the labels next, so a long label is cut before an icon is pushed out.
            Button { ImageTranslation.shared.chooseImage() } label: { Image(systemName: "photo").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .help("Translate Image… — a file or the clipboard")
                .accessibilityLabel("Translate Image…")
                .layoutPriority(2)
            Button { open() } label: { Image(systemName: "gearshape").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .keyboardShortcut(",", modifiers: .command)
                .help(String(localized: "Settings") + " (⌘,)")
                .accessibilityLabel("Settings")
                .layoutPriority(2)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .keyboardShortcut("q", modifiers: .command)
                .help(String(localized: "Quit Mwoyeo") + " (⌘Q)")
                .accessibilityLabel("Quit Mwoyeo")
                .layoutPriority(2)
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // The footer is drawn secondary, which a disabled button keeps; a disabled one is drawn tertiary so it reads as off (vision ui-fixes 1.1).
    private var canToggleOriginal: Bool { Self.canToggleOriginal(lenses: model.regions.count, translationsVisible: model.translationsVisible) }
    private var canToggleLenses: Bool { model.lensesHidden || model.regions.contains { model.isRunning($0.id) } }

    /// Show Original flips `translationsVisible`, which a lens added later inherits (`AppModel.addRegion`): with no lens it only makes the next one
    /// open showing the original. So it acts with a lens, or while the translations are hidden (the way back). ui-audit-1-1-5 1.1.
    static func canToggleOriginal(lenses: Int, translationsVisible: Bool) -> Bool { lenses > 0 || !translationsVisible }

    private func withShortcut(_ help: String, _ action: HotKeyAction) -> String {
        model.shortcut(action).map { "\(help) (\($0))" } ?? help
    }

    private func open() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

struct RegionRow: View {
    @Environment(AppModel.self) private var model
    let region: RegionConfig
    @State private var hovering: Bool

    /// `hovering`: the row as it is with the pointer on it (the accessibility audit hosts it so; the pointer sets it in the panel).
    init(region: RegionConfig, hovering: Bool = false) {
        self.region = region
        _hovering = State(initialValue: hovering)
    }

    var body: some View {
        HStack(spacing: 10) {
            LensChip(state: dotState)
            VStack(alignment: .leading, spacing: 1) {
                Text(region.name).font(.callout.weight(.medium)).lineLimit(1)
                if let hint = model.languageHint(of: region.id), model.error(of: region.id) == nil, region.isEnabled, !model.isPaused {
                    languageLine(hint)
                } else {
                    HStack(spacing: 3) {
                        if model.error(of: region.id) == nil {
                            Image(systemName: region.anchor != nil ? "macwindow" : "pin.fill").imageScale(.small).accessibilityHidden(true)
                        }
                        Text(subtitle).lineLimit(1)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    Task { await model.remove(region.id) }
                } label: { Image(systemName: "trash").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove Lens")
                    .accessibilityLabel("Remove Lens")
                    .transition(.opacity)
            }
            Toggle("", isOn: Binding(get: { region.isEnabled }, set: { v in Task { await model.setEnabled(region.id, v) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(region.name)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(hovering ? 0.75 : 0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        // The trash button shows under the pointer only: a screen reader and the keyboard get it as an action of the row.
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Remove Lens")) { Task { await model.remove(region.id) } }
    }

    /// What the lens's pill says about its language pair, in the row's second line: one line, the pill's words, and a click does what the
    /// pill's click does. It replaces the size line while it lasts (the row never grows).
    private func languageLine(_ hint: LensHint) -> some View {
        Button { model.performHint(of: region.id) } label: {
            HStack(spacing: 4) {
                if case .downloadingPack = hint {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                } else {
                    Image(systemName: hint.action == .chooseLanguages ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                        .imageScale(.small).foregroundStyle(hint.action == .chooseLanguages ? .yellow : Color.accentColor)
                }
                Text(LensHintText.rowLine(hint) + (hint.action != nil ? " ›" : "")).lineLimit(1)
            }
            .font(.caption2).foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint.action == nil ? "" : String(localized: "Does what the lens’s name tag offers"))
    }

    private var dotState: LensChip.State {
        if !region.isEnabled || model.isPaused { return .off }
        if model.error(of: region.id) != nil { return .error }
        switch model.activity(of: region.id) {
        case .idle: return .on
        case .reading, .translating: return .busy
        }
    }

    private var subtitle: String {
        if let e = model.error(of: region.id) { return e }
        let size = "\(Int(region.rect.width))×\(Int(region.rect.height))"
        let base = region.anchor != nil ? String(localized: "Follows the window · \(size)") : String(localized: "Pinned to the screen · \(size)")
        // The lens's own profile is named only when it is not the one the caption names (design §6.5).
        guard let head = lensHeadName else { return base }
        return "\(base) · \(head)"
    }
}

extension RegionRow {
    /// The head of this lens's chain, when it differs from the caption's (the front window's head); nil with no profile or when they agree.
    fileprivate var lensHeadName: String? {
        let s = model.settings
        guard !s.appProfiles.isEmpty, let anchor = region.anchor, let app = AppModel.app(ofWindow: anchor.windowID) else { return nil }
        let lens = ProfileWords.head(s, bundleID: app.bundleID, title: anchor.title, lensPin: region.profilePin)
        let caption = ProfileWords.head(s, bundleID: model.frontmostBundleID, title: nil)
        guard lens.id != caption.id else { return nil }
        return ProfileWords.cut(lens.name, at: 24)
    }
}

/// The caption under the language bar (design §6.5), a borderless menu: "Profile: Auto" / "Profile: <head>" / "Profile: <name> (every lens)".
/// A choice pins every lens and clears their own pins (`AppModel.pinEveryLens`); "Auto" returns them all to Auto.
struct ProfileCaption: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var caption: String {
        ProfileWords.caption(head: ProfileWords.head(model.settings, bundleID: model.frontmostBundleID, title: nil), pin: model.settings.pin, owner: .menuBar, limit: 24)
    }

    var body: some View {
        let pin = Binding<String?>(get: { model.settings.profilePin }, set: { model.pinEveryLens($0) })
        Menu {
            Picker("Profile", selection: pin) {
                Text("Auto — each lens picks").tag(String?.none)
                Text("All Apps Only").tag(String?.some(AppProfile.allAppsID))
                ForEach(model.settings.appProfiles.prefix(8)) { p in Text(ProfileWords.cut(p.name, at: 24)).tag(String?.some(p.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Profiles in Settings…") {
                model.settingsTab = .translation
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        } label: {
            HStack(spacing: 3) {
                Text(caption).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        // The language bar's own menu style: a borderless menu button takes its name from its chevron ("go down") and ignores the label set on it.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(caption)
    }
}

extension AppModel {
    /// The profile the menu bar's language bar edits (design §6.5): the pinned one, else the head of the front window's chain; nil is All apps.
    var barProfile: AppProfile? { ProfileWords.head(settings, bundleID: frontmostBundleID, title: nil).profile }

    /// The pair the language bar shows: that profile's, else All apps'.
    var barPair: (source: String, target: String) {
        barProfile.map { ($0.source, $0.target) } ?? (settings.sourceLanguage, settings.targetLanguage)
    }

    /// The language bar's edits go to that profile, else to All apps.
    func setBarLanguages(source: String? = nil, target: String? = nil) {
        if let p = barProfile, let i = settings.appProfiles.firstIndex(where: { $0.id == p.id }) {
            if let source { settings.appProfiles[i].source = source }
            if let target { settings.appProfiles[i].target = target }
        } else {
            if let source { settings.sourceLanguage = source }
            if let target { settings.targetLanguage = target }
        }
    }
}

/// A lens in miniature: the spectrum ring when translating, turning while it reads, grey when off.
struct LensChip: View {
    enum State { case on, busy, off, error }
    let state: State

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(state == .off ? 0.15 : 0.55))
            VStack(alignment: .leading, spacing: 2.5) {
                ForEach([12.0, 10.0, 6.0], id: \.self) { w in
                    Capsule().fill(.white.opacity(state == .off ? 0.3 : 0.9)).frame(width: w, height: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
            if state == .error {
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.red, lineWidth: 1.5)
            } else {
                LensRing(cornerRadius: 6, lineWidth: 1.5, glow: 2.5, spinning: state == .busy, active: state != .off)
            }
        }
        .frame(width: 26, height: 20)
        .animation(.easeOut(duration: 0.25), value: state)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .on: String(localized: "Translating")
        case .busy: String(localized: "Reading")
        case .off: String(localized: "Off")
        case .error: String(localized: "Error")
        }
    }
}

/// The empty state: a lens gliding along faint lines, turning what it covers bright.
private struct EmptyLens: View {
    var body: some View {
        // Reduce Motion: the lens rests in the middle of the lines.
        let still = Motion.shared.reduced
        TimelineView(.animation(paused: still)) { t in
            GeometryReader { g in
                let phase = still ? 0.5 : (sin(t.date.timeIntervalSinceReferenceDate * 0.9) + 1) / 2
                let lens = CGRect(x: phase * (g.size.width - 64), y: 4, width: 64, height: g.size.height - 8)
                ZStack(alignment: .topLeading) {
                    lines.foregroundStyle(.primary.opacity(0.13))
                    lines.foregroundStyle(.primary.opacity(0.85))
                        .mask(Rectangle().frame(width: lens.width, height: lens.height).offset(x: lens.minX, y: lens.minY))
                    LensRing(cornerRadius: 10, lineWidth: 2, glow: 5, spinning: true, period: 6)
                        .frame(width: lens.width, height: lens.height)
                        .offset(x: lens.minX, y: lens.minY)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([1.0, 0.82, 0.93, 0.55], id: \.self) { f in
                GeometryReader { g in Capsule().frame(width: g.size.width * f, height: 5) }.frame(height: 5)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 2)
    }
}

struct LanguageBar: View {
    @Binding var source: String
    @Binding var target: String

    var body: some View {
        HStack(spacing: 0) {
            menu($source, Languages.sources, title: String(localized: "Translate from"))
            Button {
                guard source != "auto" else { return }
                withAnimation(Motion.shared.animation(.snappy)) { (source, target) = (target, source) }
            } label: {
                Image(systemName: source == "auto" ? "arrow.right" : "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(source == "auto" ? String(localized: "Translation direction") : String(localized: "Swap languages"))
            .accessibilityLabel(source == "auto" ? String(localized: "Translation direction") : String(localized: "Swap languages"))
            menu($target, Languages.targets, title: String(localized: "Translate to"))
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: Capsule())
    }

    private func menu(_ selection: Binding<String>, _ options: [String], title: String) -> some View {
        Menu {
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text(Languages.name($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(Languages.name(selection.wrappedValue)).font(.callout.weight(.medium)).contentTransition(.opacity)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
        .accessibilityValue(Languages.name(selection.wrappedValue))
    }
}

/// Apple or an added engine, next to the language bar. It exists only once an engine has been added.
private struct EngineMenu: View {
    @Environment(AppModel.self) private var model

    private var active: EngineConfig? { model.settings.activeEngineConfig }

    var body: some View {
        Menu {
            Picker("", selection: Binding(get: { model.settings.activeEngineConfig?.id }, set: { model.selectEngine($0) })) {
                Text("Apple").tag(UUID?.none)
                ForEach(model.settings.engines) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                if let active { Image(systemName: active.badgeSymbol).font(.caption) }
                Text(active?.name ?? String(localized: "Apple")).font(.callout.weight(.medium)).lineLimit(1).frame(maxWidth: 96)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
        .help("Translation engine")
        .accessibilityLabel("Translation engine")
        .accessibilityValue(active?.name ?? String(localized: "Apple"))
    }
}

#if !MAS
private struct UpdateBanner: View {
    let version: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mwoyeo \(version) is available").font(.caption.weight(.semibold))
                if Updates.viaHomebrew {
                    Text(verbatim: "brew upgrade mwoyeo").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Button("What’s New", action: open).controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
#endif

struct IssueBanner: View {
    let message: String
    var detail: String?
    var action = String(localized: "Open Settings")
    /// Something is on its way (a download): a spinner instead of the warning, and the button says where to look.
    var busy = false
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if busy {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            Button(action, action: perform).controlSize(.small)
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// An added engine gave way to Apple: a quiet line the user can close, not a warning.
struct EngineNotice: View {
    let headline: String
    let reason: String?
    let useApple: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let reason { Text(reason).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            Button("Switch to Apple", action: useApple).controlSize(.small)
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // The language bar's glass and corner radius (half its 30 pt height); a notice of two lines would turn a Capsule into a pill.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

/// The text recognizer is starting or stuck: a quiet line in the engine notice's glass, with nothing to press (no setting helps).
private struct RecognitionNotice: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The panel's banner for a trouble with the language pair, when no lens says it in its own row: a pack to download (said as asking,
/// downloading or not finished, `PackLedger`) or a pair with no translation. One action each, from where the person is.
struct LanguageNotice {
    private enum Kind {
        case pack(PackPair)
        case unsupported(PackPair)
    }

    private let kind: Kind

    init?(_ issue: TranslationIssue) {
        switch issue {
        case let .languagePackMissing(source, target): kind = .pack(PackPair(source: source, target: target))
        case let .unsupportedPair(source, target): kind = .unsupported(PackPair(source: source, target: target))
        default: return nil
        }
    }

    func isDownloading(_ ledger: PackLedger) -> Bool {
        if case let .pack(pair) = kind { return ledger.phase(of: pair) == .downloading }
        return false
    }

    func message(_ ledger: PackLedger) -> String {
        switch kind {
        case let .pack(pair):
            switch ledger.phase(of: pair) {
            case .downloading?: LensHintText.downloading(pair)
            case .notFinished?: LensHintText.notFinishedState(pair)
            case nil: String(localized: "The \(Languages.name(pair.source)) → \(Languages.name(pair.target)) language pack is not installed.")
            }
        // The pill's short words: the system's sentence wraps to three lines beside the button.
        case let .unsupported(pair): LensHintText.notSupported(pair)
        }
    }

    func action(_ ledger: PackLedger) -> String {
        switch kind {
        case let .pack(pair):
            switch ledger.phase(of: pair) {
            case .downloading?: String(localized: "Open Settings")
            case .notFinished?: String(localized: "Try again")
            case nil: String(localized: "Download")
            }
        case .unsupported: String(localized: "Choose Languages")
        }
    }

    @MainActor func perform(_ model: AppModel) {
        switch kind {
        case let .pack(pair):
            // While the sheet is up, the click only brings its window forward (`AppModel.downloadPack`).
            model.downloadPack(pair)
        case .unsupported: model.openSettings(on: .general)
        }
    }
}
