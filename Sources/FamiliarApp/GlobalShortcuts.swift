import AppKit
import Carbon
import FamiliarCore

/// A key with its modifiers, as Carbon's hot keys take it: chosen in Settings, stored in the defaults.
struct KeyCombo: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int   // Carbon: cmdKey, optionKey, controlKey, shiftKey

    static let optionSpace = KeyCombo(keyCode: kVK_Space, modifiers: optionKey)

    /// From a key press in the shortcut recorder.
    init(keyCode: Int, modifiers: Int) { self.keyCode = keyCode; self.modifiers = modifiers }
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        self.init(keyCode: Int(event.keyCode), modifiers: m)
    }

    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// For menus: the key and modifiers as AppKit shows them.
    var keyEquivalent: String {
        switch keyCode {
        case kVK_Space: return " "
        default: return Self.keyName(keyCode).count == 1 ? Self.keyName(keyCode).lowercased() : ""
        }
    }
    var modifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        return flags
    }

    /// Why this combination can't be a shortcut, or nil. One needs ⌘, ⌥ or ⌃ (or is a function key), so typing never
    /// sets it off; macOS's own are left alone.
    var problem: String? {
        if modifiers & (cmdKey | optionKey | controlKey) == 0 && !Self.functionKeys.contains(keyCode) {
            return "Use ⌘, ⌥ or ⌃ with the key."
        }
        let macOS: [KeyCombo: String] = [
            KeyCombo(keyCode: kVK_Space, modifiers: cmdKey): "Spotlight",
            KeyCombo(keyCode: kVK_Space, modifiers: cmdKey | optionKey): "Finder search",
            KeyCombo(keyCode: kVK_Space, modifiers: controlKey): "switching input sources",
            KeyCombo(keyCode: kVK_Space, modifiers: controlKey | cmdKey): "emoji",
            KeyCombo(keyCode: kVK_Tab, modifiers: cmdKey): "switching apps",
            KeyCombo(keyCode: kVK_ANSI_Q, modifiers: cmdKey): "quitting apps",
        ]
        if let what = macOS[self] { return "macOS uses \(display) for \(what)." }
        return nil
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    private static func keyName(_ code: Int) -> String {
        switch code {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case _ where functionKeys.contains(code): return "F\((functionKeys.firstIndex(of: code) ?? 0) + 1)"
        default:
            // The character the key types on this keyboard layout, unshifted.
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
            let layout = unsafeBitCast(data, to: CFData.self)
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
                UCKeyTranslate($0, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            }
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

extension KeyCombo: Hashable {}

/// The shortcuts that work from any app, through Carbon's hot keys (no accessibility permission needed): ⌥Space opens
/// the panel to search or ask (Tab switches), and recording a meeting has none unless one is chosen. Both can be
/// changed in Settings. Push to talk is a held key of its own (`Dictation`).
enum GlobalShortcut: UInt32, CaseIterable {
    case search = 1, record

    var label: String {
        switch self {
        case .search: return "Search or ask"
        case .record: return "Start or stop recording a meeting"
        }
    }

    var defaultCombo: KeyCombo? {
        switch self {
        case .search: return .optionSpace
        case .record: return nil
        }
    }

    private var defaultsKey: String { "shortcut.\(self)" }

    /// The chosen combination; nil when it has none.
    var combo: KeyCombo? {
        get {
            guard let data = SettingsStore.defaults.data(forKey: defaultsKey) else { return defaultCombo }
            return try? JSONDecoder().decode(KeyCombo?.self, from: data)
        }
        nonmutating set {
            SettingsStore.defaults.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
            GlobalShortcut.registerAll()
        }
    }

    var display: String { combo?.display ?? "None" }

    private static var actions: [GlobalShortcut: () -> Void] = [:]
    private static var references: [EventHotKeyRef] = []
    private static var handlerInstalled = false
    /// The shortcuts another app already holds, so they don't work here (Settings says so).
    private(set) static var taken: Set<GlobalShortcut> = []

    /// Sets the action for each shortcut and registers them.
    static func register(_ actions: [GlobalShortcut: () -> Void]) {
        self.actions = actions
        if !handlerInstalled {
            handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                let number = id.id
                DispatchQueue.main.async { GlobalShortcut(rawValue: number).flatMap { GlobalShortcut.actions[$0] }?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        registerAll()
    }

    /// Lets go of every shortcut (while Settings records a new one, so pressing it doesn't open the panel).
    static func unregisterAll() {
        references.forEach { UnregisterEventHotKey($0) }
        references = []
    }

    /// Registers the chosen combinations again. One that another app already holds is skipped and noted.
    static func registerAll() {
        unregisterAll()
        guard handlerInstalled else { return }
        taken = []
        for hotkey in allCases where actions[hotkey] != nil {
            guard let combo = hotkey.combo else { continue }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5346_4C53), id: hotkey.rawValue)   // "SFLS"
            let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), id, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references.append(reference) } else {
                taken.insert(hotkey)
                AppLog.write("shortcut \(combo.display) is taken by another app (\(status))")
            }
        }
    }

    /// The search shortcut, as shown in Settings' header and the panel.
    static var display: String { GlobalShortcut.search.display }
}
