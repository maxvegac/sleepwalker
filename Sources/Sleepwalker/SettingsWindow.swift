import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let controller: AppController
    private var window: NSWindow?

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activateCompat()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(controller: controller, preferences: controller.preferences))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Configuración de Sleepwalker"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section {
                ShortcutRow(title: "Activar o desactivar Sleepwalker",
                            shortcut: $preferences.toggleAwakeShortcut,
                            defaultShortcut: .toggleAwakeDefault,
                            failed: controller.failedShortcuts.contains(.toggleAwake))
                ShortcutRow(title: "Apagar o encender la pantalla",
                            shortcut: $preferences.toggleScreenShortcut,
                            defaultShortcut: .toggleScreenDefault,
                            failed: controller.failedShortcuts.contains(.toggleScreen))
            } header: {
                Text("Atajos de teclado")
            } footer: {
                Text("Funcionan desde cualquier app. Haz clic en un atajo y presiona la combinación nueva (con al menos dos de ⌃ ⌥ ⌘). ⌫ lo elimina y Esc cancela.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Pantalla") {
                Picker("Mientras Sleepwalker está activo", selection: $preferences.displayPolicy) {
                    Text("Seguir la configuración del sistema").tag(DisplayPolicy.system)
                    Text("Mantenerla siempre encendida").tag(DisplayPolicy.keepOn)
                    Text("Apagarla tras un tiempo sin uso").tag(DisplayPolicy.autoOff)
                }
                Picker("Apagarla tras", selection: $preferences.autoOffMinutes) {
                    ForEach(Preferences.autoOffChoices, id: \.self) { minutes in
                        Text("\(Format.shortDuration(minutes: minutes)) de inactividad").tag(minutes)
                    }
                }
                .disabled(preferences.displayPolicy != .autoOff)
                Toggle(isOn: $preferences.wakeOnlyWithShortcut) {
                    Text("Solo el atajo vuelve a encenderla")
                    Text("Si la pantalla se enciende sola o por un roce del mouse, Sleepwalker la vuelve a apagar. Desbloquear el Mac también la enciende.")
                }
                Picker("Volver a apagarla tras", selection: $preferences.resleepSeconds) {
                    ForEach(Preferences.resleepChoices, id: \.self) { seconds in
                        Text("\(seconds) s sin actividad").tag(seconds)
                    }
                }
                .disabled(!preferences.wakeOnlyWithShortcut)
            }

            Section("General") {
                if ClosedLidGuard.hasLid {
                    Toggle(isOn: Binding(
                        get: { controller.keepsAwakeWithLidClosed },
                        set: { controller.setKeepAwakeWithLidClosed($0) }
                    )) {
                        Text("Seguir despierto con la tapa cerrada")
                        Text("Mientras Sleepwalker está activo y el cargador está conectado. Si lo desconectas con la tapa cerrada, el Mac se suspende. La primera vez pide la contraseña de un administrador.")
                    }
                }
                Toggle("Abrir Sleepwalker al iniciar sesión", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                Toggle("Activar al abrir Sleepwalker", isOn: $preferences.activateOnLaunch)
                Picker("Duración al activar con un clic", selection: $preferences.defaultDurationMinutes) {
                    ForEach(Preferences.durationChoices, id: \.self) { minutes in
                        Text(Format.duration(minutes: minutes)).tag(minutes)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: Shortcut?
    let defaultShortcut: Shortcut
    let failed: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                ShortcutRecorder(shortcut: $shortcut)
                    .frame(width: 150)
                Button {
                    shortcut = defaultShortcut
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Restablecer \(defaultShortcut.displayString)")
                .disabled(shortcut == defaultShortcut)
            }
        } label: {
            Text(title)
            if failed {
                Text("macOS no aceptó este atajo; elige otro.")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton()
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onChange = { shortcut = $0 }
    }
}

/// Botón que, al hacerle clic, graba la siguiente combinación de teclas.
final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut? {
        didSet { updateTitle() }
    }
    var onChange: ((Shortcut?) -> Void)?

    private var isRecording = false
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var hint: String?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.pushOnPushOff)
        target = self
        action = #selector(clicked)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        finishRecording(with: nil, changed: false)
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        finishRecording(with: nil, changed: false)
        let center = NotificationCenter.default
        if let window { center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window) }
        if let newWindow {
            center.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: newWindow)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // Cerrar la ventana o cambiar de app cancela la grabación; si no, los atajos quedarían suspendidos.
    @objc private func windowDidResignKey(_ notification: Notification) {
        finishRecording(with: nil, changed: false)
    }

    @objc private func clicked() {
        if isRecording {
            finishRecording(with: nil, changed: false)
        } else {
            isRecording = true
            heldModifiers = []
            hint = nil
            HotKeyCenter.shared.suspend()
            window?.makeFirstResponder(self)
            updateTitle()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        heldModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        updateTitle()
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let keyCode = Int(event.keyCode)
        if modifiers.isEmpty, keyCode == kVK_Escape {
            finishRecording(with: nil, changed: false)
        } else if modifiers.isEmpty, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            finishRecording(with: nil, changed: true)
        } else {
            let candidate = Shortcut(event: event)
            if candidate.isUsableGlobally {
                finishRecording(with: candidate, changed: true)
            } else {
                hint = "Usa dos de ⌃⌥⌘"
                NSSound.beep()
                updateTitle()
            }
        }
    }

    private func finishRecording(with newShortcut: Shortcut?, changed: Bool) {
        guard isRecording else { return }
        isRecording = false
        // Primero se reactivan los atajos actuales; luego el cambio los vuelve a registrar con el nuevo.
        HotKeyCenter.shared.resume()
        if changed {
            shortcut = newShortcut
            onChange?(newShortcut)
        }
        updateTitle()
    }

    private func updateTitle() {
        state = isRecording ? .on : .off
        if isRecording {
            title = hint ?? (heldModifiers.isEmpty ? "Presiona el atajo…" : Shortcut.symbols(for: heldModifiers) + "…")
        } else {
            title = shortcut?.displayString ?? "Sin atajo"
        }
    }
}
