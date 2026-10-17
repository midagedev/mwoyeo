import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as Carbon registers it, plus how to show it.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`controlKey | optionKey`…).
    var modifiers: UInt32
    var display: String

    /// A combo from a key press, if it has ⌃ or ⌥. Bare keys would steal typing in every app, and ⌘ combos are
    /// the apps' own (⌘Q, ⌘W, ⌘C…): registered globally they would stop working everywhere.
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !f.intersection([.control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = (f.contains(.control) ? UInt32(controlKey) : 0) | (f.contains(.option) ? UInt32(optionKey) : 0)
            | (f.contains(.shift) ? UInt32(shiftKey) : 0) | (f.contains(.command) ? UInt32(cmdKey) : 0)
        display = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "")
            + (f.contains(.command) ? "⌘" : "") + Self.name(of: event.keyCode, typed: key)
    }

    init(keyCode: Int, modifiers: Int, display: String) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.display = display
    }

    private static func name(of keyCode: UInt16, typed: String) -> String {
        switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: typed
        }
    }
}

enum HotKeyAction: String, Codable, CaseIterable, Identifiable {
    case addLens, toggleOriginal, pause, refresh
    /// Lens actions, no default combo; they act on the lens under the pointer, else the newest one.
    case saveLensImage, copyOriginal, readAloud

    var id: String { rawValue }
    var title: String {
        switch self {
        case .addLens: String(localized: "Add Lens")
        case .toggleOriginal: String(localized: "Show Original")
        case .pause: String(localized: "Pause")
        case .refresh: String(localized: "Translate Again")
        case .saveLensImage: String(localized: "Save Lens Image")
        case .copyOriginal: String(localized: "Copy Original Text")
        case .readAloud: String(localized: "Read Aloud")
        }
    }

    /// ⌃⌥ plus a letter, avoiding the ⌃⌥ letters window managers such as Rectangle and Magnet take by default
    /// (D F G E T for thirds, U I J K for corners, C for centre). Pause and refresh have none: the menu has them.
    static let defaults: [String: KeyCombo] = [
        HotKeyAction.addLens.rawValue: KeyCombo(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey, display: "⌃⌥L"),
        HotKeyAction.toggleOriginal.rawValue: KeyCombo(keyCode: kVK_ANSI_O, modifiers: controlKey | optionKey, display: "⌃⌥O"),
    ]
}

/// System-wide shortcuts via Carbon's RegisterEventHotKey — still the only API that works without
/// Accessibility permission. It does not fail when another app registered the same combo (both succeed), so a
/// clash cannot be detected; the defaults stay clear of popular apps and every shortcut can be re-recorded.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var handlers: [HotKeyAction: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func setHandler(_ action: HotKeyAction, _ handler: @escaping () -> Void) { handlers[action] = handler }

    /// Registers `combos` (action raw value → combo), replacing what was registered.
    func apply(_ combos: [String: KeyCombo]) {
        installIfNeeded()
        suspend()
        for (i, action) in HotKeyAction.allCases.enumerated() {
            guard let c = combos[action.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D57_5941), id: UInt32(i)) // 'MWYA'
            if RegisterEventHotKey(c.keyCode, c.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    /// Unregisters everything, so a shortcut being recorded reaches the recorder instead of firing.
    func suspend() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    fileprivate func fire(_ index: UInt32) {
        guard Int(index) < HotKeyAction.allCases.count else { return }
        handlers[HotKeyAction.allCases[Int(index)]]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
