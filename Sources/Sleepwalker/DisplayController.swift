import AppKit
import IOKit.pwr_mgt

/// Apaga y enciende la pantalla sin suspender el Mac y, si así se pidió, vigila que siga apagada
/// hasta que se use el atajo (o se desbloquee el Mac).
@MainActor
final class DisplayController: NSObject {
    /// `true` desde que se pide apagar la pantalla (atajo, menú o apagado automático) hasta que se vuelve a encender.
    private(set) var isScreenOffMode = false

    var wakeOnlyWithShortcut = true
    var resleepDelay: TimeInterval = 10
    var shortcutHint: String?
    var onChange: (() -> Void)?

    private var displaysAsleep = false
    private var sessionLocked = false
    private var lastWake = Date.distantPast
    private var lastSleepRequest = Date.distantPast
    private var settleDeadline = Date.distantPast
    private var pendingSleep: Task<Void, Never>?
    private var watchdog: Timer?
    private let hud = ScreenOffHUD()

    override init() {
        super.init()
        displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(leaveScreenOffMode(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(leaveScreenOffMode(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock(_:)), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock(_:)), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    var isDisplayAsleep: Bool {
        displaysAsleep || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Qué significa el atajo de pantalla en este momento:
    /// - pantalla apagada (la propia tecla la está despertando): encenderla;
    /// - recién apagada pero se volvió a encender (un roce del trackpad): apagarla de nuevo;
    /// - con el aviso a la vista: dejarla encendida, que es lo que indica el aviso;
    /// - encendida normalmente: apagarla.
    var toggleShouldTurnScreenOn: Bool {
        if isDisplayAsleep || Date().timeIntervalSince(lastWake) < 0.5 { return true }
        return isScreenOffMode && !isSettling
    }

    /// Los primeros segundos después de pedir apagarla.
    private var isSettling: Bool { Date() < settleDeadline }

    func enterScreenOffMode(heldKey: UInt32?, delay: TimeInterval) {
        isScreenOffMode = true
        hud.hide()
        settleDeadline = Date().addingTimeInterval(5)
        pendingSleep?.cancel()
        pendingSleep = Task { [weak self] in
            // Si se apaga con las teclas del atajo aún apretadas, al soltarlas se volvería a encender.
            await Self.waitUntilKeysReleased(heldKey: heldKey)
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isScreenOffMode else { return }
            self.settleDeadline = Date().addingTimeInterval(5)
            self.requestDisplaySleep()
            self.startWatchdog()
        }
        logger.notice("Pantalla: modo apagado")
        onChange?()
    }

    func exitScreenOffMode(wake: Bool) {
        pendingSleep?.cancel()
        pendingSleep = nil
        stopWatchdog()
        hud.hide()
        if wake { Self.wakeDisplays() }
        guard isScreenOffMode else { return }
        isScreenOffMode = false
        logger.notice("Pantalla: encendida")
        onChange?()
    }

    // MARK: - Vigilancia

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(checkScreen), userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Cada medio segundo en modo apagado: si la pantalla se encendió sin el atajo, la vuelve a apagar.
    @objc private func checkScreen() {
        guard isScreenOffMode else {
            stopWatchdog()
            return
        }
        // Le damos a la pantalla un momento para terminar de apagarse.
        guard Date().timeIntervalSince(lastSleepRequest) > 1, !isDisplayAsleep else {
            hud.hide()
            return
        }

        let idle = SystemActivity.secondsSinceLastInput
        // Recién apagada, soltar las teclas o rozar el trackpad la vuelve a encender: eso no cuenta.
        if isSettling {
            if idle >= 0.5 { requestDisplaySleep() }
            return
        }
        guard wakeOnlyWithShortcut else {
            // Comportamiento normal de macOS: cualquier tecla o movimiento la enciende y ahí se queda.
            exitScreenOffMode(wake: false)
            return
        }
        // En la pantalla de bloqueo se da más margen para escribir la contraseña.
        let delay = sessionLocked ? max(resleepDelay, 30) : resleepDelay
        if idle >= delay {
            hud.hide()
            requestDisplaySleep()
        } else if !sessionLocked {
            hud.show(secondsLeft: Int((delay - idle).rounded(.up)), shortcut: shortcutHint)
        }
    }

    // MARK: - Notificaciones del sistema

    @objc private func screensDidSleep(_ notification: Notification) {
        displaysAsleep = true
        hud.hide()
    }

    @objc private func screensDidWake(_ notification: Notification) {
        displaysAsleep = false
        lastWake = Date()
        if isScreenOffMode { checkScreen() }
    }

    @objc private func screenDidLock(_ notification: Notification) {
        sessionLocked = true
        hud.hide()
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        sessionLocked = false
        // Desbloquear el Mac deja claro que se quiere usar la pantalla.
        exitScreenOffMode(wake: false)
    }

    /// El Mac se va a dormir de verdad (tapa cerrada, menú Apple) o se cambió de usuario.
    @objc private func leaveScreenOffMode(_ notification: Notification) {
        exitScreenOffMode(wake: false)
    }

    // MARK: - Encender y apagar

    private func requestDisplaySleep() {
        lastSleepRequest = Date()
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        do {
            try pmset.run()
        } catch {
            logger.error("pmset displaysleepnow falló: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Enciende la pantalla declarando actividad del usuario (lo mismo que `caffeinate -u`).
    static func wakeDisplays() {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity("Sleepwalker: encender pantalla" as CFString, kIOPMUserActiveLocal, &assertionID)
        guard result == kIOReturnSuccess else {
            logger.error("No se pudo encender la pantalla (error \(result))")
            return
        }
        let id = assertionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { IOPMAssertionRelease(id) }
    }

    private static func waitUntilKeysReleased(heldKey: UInt32?) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let modifiers = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            let keyHeld = heldKey.map { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) } ?? false
            if modifiers.isEmpty && !keyHeld { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
