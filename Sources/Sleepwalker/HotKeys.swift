import AppKit
import Carbon.HIToolbox

/// Combinación de teclas global, guardada con los códigos de Carbon que espera `RegisterEventHotKey`.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let toggleAwakeDefault = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey | cmdKey))
    static let toggleScreenDefault = Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | cmdKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// "⌃⌥⌘P"
    var displayString: String { Self.symbols(for: modifierFlags) + KeyNames.name(for: keyCode) }

    /// Para no robarle teclas al resto del sistema (⌘C, ⌥N para la ñ, ⌃C en la terminal…)
    /// se exigen al menos dos de ⌃ ⌥ ⌘, salvo en las teclas de función.
    var isUsableGlobally: Bool {
        let strongModifiers = modifierFlags.intersection([.control, .option, .command])
        return KeyNames.isFunctionKey(keyCode) || strongModifiers.rawValue.nonzeroBitCount >= 2
    }

    var menuKeyEquivalent: String? { KeyNames.menuKeyEquivalent(for: keyCode) }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }
}

enum KeyNames {
    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Espacio", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    private static let specialEquivalents: [Int: Int] = [
        kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Space: 0x20, kVK_Delete: 0x08, kVK_Escape: 0x1B,
        kVK_ForwardDelete: NSDeleteFunctionKey, kVK_LeftArrow: NSLeftArrowFunctionKey,
        kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
        kVK_DownArrow: NSDownArrowFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
    ]

    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys.contains(Int(keyCode))
    }

    static func name(for keyCode: UInt32) -> String {
        let code = Int(keyCode)
        if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
        if let name = specialNames[code] { return name }
        return character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// Lo que espera `NSMenuItem.keyEquivalent` para mostrar el atajo junto a una opción del menú.
    static func menuKeyEquivalent(for keyCode: UInt32) -> String? {
        let code = Int(keyCode)
        if let index = functionKeys.firstIndex(of: code) { return string(fromScalar: NSF1FunctionKey + index) }
        if let scalar = specialEquivalents[code] { return string(fromScalar: scalar) }
        return character(for: keyCode)?.lowercased()
    }

    /// El carácter que produce la tecla en la distribución de teclado actual, sin modificadores.
    private static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                  characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length)
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }

    private static func string(fromScalar value: Int) -> String? {
        UnicodeScalar(UInt32(value)).map { String(Character($0)) }
    }
}

private let hotKeySignature: OSType = 0x534C_574B // 'SLWK'

/// Atajos globales con `RegisterEventHotKey` de Carbon: funcionan desde cualquier app y,
/// a diferencia de un monitor de eventos, no piden permisos de Accesibilidad.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Entry {
        var shortcut: Shortcut
        var handler: () -> Void
        var ref: EventHotKeyRef?
    }

    private var entries: [UInt32: Entry] = [:]
    private var lastPress: [UInt32: Date] = [:]
    private var suspendCount = 0
    private var eventHandler: EventHandlerRef?

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, &eventHandler)
    }

    /// Registra (o reemplaza) el atajo `id`. `nil` lo elimina. Devuelve `false` si macOS no lo acepta.
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut?, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard let shortcut else { return true }
        var entry = Entry(shortcut: shortcut, handler: handler, ref: nil)
        if suspendCount == 0 {
            guard let ref = Self.registerWithSystem(id: id, shortcut: shortcut) else { return false }
            entry.ref = ref
        }
        entries[id] = entry
        return true
    }

    func unregister(id: UInt32) {
        if let ref = entries.removeValue(forKey: id)?.ref {
            UnregisterEventHotKey(ref)
        }
    }

    /// Mientras se graba un atajo nuevo hay que soltar los actuales; si no, se dispararían al presionarlos.
    func suspend() {
        suspendCount += 1
        guard suspendCount == 1 else { return }
        for id in entries.keys {
            if let ref = entries[id]?.ref { UnregisterEventHotKey(ref) }
            entries[id]?.ref = nil
        }
    }

    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        guard suspendCount == 0 else { return }
        for (id, entry) in entries {
            entries[id]?.ref = Self.registerWithSystem(id: id, shortcut: entry.shortcut)
        }
    }

    fileprivate func handlePress(id: UInt32) {
        let now = Date()
        defer { lastPress[id] = now }
        // Si se deja la tecla apretada pueden llegar repeticiones: solo cuenta la primera.
        if let last = lastPress[id], now.timeIntervalSince(last) < 0.35 { return }
        entries[id]?.handler()
    }

    private static func registerWithSystem(id: UInt32, shortcut: Shortcut) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            logger.error("No se pudo registrar \(shortcut.displayString, privacy: .public) (error \(status))")
            return nil
        }
        logger.notice("Atajo registrado: \(shortcut.displayString, privacy: .public)")
        return ref
    }
}

private func hotKeyEventHandler(_ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    // Carbon entrega los atajos en el hilo principal.
    MainActor.assumeIsolated { HotKeyCenter.shared.handlePress(id: id) }
    return noErr
}
