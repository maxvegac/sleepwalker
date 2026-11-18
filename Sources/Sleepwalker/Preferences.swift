import Foundation

enum DisplayPolicy: String, CaseIterable {
    /// No se toca la pantalla: se apaga según la configuración de macOS.
    case system
    /// Como Caffeine clásico: la pantalla no se apaga sola.
    case keepOn
    /// Sleepwalker la apaga tras `autoOffMinutes` sin actividad, aunque macOS diga otra cosa.
    case autoOff
}

enum ShortcutAction: UInt32, CaseIterable {
    case toggleAwake = 1
    case toggleScreen = 2
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// Minutos; 0 = indefinidamente.
    static let durationChoices = [0, 15, 30, 60, 120, 240, 480]
    static let autoOffChoices = [2, 5, 10, 15, 30, 60]
    static let resleepChoices = [5, 10, 20, 30, 60]

    /// Se llama después de cualquier cambio.
    var onChange: (() -> Void)?

    @Published var activateOnLaunch: Bool { didSet { save(activateOnLaunch, for: .activateOnLaunch) } }
    @Published var defaultDurationMinutes: Int { didSet { save(defaultDurationMinutes, for: .defaultDurationMinutes) } }
    @Published var displayPolicy: DisplayPolicy { didSet { save(displayPolicy.rawValue, for: .displayPolicy) } }
    @Published var autoOffMinutes: Int { didSet { save(autoOffMinutes, for: .autoOffMinutes) } }
    @Published var wakeOnlyWithShortcut: Bool { didSet { save(wakeOnlyWithShortcut, for: .wakeOnlyWithShortcut) } }
    @Published var resleepSeconds: Int { didSet { save(resleepSeconds, for: .resleepSeconds) } }
    @Published var keepAwakeWithLidClosed: Bool { didSet { save(keepAwakeWithLidClosed, for: .keepAwakeWithLidClosed) } }
    @Published var toggleAwakeShortcut: Shortcut? { didSet { saveShortcut(toggleAwakeShortcut, for: .toggleAwakeShortcut) } }
    @Published var toggleScreenShortcut: Shortcut? { didSet { saveShortcut(toggleScreenShortcut, for: .toggleScreenShortcut) } }

    var hasShownWelcome: Bool {
        get { defaults.bool(forKey: Key.hasShownWelcome.rawValue) }
        set { defaults.set(newValue, forKey: Key.hasShownWelcome.rawValue) }
    }

    private let defaults: UserDefaults

    private enum Key: String {
        case activateOnLaunch, defaultDurationMinutes, displayPolicy, autoOffMinutes
        case wakeOnlyWithShortcut, resleepSeconds, keepAwakeWithLidClosed, toggleAwakeShortcut, toggleScreenShortcut
        case hasShownWelcome
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.activateOnLaunch.rawValue: true,
            Key.defaultDurationMinutes.rawValue: 0,
            Key.displayPolicy.rawValue: DisplayPolicy.system.rawValue,
            Key.autoOffMinutes.rawValue: 10,
            Key.wakeOnlyWithShortcut.rawValue: true,
            Key.resleepSeconds.rawValue: 10,
            Key.keepAwakeWithLidClosed.rawValue: false,
        ])
        activateOnLaunch = defaults.bool(forKey: Key.activateOnLaunch.rawValue)
        defaultDurationMinutes = defaults.integer(forKey: Key.defaultDurationMinutes.rawValue)
        displayPolicy = DisplayPolicy(rawValue: defaults.string(forKey: Key.displayPolicy.rawValue) ?? "") ?? .system
        autoOffMinutes = max(defaults.integer(forKey: Key.autoOffMinutes.rawValue), 1)
        wakeOnlyWithShortcut = defaults.bool(forKey: Key.wakeOnlyWithShortcut.rawValue)
        resleepSeconds = max(defaults.integer(forKey: Key.resleepSeconds.rawValue), 2)
        keepAwakeWithLidClosed = defaults.bool(forKey: Key.keepAwakeWithLidClosed.rawValue)
        toggleAwakeShortcut = Self.loadShortcut(defaults, key: .toggleAwakeShortcut, fallback: .toggleAwakeDefault)
        toggleScreenShortcut = Self.loadShortcut(defaults, key: .toggleScreenShortcut, fallback: .toggleScreenDefault)
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        switch action {
        case .toggleAwake: return toggleAwakeShortcut
        case .toggleScreen: return toggleScreenShortcut
        }
    }

    private func save(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        onChange?()
    }

    // "Sin atajo" se guarda como datos vacíos para distinguirlo de "nunca configurado" (que usa el de fábrica).
    private func saveShortcut(_ shortcut: Shortcut?, for key: Key) {
        save(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), for: key)
    }

    private static func loadShortcut(_ defaults: UserDefaults, key: Key, fallback: Shortcut) -> Shortcut? {
        guard let data = defaults.data(forKey: key.rawValue) else { return fallback }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
}
