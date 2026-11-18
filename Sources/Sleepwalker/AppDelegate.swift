import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var statusMenu: StatusMenuController?
    private var pendingURLs: [URL] = []
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController(preferences: .shared)
        self.controller = controller
        statusMenu = StatusMenuController(controller: controller)
        controller.start()
        handleTerminationSignal()

        pendingURLs.forEach(controller.handle(url:))
        pendingURLs.removeAll()

        if !controller.preferences.hasShownWelcome {
            perform(#selector(showWelcome), with: nil, afterDelay: 0.3)
        }
    }

    // sleepwalker://… permite manejar Sleepwalker desde Atajos, Raycast, scripts, etc. (ver README).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else {
            pendingURLs += urls
            return
        }
        urls.forEach(controller.handle(url:))
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
    }

    /// `pkill` (lo que hace `make install`) manda SIGTERM, que cierra la app sin pasar por `applicationWillTerminate`.
    /// Se convierte en un cierre normal para que alcance a restaurar la suspensión con la tapa cerrada.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }

    // Abrir la app cuando ya está corriendo (doble clic en Finder, Spotlight) muestra la configuración.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showSettings()
        return false
    }

    @objc private func showWelcome() {
        guard let controller else { return }
        let preferences = controller.preferences
        preferences.hasShownWelcome = true

        var lines = [
            "Clic en el ícono: activa o desactiva Sleepwalker. Mientras está activo, el Mac no se suspende.",
            "Clic derecho: duración, opciones de pantalla y configuración.",
            "",
        ]
        if let screen = controller.activeShortcut(for: .toggleScreen) {
            lines.append("\(screen.displayString) apaga la pantalla sin suspender el Mac. Vuelve a presionarlo para encenderla.")
        }
        if let awake = controller.activeShortcut(for: .toggleAwake) {
            lines.append("\(awake.displayString) activa o desactiva Sleepwalker.")
        }

        let alert = NSAlert()
        alert.messageText = "Sleepwalker está en la barra de menús"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Entendido")
        alert.addButton(withTitle: "Configuración…")
        NSApp.activateCompat()
        if alert.runModal() == .alertSecondButtonReturn {
            controller.showSettings()
        }
    }
}
