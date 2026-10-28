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
    /// The key is named by its code, not by what the current input source typed: under Korean input ⌃⌥P types "ㅔ", and a
    /// layout may type nothing at all for ⌥ and a key, which recorded nothing.
    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !f.intersection([.control, .option]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = (f.contains(.control) ? UInt32(controlKey) : 0) | (f.contains(.option) ? UInt32(optionKey) : 0)
            | (f.contains(.shift) ? UInt32(shiftKey) : 0) | (f.contains(.command) ? UInt32(cmdKey) : 0)
        guard let shown = Self.display(keyCode: event.keyCode, modifiers: modifiers) else { return nil }
        display = shown
    }

    init(keyCode: Int, modifiers: Int, display: String) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.display = display
    }

    /// A saved combo is shown by its code too, so one recorded under another input source ("⌃⌥ㅔ") reads "⌃⌥P" again.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt32.self, forKey: .keyCode)
        modifiers = try c.decode(UInt32.self, forKey: .modifiers)
        if let shown = Self.display(keyCode: UInt16(truncatingIfNeeded: keyCode), modifiers: modifiers) { display = shown }
        else { display = try c.decode(String.self, forKey: .display) }
    }

    /// "⌃⌥⇧⌘" and the key's name; nil for a key that has no name.
    static func display(keyCode: UInt16, modifiers: UInt32) -> String? {
        guard let key = name(of: keyCode) else { return nil }
        return (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "")
            + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + key
    }

    private static func name(of keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: functionKeys[Int(keyCode)] ?? printed(keyCode)
        }
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
        kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// What the key prints, unshifted, on the ASCII keyboard the person uses (U.S., Dvorak…), whatever input source is on.
    private static func printed(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, keyCode, UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let key = String(utf16CodeUnits: chars, count: length).uppercased()
        // Function keys print private-use characters and some keys control characters: no name to show.
        let shown = key.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
        return shown && !key.trimmingCharacters(in: .whitespaces).isEmpty ? key : nil
    }
}

enum HotKeyAction: String, Codable, CaseIterable, Identifiable {
    case addLens, toggleOriginal, hideLenses, pause, refresh
    /// Lens actions, no default combo; they act on the lens under the pointer, else the newest one.
    case saveLensImage, copyOriginal, readAloud, ignoreRegion, keepRecentLines
    /// Opens the Translate Text window; no default combo, and no lens to act on.
    case translateText
    /// The whole screen translated while it is held (`Peek`); no default combo.
    case peek

    var id: String { rawValue }
    var title: String {
        switch self {
        case .addLens: String(localized: "Add Lens")
        case .toggleOriginal: String(localized: "Show Original")
        case .hideLenses: String(localized: "Hide Lenses")
        case .pause: String(localized: "Pause")
        case .refresh: String(localized: "Translate Again")
        case .saveLensImage: String(localized: "Save Lens Image")
        case .copyOriginal: String(localized: "Copy Original Text")
        case .readAloud: String(localized: "Read Aloud")
        case .translateText: String(localized: "Translate Text")
        case .ignoreRegion: String(localized: "Ignore Region")
        case .keepRecentLines: String(localized: "Keep Recent Lines")
        case .peek: String(localized: "Translate Screen While Held")
        }
    }

    /// ⌃⌥ plus a letter, avoiding the ⌃⌥ letters window managers such as Rectangle and Magnet take by default
    /// (D F G E T for thirds, U I J K for corners, C for centre). Only the few used all the time have one (the user, 2026-10-21: few
    /// defaults, the fewest clashes with other apps; 2026-10-25: the whole screen while held, ⌃⌥P, is one); every other action is assigned
    /// by the person in Settings › Shortcuts.
    static let defaults: [String: KeyCombo] = [
        HotKeyAction.addLens.rawValue: KeyCombo(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey, display: "⌃⌥L"),
        HotKeyAction.toggleOriginal.rawValue: KeyCombo(keyCode: kVK_ANSI_O, modifiers: controlKey | optionKey, display: "⌃⌥O"),
        HotKeyAction.peek.rawValue: KeyCombo(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey, display: "⌃⌥P"),
    ]
    /// The actions that had a default up to 1.1.7: settings saved then have been given these and no other.
    static let defaultsUntil117: Set<String> = [HotKeyAction.addLens.rawValue, HotKeyAction.toggleOriginal.rawValue]

    /// `shortcuts` given each default it has not been given yet (`offered`), unless its keys are already some action's: a default added in a
    /// later version reaches settings saved before it, once; one the person cleared stays cleared.
    static func givingNewDefaults(_ shortcuts: [String: KeyCombo], offered: Set<String>) -> [String: KeyCombo] {
        var out = shortcuts
        for (action, combo) in defaults where !offered.contains(action) && out[action] == nil
            && !out.values.contains(where: { $0.keyCode == combo.keyCode && $0.modifiers == combo.modifiers }) {
            out[action] = combo
        }
        return out
    }
}

/// System-wide shortcuts via Carbon's RegisterEventHotKey — still the only API that works without
/// Accessibility permission. It does not fail when another app registered the same combo (both succeed), so a
/// clash cannot be detected; the defaults stay clear of popular apps and every shortcut can be re-recorded.
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private var handlers: [HotKeyAction: () -> Void] = [:]
    /// What a held action does when its key comes up (`peek`).
    private var releases: [HotKeyAction: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func setHandler(_ action: HotKeyAction, _ handler: @escaping () -> Void) { handlers[action] = handler }
    func setRelease(_ action: HotKeyAction, _ handler: @escaping () -> Void) { releases[action] = handler }

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

    fileprivate func fire(_ index: UInt32, released: Bool) {
        guard Int(index) < HotKeyAction.allCases.count else { return }
        let action = HotKeyAction.allCases[Int(index)]
        (released ? releases[action] : handlers[action])?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id, released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            Task { @MainActor in HotKeys.shared.fire(id, released: released) }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
