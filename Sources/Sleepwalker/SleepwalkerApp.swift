import AppKit

@main
enum SleepwalkerApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Sin ícono en el Dock: Sleepwalker vive en la barra de menús (Info.plist también lo declara).
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
