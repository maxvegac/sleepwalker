import AppKit
import IOKit.pwr_mgt

/// Una aserción de energía de IOKit: lo mismo que usa `caffeinate`, sin procesos extra ni permisos especiales.
final class PowerAssertion {
    private let type: CFString
    private let name: CFString
    private var assertionID: IOPMAssertionID = 0

    init(type: String, name: String) {
        self.type = type as CFString
        self.name = name as CFString
    }

    deinit {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }

    var isHeld: Bool {
        get { assertionID != 0 }
        set { newValue ? acquire() : release() }
    }

    private func acquire() {
        guard assertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)
        if result == kIOReturnSuccess {
            assertionID = id
        } else {
            logger.error("No se pudo crear la aserción \(self.type as String, privacy: .public): \(result)")
        }
    }

    private func release() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}

enum SystemActivity {
    private static let anyInputEvent = CGEventType(rawValue: ~0)!

    /// Segundos desde la última vez que alguien usó el teclado, el mouse o el trackpad.
    static var secondsSinceLastInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
    }

    /// Apps que ahora mismo impiden que la pantalla se apague sola (videos, presentaciones, llamadas…).
    static func displaySleepBlockers() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as NSDictionary? else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for (key, value) in byProcess {
            guard let pid = (key as? NSNumber)?.int32Value, pid != ownPID,
                  let assertions = value as? [[String: Any]] else { continue }
            let blocksDisplaySleep = assertions.contains { assertion in
                let type = assertion["AssertType"] as? String
                let level = (assertion["AssertLevel"] as? NSNumber)?.intValue ?? 0
                return level > 0 && (type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion")
            }
            if blocksDisplaySleep {
                let name = processName(pid)
                if !names.contains(name) { names.append(name) }
            }
        }
        return names.sorted()
    }

    private static func processName(_ pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name
        }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "PID \(pid)"
    }
}
