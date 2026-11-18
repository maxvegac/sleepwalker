import AppKit
import SwiftUI

/// Aviso que aparece si la pantalla se enciende estando en modo apagado.
@MainActor
final class ScreenOffHUD {
    private let model = HUDModel()
    private var panel: NSPanel?

    func show(secondsLeft: Int, shortcut: String?) {
        model.secondsLeft = max(secondsLeft, 0)
        model.shortcut = shortcut
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        center(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let content = NSHostingView(rootView: HUDView(model: model))
        let size = content.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedRectMask(radius: 22)
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        panel.contentView = background
        return panel
    }

    private func center(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var secondsLeft = 0
    @Published var shortcut: String?
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 7) {
                Text("La pantalla está en modo apagado")
                    .font(.system(size: 15, weight: .semibold))
                if let shortcut = model.shortcut {
                    HStack(spacing: 6) {
                        Text("Presiona")
                        KeyCap(text: shortcut)
                        Text("para encenderla")
                    }
                } else {
                    Text("Enciéndela desde el menú de Sleepwalker")
                }
                Text("Se apagará de nuevo en \(model.secondsLeft) s")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 420, alignment: .leading)
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.28)))
    }
}

private extension NSImage {
    /// Máscara estirable para redondear las esquinas de un `NSVisualEffectView`.
    static func roundedRectMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
