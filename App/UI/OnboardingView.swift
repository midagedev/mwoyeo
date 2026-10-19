import Combine
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let intelligence = IntelligenceTranslator()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            LensDemo()
                .padding(.horizontal, 28)
                .padding(.top, 40)
            VStack(spacing: 6) {
                Text("Mwoyeo")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Put a lens on the screen. The text under it is erased and rewritten in your language.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)
            .padding(.top, 22)
            .padding(.bottom, 22)

            VStack(spacing: 10) {
                StepCard(number: 1, title: String(localized: "Screen Recording"), done: model.hasScreenPermission,
                         detail: model.hasScreenPermission ? String(localized: "Allowed. Mwoyeo reads only what is under a lens, and never stores or sends it.")
                             : String(localized: "Needed to read the text under a lens. You may have to reopen Mwoyeo after allowing it.")) {
                    if !model.hasScreenPermission {
                        Button("Allow") { model.requestPermission() }.buttonStyle(.glassProminent)
                    }
                }
                StepCard(number: 2, title: String(localized: "Languages"), done: true,
                         detail: intelligence.isAvailable ? String(localized: "Apple Intelligence translates with context. For faster translation, get a language pack in Settings › Translation.")
                             : String(localized: "Mwoyeo uses Apple Translation. Get a language pack in Settings › Translation.")) {
                    LanguageBar(source: $model.settings.sourceLanguage, target: $model.settings.targetLanguage)
                        .frame(width: 230)
                }
                StepCard(number: 3, title: String(localized: "Place a Lens"), done: !model.regions.isEmpty,
                         detail: String(localized: "Press \(model.shortcut(.addLens) ?? "⌃⌥L") anywhere, then drag an area or click. The lens follows the window it lands on; hold ⌥ to pin it to the screen.")) {
                    Button("Try It Now") {
                        finish()
                        Task { await model.addRegion() }
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.hasScreenPermission)
                }
            }
            .padding(.horizontal, 28)

            if Distribution.isAppStore {
                ImportSettingsRow()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
            }

            HStack {
                Text("Everything happens on this Mac.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Get Started") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(28)
        }
        .frame(width: 600)
        .onReceive(permissionTimer) { _ in model.recheckPermission() }
    }

    private func finish() {
        model.settings.hasCompletedOnboarding = true
        close()
    }
}

private struct StepCard<Accessory: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(!done)   // the number is noise; the check says the step is done
            .animation(Motion.shared.animation(.spring(duration: 0.3)), value: done)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A chat window with a lens gliding over it; under the lens the messages read in the interface language.
private struct LensDemo: View {
    /// (name, colour, original, translation). The originals are English, or Japanese for an English interface.
    private let rows: [(String, Color, String, String)] = {
        let en = Bundle.main.preferredLocalizations.first == "en"
        return [
            ("maya", Color(red: 0.96, green: 0.48, blue: 0.40),
             en ? "昨夜パッチノート見るまで起きてた人いる？" : "ok who stayed up for the patch notes last night",
             String(localized: "ok who stayed up for the patch notes last night")),
            ("junpark", Color(red: 0.35, green: 0.65, blue: 1.00),
             en ? "はい私。やっと二段ジャンプのバグ直ったね" : "guilty. they finally fixed the double jump bug",
             String(localized: "guilty. they finally fixed the double jump bug")),
            ("rinrin", Color(red: 0.94, green: 0.70, blue: 0.20),
             en ? "今夜レイド行ける人いる？あと二人ほしい" : "anyone up for the raid tonight? need two more",
             String(localized: "anyone up for the raid tonight? need two more")),
            ("samwise", Color(red: 0.23, green: 0.65, blue: 0.36),
             en ? "了解、9時に集合で！" : "count me in, see you all at 9",
             String(localized: "count me in, see you all at 9")),
        ]
    }()

    private let rowHeight: CGFloat = 50, top: CGFloat = 16

    var body: some View {
        // Reduce Motion: the lens rests half way down, over two of the messages.
        let still = Motion.shared.reduced
        TimelineView(.animation(paused: still)) { t in
            GeometryReader { g in
                // The lens glides down and back over the messages; whatever it covers reads translated, message by message.
                let phase = still ? 0.5 : (sin(t.date.timeIntervalSinceReferenceDate * 0.6 - .pi / 2) + 1) / 2
                let lensHeight = rowHeight * 2 + 8
                let lens = CGRect(x: 16, y: top - 4 + phase * (rowHeight * CGFloat(rows.count) - lensHeight + 8),
                                  width: g.size.width - 32, height: lensHeight)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.19, green: 0.20, blue: 0.22))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(red: 0.15, green: 0.16, blue: 0.18))
                        .frame(width: lens.width, height: lens.height)
                        .offset(x: lens.minX, y: lens.minY)
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        let mid = top + rowHeight * (CGFloat(i) + 0.5)
                        message(r, translated: lens.minY < mid && mid < lens.maxY)
                            .offset(x: 34, y: top + rowHeight * CGFloat(i) + 6)
                    }
                    LensRing(cornerRadius: 14, lineWidth: 2.5, glow: 9, spinning: true, period: 7)
                        .frame(width: lens.width, height: lens.height)
                        .offset(x: lens.minX, y: lens.minY)
                }
            }
        }
        .frame(height: top * 2 + rowHeight * CGFloat(rows.count))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A lens turning text into your language")
    }

    private func message(_ r: (String, Color, String, String), translated: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(r.1).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: r.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(r.1)
                Text(verbatim: translated ? r.3 : r.2)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(translated ? 1 : 0.72))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: translated)
            }
        }
    }
}
