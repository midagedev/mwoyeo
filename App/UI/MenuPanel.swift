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
                } else {
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
                LanguageBar(source: Binding(get: { model.effectiveSettings.sourceLanguage }, set: { model.setLanguages(source: $0) }),
                            target: Binding(get: { model.effectiveSettings.targetLanguage }, set: { model.setLanguages(target: $0) }))
                if !model.settings.engines.isEmpty { EngineMenu() }
            }
            if let profile = model.activeProfile {
                Text("\(profile.appName) profile").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, -6)
            }
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
            .disabled(model.regions.isEmpty)
        }
    }

    private var statusLine: String {
        let active = model.regions.filter(\.isEnabled).count
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
            Spacer()
            Button { ImageTranslation.shared.chooseImage() } label: { Image(systemName: "photo") }
                .help("Translate Image… — a file or the clipboard")
                .accessibilityLabel("Translate Image…")
            Button { open() } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Mwoyeo")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func withShortcut(_ help: String, _ action: HotKeyAction) -> String {
        model.shortcut(action).map { "\(help) (\($0))" } ?? help
    }

    private func open() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

private struct RegionRow: View {
    @Environment(AppModel.self) private var model
    let region: RegionConfig
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            LensChip(state: dotState)
            VStack(alignment: .leading, spacing: 1) {
                Text(region.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 3) {
                    if model.error(of: region.id) == nil {
                        Image(systemName: region.anchor != nil ? "macwindow" : "pin.fill").imageScale(.small)
                    }
                    Text(subtitle).lineLimit(1)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    Task { await model.remove(region.id) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove Lens")
                    .transition(.opacity)
            }
            Toggle("", isOn: Binding(get: { region.isEnabled }, set: { v in Task { await model.setEnabled(region.id, v) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(hovering ? 0.75 : 0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
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
        if region.anchor != nil { return String(localized: "Follows the window · \(size)") }
        return String(localized: "Pinned to the screen · \(size)")
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
        TimelineView(.animation) { t in
            GeometryReader { g in
                let phase = (sin(t.date.timeIntervalSinceReferenceDate * 0.9) + 1) / 2
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
            menu($source, Languages.sources)
            Button {
                guard source != "auto" else { return }
                withAnimation(.snappy) { (source, target) = (target, source) }
            } label: {
                Image(systemName: source == "auto" ? "arrow.right" : "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(source == "auto" ? String(localized: "Translation direction") : String(localized: "Swap languages"))
            menu($target, Languages.targets)
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: Capsule())
    }

    private func menu(_ selection: Binding<String>, _ options: [String]) -> some View {
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
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
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
    }
}

#if !MAS
private struct UpdateBanner: View {
    let version: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
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
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
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
private struct EngineNotice: View {
    let headline: String
    let reason: String?
    let useApple: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let reason { Text(reason).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            Button("Use Apple", action: useApple).controlSize(.small)
            Button(action: dismiss) { Image(systemName: "xmark") }
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
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
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
