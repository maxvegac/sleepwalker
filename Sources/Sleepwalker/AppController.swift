import AppKit
import IOKit.pwr_mgt

/// Estado central de Sleepwalker: mantener el Mac despierto, la política de pantalla y los atajos.
@MainActor
final class AppController: NSObject, ObservableObject {
    let preferences: Preferences
    let display = DisplayController()

    @Published private(set) var isActive = false
    @Published private(set) var expiresAt: Date?
    /// Duración elegida al activar; `nil` = indefinidamente.
    @Published private(set) var activeDuration: TimeInterval?
    @Published private(set) var failedShortcuts: Set<ShortcutAction> = []

    /// Avisa a la barra de menús de que algo visible cambió.
    var onChange: (() -> Void)?

    private let systemAssertion = PowerAssertion(type: kIOPMAssertPreventUserIdleSystemSleep as String,
                                                 name: "Sleepwalker mantiene el Mac despierto")
    private let displayAssertion = PowerAssertion(type: kIOPMAssertPreventUserIdleDisplaySleep as String,
                                                  name: "Sleepwalker mantiene la pantalla encendida")
    private var registeredShortcuts: [ShortcutAction: Shortcut?] = [:]
    private var expiryTimer: Timer?
    private var autoOffTimer: Timer?
    private lazy var settingsWindow = SettingsWindowController(controller: self)

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
    }

    func start() {
        preferences.onChange = { [weak self] in self?.preferencesChanged() }
        display.onChange = { [weak self] in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        registerShortcuts()
        if preferences.activateOnLaunch {
            activate(for: defaultDuration)
        } else {
            refresh()
        }
    }

    // MARK: - Mantener despierto

    var defaultDuration: TimeInterval? {
        preferences.defaultDurationMinutes > 0 ? TimeInterval(preferences.defaultDurationMinutes * 60) : nil
    }

    func activate(for duration: TimeInterval?) {
        isActive = true
        activeDuration = duration
        expiresAt = duration.map { Date().addingTimeInterval($0) }
        scheduleExpiry()
        logger.notice("Activado \(duration.map { "por \(Int($0)) s" } ?? "indefinidamente", privacy: .public)")
        refresh()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        activeDuration = nil
        expiresAt = nil
        scheduleExpiry()
        display.exitScreenOffMode(wake: false)
        logger.notice("Desactivado")
        refresh()
    }

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activate(for: defaultDuration)
        }
    }

    var statusDescription: String {
        guard isActive else { return "Inactivo: el Mac puede suspenderse" }
        guard let expiresAt else { return "Activo: el Mac no se suspenderá" }
        return "Activo: quedan \(Format.remaining(expiresAt.timeIntervalSinceNow))"
    }

    // MARK: - Pantalla

    var isScreenOff: Bool { display.isScreenOffMode }

    func toggleScreen(heldKey: UInt32? = nil) {
        if display.toggleShouldTurnScreenOn {
            turnScreenOn()
        } else {
            turnScreenOff(heldKey: heldKey)
        }
    }

    /// Apaga la pantalla dejando el Mac despierto (si Sleepwalker estaba inactivo, lo activa: esa es la gracia).
    func turnScreenOff(heldKey: UInt32? = nil, delay: TimeInterval = 0.4) {
        if !isActive { activate(for: nil) }
        display.enterScreenOffMode(heldKey: heldKey, delay: delay)
    }

    func turnScreenOn() {
        display.exitScreenOffMode(wake: true)
    }

    /// Apps que ahora mismo impiden el apagado automático (videos, presentaciones…).
    var autoOffBlockers: [String] { SystemActivity.displaySleepBlockers() }

    // MARK: - Atajos

    /// El atajo configurado, solo si macOS lo aceptó.
    func activeShortcut(for action: ShortcutAction) -> Shortcut? {
        failedShortcuts.contains(action) ? nil : preferences.shortcut(for: action)
    }

    private func registerShortcuts() {
        var failed = Set<ShortcutAction>()
        for action in ShortcutAction.allCases {
            let shortcut = preferences.shortcut(for: action)
            let registered = HotKeyCenter.shared.register(id: action.rawValue, shortcut: shortcut) { [weak self] in
                self?.perform(action)
            }
            if !registered { failed.insert(action) }
            registeredShortcuts.updateValue(shortcut, forKey: action)
        }
        failedShortcuts = failed
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .toggleAwake:
            toggle()
        case .toggleScreen:
            toggleScreen(heldKey: preferences.toggleScreenShortcut?.keyCode)
        }
    }

    private func preferencesChanged() {
        let wanted = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, preferences.shortcut(for: $0)) })
        if wanted != registeredShortcuts { registerShortcuts() }
        refresh()
    }

    // MARK: - Estado

    private func refresh() {
        let policy = preferences.displayPolicy
        systemAssertion.isHeld = isActive
        // Con apagado automático también se mantiene encendida: el momento de apagarla lo decide Sleepwalker, no macOS.
        displayAssertion.isHeld = isActive && !display.isScreenOffMode && (policy == .keepOn || policy == .autoOff)
        display.wakeOnlyWithShortcut = preferences.wakeOnlyWithShortcut
        display.resleepDelay = TimeInterval(preferences.resleepSeconds)
        display.shortcutHint = activeShortcut(for: .toggleScreen)?.displayString
        updateAutoOffTimer()
        onChange?()
    }

    private func updateAutoOffTimer() {
        let needed = isActive && preferences.displayPolicy == .autoOff
        if needed, autoOffTimer == nil {
            let timer = Timer(timeInterval: 10, target: self, selector: #selector(checkAutoOff), userInfo: nil, repeats: true)
            timer.tolerance = 2
            RunLoop.main.add(timer, forMode: .common)
            autoOffTimer = timer
        } else if !needed {
            autoOffTimer?.invalidate()
            autoOffTimer = nil
        }
    }

    @objc private func checkAutoOff() {
        guard isActive, preferences.displayPolicy == .autoOff, !display.isScreenOffMode else { return }
        let idle = SystemActivity.secondsSinceLastInput
        guard idle >= TimeInterval(preferences.autoOffMinutes * 60) else { return }
        // Un video o una llamada también impiden que macOS apague la pantalla: respetamos lo mismo.
        guard autoOffBlockers.isEmpty else { return }
        logger.notice("Apagado automático tras \(Int(idle)) s sin actividad")
        display.enterScreenOffMode(heldKey: nil, delay: 0)
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let expiresAt else { return }
        let timer = Timer(fireAt: expiresAt, interval: 0, target: self, selector: #selector(checkExpiry),
                          userInfo: nil, repeats: false)
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    @objc private func systemDidWake(_ notification: Notification) {
        checkExpiry()
    }

    @objc private func checkExpiry() {
        guard isActive, let expiresAt else { return }
        if expiresAt.timeIntervalSinceNow <= 0.5 {
            deactivate()
        } else {
            scheduleExpiry()
        }
    }

    // MARK: - Inicio de sesión, configuración y URLs

    var launchAtLogin: Bool { LoginItem.isEnabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        objectWillChange.send()
        do {
            try LoginItem.setEnabled(enabled)
            if enabled, LoginItem.needsApproval { LoginItem.openSystemSettings() }
        } catch {
            let alert = NSAlert()
            alert.messageText = enabled ? "No se pudo activar el inicio automático" : "No se pudo desactivar el inicio automático"
            alert.informativeText = error.localizedDescription
            NSApp.activateCompat()
            alert.runModal()
        }
        onChange?()
    }

    func showSettings() {
        settingsWindow.show()
    }

    /// sleepwalker://activate[?minutes=30|hours=2], deactivate, toggle, screen/off, screen/on, screen/toggle, settings
    func handle(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "sleepwalker" else { return }
        let command = ([components.host ?? ""] + components.path.split(separator: "/").map(String.init))
            .filter { !$0.isEmpty }
            .joined(separator: "/")
            .lowercased()
        let query = components.queryItems ?? []
        func number(_ name: String) -> Double {
            query.first { $0.name == name }?.value.flatMap(Double.init) ?? 0
        }

        logger.notice("URL: \(url.absoluteString, privacy: .public)")
        switch command {
        case "activate", "on":
            let seconds = number("hours") * 3600 + number("minutes") * 60 + number("seconds")
            activate(for: seconds > 0 ? seconds : nil)
        case "deactivate", "off":
            deactivate()
        case "toggle":
            toggle()
        case "screen/off":
            turnScreenOff(delay: 0.6)
        case "screen/on":
            turnScreenOn()
        case "screen", "screen/toggle":
            toggleScreen()
        case "settings", "preferences":
            showSettings()
        default:
            logger.error("Comando desconocido: \(command, privacy: .public)")
        }
    }
}
