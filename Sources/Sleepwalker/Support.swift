import AppKit
import os
import ServiceManagement

let logger = Logger(subsystem: "com.maxvegac.sleepwalker", category: "Sleepwalker")

enum Format {
    /// "Indefinidamente", "15 minutos", "1 hora", "4 horas".
    static func duration(minutes: Int) -> String {
        switch minutes {
        case 0: return "Indefinidamente"
        case 1: return "1 minuto"
        case 60: return "1 hora"
        case let m where m % 60 == 0: return "\(m / 60) horas"
        default: return "\(minutes) minutos"
        }
    }

    /// Versión corta para frases: "10 min", "1 h".
    static func shortDuration(minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min"
    }

    /// Tiempo restante: "1 h 05 min", "12 min", "40 s".
    static func remaining(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval.rounded(.up)), 0)
        guard seconds >= 60 else { return "\(seconds) s" }
        let minutes = (seconds + 59) / 60
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(String(format: "%02d", rest)) min"
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

extension NSApplication {
    /// Trae Sleepwalker al frente (es una app de barra de menús, así que no lo está nunca).
    func activateCompat() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
