import AppKit

/// El ícono de la barra de menús: clic izquierdo activa o desactiva (como Caffeine), clic derecho abre el menú.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private weak var headerItem: NSMenuItem?
    private var headerTimer: Timer?

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        controller.onChange = { [weak self] in self?.updateButton() }
        updateButton()
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        button.image = controller.isActive ? StatusIcon.active : StatusIcon.inactive
        button.toolTip = "Sleepwalker · \(controller.statusDescription)\nClic: activar o desactivar · Clic derecho: menú"
        headerItem?.title = controller.statusDescription
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            controller.toggle()
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard controller.expiresAt != nil else { return }
        // Mantiene al día el tiempo restante mientras el menú está abierto.
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(updateHeader), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        headerTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        // Sin menú asignado, el siguiente clic izquierdo vuelve a activar o desactivar.
        statusItem.menu = nil
        headerTimer?.invalidate()
        headerTimer = nil
    }

    @objc private func updateHeader() {
        headerItem?.title = controller.statusDescription
    }

    // MARK: - Menú

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem(title: controller.statusDescription, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        headerItem = header
        menu.addItem(.separator())

        menu.addItem(actionItem(controller.isActive ? "Desactivar" : "Activar", #selector(toggleAwake),
                                shortcut: controller.activeShortcut(for: .toggleAwake)))
        let durations = NSMenu()
        for minutes in Preferences.durationChoices {
            let item = actionItem(Format.duration(minutes: minutes), #selector(activateForDuration(_:)))
            item.tag = minutes
            let duration = minutes > 0 ? TimeInterval(minutes * 60) : nil
            item.state = controller.isActive && controller.activeDuration == duration ? .on : .off
            durations.addItem(item)
        }
        menu.addItem(submenuItem("Activar durante", durations))

        menu.addItem(.separator())
        menu.addItem(actionItem(controller.isScreenOff ? "Encender pantalla" : "Apagar pantalla", #selector(toggleScreen),
                                shortcut: controller.activeShortcut(for: .toggleScreen)))
        menu.addItem(submenuItem("Pantalla mientras está activo", displayMenu()))

        menu.addItem(.separator())
        let login = actionItem("Abrir al iniciar sesión", #selector(toggleLaunchAtLogin))
        login.state = controller.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(actionItem("Configuración…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(actionItem("Salir de Sleepwalker", #selector(quit), key: "q"))
    }

    private func displayMenu() -> NSMenu {
        let preferences = controller.preferences
        let menu = NSMenu()
        menu.autoenablesItems = false

        for (title, policy) in [("Seguir la configuración del sistema", DisplayPolicy.system),
                                ("Mantenerla siempre encendida", DisplayPolicy.keepOn)] {
            let item = actionItem(title, #selector(selectDisplayPolicy(_:)))
            item.representedObject = policy.rawValue
            item.state = preferences.displayPolicy == policy ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for minutes in Preferences.autoOffChoices {
            let item = actionItem("Apagarla tras \(Format.shortDuration(minutes: minutes)) de inactividad", #selector(selectAutoOff(_:)))
            item.tag = minutes
            item.state = preferences.displayPolicy == .autoOff && preferences.autoOffMinutes == minutes ? .on : .off
            menu.addItem(item)
        }
        if preferences.displayPolicy == .autoOff, controller.isActive {
            let blockers = controller.autoOffBlockers
            if !blockers.isEmpty {
                let verb = blockers.count == 1 ? "la mantiene" : "la mantienen"
                let note = NSMenuItem(title: "En pausa: \(blockers.joined(separator: ", ")) \(verb) encendida",
                                      action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
        }

        menu.addItem(.separator())
        let onlyShortcut = actionItem("Solo el atajo vuelve a encenderla", #selector(toggleWakeOnlyWithShortcut))
        onlyShortcut.state = preferences.wakeOnlyWithShortcut ? .on : .off
        menu.addItem(onlyShortcut)
        return menu
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "", shortcut: Shortcut? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let shortcut, let equivalent = shortcut.menuKeyEquivalent {
            item.keyEquivalent = equivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        return item
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    // MARK: - Acciones

    @objc private func toggleAwake() {
        controller.toggle()
    }

    @objc private func activateForDuration(_ sender: NSMenuItem) {
        controller.activate(for: sender.tag > 0 ? TimeInterval(sender.tag * 60) : nil)
    }

    @objc private func toggleScreen() {
        if controller.isScreenOff {
            controller.turnScreenOn()
        } else {
            // Desde el menú la mano sigue en el mouse: se espera un poco más antes de apagar.
            controller.turnScreenOff(delay: 0.8)
        }
    }

    @objc private func selectDisplayPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = DisplayPolicy(rawValue: raw) else { return }
        controller.preferences.displayPolicy = policy
    }

    @objc private func selectAutoOff(_ sender: NSMenuItem) {
        controller.preferences.autoOffMinutes = sender.tag
        controller.preferences.displayPolicy = .autoOff
    }

    @objc private func toggleWakeOnlyWithShortcut() {
        controller.preferences.wakeOnlyWithShortcut.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        controller.setLaunchAtLogin(!controller.launchAtLogin)
    }

    @objc private func openSettings() {
        controller.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Un sonámbulo caminando con los brazos estirados: con "z" cuando Sleepwalker está activo, atenuado cuando no.
@MainActor
enum StatusIcon {
    static let active = make(active: true)
    static let inactive = make(active: false)

    private static func make(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Capa de transparencia: así las partes que se superponen no quedan más oscuras al atenuar.
            context.setAlpha(active ? 1 : 0.45)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.black.set()

            NSBezierPath(ovalIn: NSRect(x: 5.5, y: 12.5, width: 4.2, height: 4.2)).fill()
            let body = strokePath(width: 1.8)
            body.move(to: NSPoint(x: 7.1, y: 11.9))   // cuello
            body.line(to: NSPoint(x: 6.3, y: 7.0))    // cadera
            body.line(to: NSPoint(x: 8.9, y: 1.4))    // pie adelantado
            body.move(to: NSPoint(x: 6.3, y: 7.0))
            body.line(to: NSPoint(x: 5.1, y: 4.3))    // rodilla
            body.line(to: NSPoint(x: 3.5, y: 1.6))    // pie atrasado
            body.move(to: NSPoint(x: 7.0, y: 11.0))   // hombro
            body.line(to: NSPoint(x: 13.2, y: 11.0))  // brazos estirados
            body.stroke()

            if active {
                for (center, size) in [(NSPoint(x: 13.6, y: 15.0), 3.0), (NSPoint(x: 16.4, y: 16.3), 2.0)] {
                    let z = strokePath(width: size > 2.5 ? 1.2 : 1.0)
                    z.move(to: NSPoint(x: center.x - size / 2, y: center.y + size / 2))
                    z.line(to: NSPoint(x: center.x + size / 2, y: center.y + size / 2))
                    z.line(to: NSPoint(x: center.x - size / 2, y: center.y - size / 2))
                    z.line(to: NSPoint(x: center.x + size / 2, y: center.y - size / 2))
                    z.stroke()
                }
            }
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "Sleepwalker activo" : "Sleepwalker inactivo"
        return image
    }

    private static func strokePath(width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
}
