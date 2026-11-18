import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// Seguir despierto con la tapa cerrada. Cerrar la tapa suspende el Mac aunque haya aserciones de energía (las de
/// Sleepwalker, Caffeine o `caffeinate`); lo único que lo evita es `pmset disablesleep 1`, y eso solo lo puede hacer root.
/// Por eso Sleepwalker instala una vez, con la contraseña de un administrador, una regla de sudo que permite
/// exactamente `pmset -a disablesleep 0` y `pmset -a disablesleep 1`, y nada más.
@MainActor
final class ClosedLidGuard {
    static let sudoersPath = "/private/etc/sudoers.d/sleepwalker"
    private static let disableSleepCommand = ["/usr/bin/pmset", "-a", "disablesleep"]
    private static let ownedKey = "sleepDisabledBySleepwalker"

    enum AuthorizationResult {
        case authorized, cancelled, failed(String)
    }

    /// Se llama al conectar o desconectar el cargador.
    var onPowerSourceChange: (() -> Void)?

    private var powerSourceNotification: CFRunLoopSource?
    /// sudo rechazó el comando: no se reintenta hasta volver a dar el permiso.
    private var sudoFailed = false

    /// Este Mac tiene tapa.
    static var hasLid: Bool { rootDomainProperty(kAppleClamshellStateKey) != nil }
    static var isLidClosed: Bool { rootDomainProperty(kAppleClamshellStateKey) as? Bool ?? false }
    /// `pmset disablesleep` está activo, lo haya puesto Sleepwalker o alguien más.
    static var isSleepDisabled: Bool { rootDomainProperty("SleepDisabled") as? Bool ?? false }

    static var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return type as String == kIOPMACPowerKey
    }

    /// La regla de sudo ya está instalada.
    var isAuthorized: Bool { FileManager.default.fileExists(atPath: Self.sudoersPath) }

    /// Sleepwalker desactivó la suspensión y le toca restaurarla. Se guarda en disco por si la app termina de golpe:
    /// al volver a abrirse la restaura.
    private var ownsSleepDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.ownedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.ownedKey) }
    }

    func startMonitoringPower() {
        guard powerSourceNotification == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<ClosedLidGuard>.fromOpaque(context).takeUnretainedValue().onPowerSourceChange?()
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceNotification = source
    }

    /// Desactiva la suspensión si se pide, hay permiso y el cargador está conectado; si no, la restaura.
    /// `sleepIfLidClosed`: al restaurarla con la tapa cerrada, suspende el Mac (si no, seguiría despierto en la mochila).
    func update(wanted: Bool, sleepIfLidClosed: Bool = true) {
        if wanted, isAuthorized, !sudoFailed, Self.isOnACPower {
            guard !Self.isSleepDisabled else { return }  // ya está, por Sleepwalker o por alguien más
            if setSleepDisabled(true) {
                ownsSleepDisabled = true
            } else {
                sudoFailed = true
            }
        } else if ownsSleepDisabled {
            if Self.isSleepDisabled {
                guard setSleepDisabled(false) else { return }  // se reintenta en la próxima actualización
                // macOS no vuelve a evaluar la tapa al permitir la suspensión: hay que pedirla.
                if sleepIfLidClosed, Self.isLidClosed { Self.run("/usr/bin/pmset", ["sleepnow"]) }
            }
            ownsSleepDisabled = false
        }
    }

    /// Pide la contraseña de un administrador e instala la regla de sudo.
    func authorize() -> AuthorizationResult {
        let command = Self.disableSleepCommand.joined(separator: " ")
        let lines = [
            "# Sleepwalker: permite mantener el Mac despierto con la tapa cerrada (https://github.com/maxvegac/sleepwalker)",
            "#\(getuid()) ALL = (root) NOPASSWD: \(command) 0, \(command) 1",
        ]
        // Se escribe al lado con un nombre que sudo ignora (lleva punto) y solo se activa si visudo la da por buena:
        // un archivo de sudoers con errores dejaría sudo inutilizable.
        let draft = "/private/etc/sudoers.d/.sleepwalker.tmp"
        let script = "printf '%s\\n' \(lines.map { "'\($0)'" }.joined(separator: " ")) > \(draft)"
            + " && /usr/sbin/chown root:wheel \(draft) && /bin/chmod 0440 \(draft)"
            + " && /usr/sbin/visudo -cqf \(draft) && /bin/mv -f \(draft) \(Self.sudoersPath)"
            + "; status=$?; /bin/rm -f \(draft); exit $status"
        let prompt = "Sleepwalker necesita permiso para que el Mac siga despierto con la tapa cerrada."
        let source = "do shell script \(Self.appleScriptString(script)) with prompt \(Self.appleScriptString(prompt))"
            + " with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -128 { return .cancelled }
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "Error desconocido.")
        }
        logger.notice("Tapa cerrada: permiso instalado")
        sudoFailed = false
        // Comprueba que sudo acepta la regla, sin cambiar nada.
        guard Self.run("/usr/bin/sudo", ["-n", "-l"] + Self.disableSleepCommand + ["1"]) else {
            return .failed("macOS no aceptó la regla instalada en \(Self.sudoersPath).")
        }
        return .authorized
    }

    private func setSleepDisabled(_ disabled: Bool) -> Bool {
        let succeeded = Self.run("/usr/bin/sudo", ["-n"] + Self.disableSleepCommand + [disabled ? "1" : "0"])
        if succeeded {
            logger.notice("Tapa cerrada: suspensión \(disabled ? "desactivada" : "restaurada", privacy: .public)")
        }
        return succeeded
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            logger.error("No se pudo ejecutar \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            logger.error("\(([path] + arguments).joined(separator: " "), privacy: .public) falló: \(message, privacy: .public)")
            return false
        }
        return true
    }

    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func rootDomainProperty(_ key: String) -> Any? {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return nil }
        defer { IOObjectRelease(rootDomain) }
        return IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
