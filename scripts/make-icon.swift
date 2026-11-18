// Dibuja el ícono de Sleepwalker en todos los tamaños de un .iconset.
// Uso: swift scripts/make-icon.swift Resources/AppIcon.iconset  (o `make icon`, que además crea el .icns)
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: output)
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
}

/// Todo se dibuja en una cuadrícula de 1024 y se escala al tamaño pedido.
func drawIcon(in context: CGContext, side: CGFloat) {
    context.scaleBy(x: side / 1024, y: side / 1024)

    // Cuerpo con la retícula estándar de macOS: 824/1024 con margen para la sombra.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 184, cornerHeight: 184, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x000000, alpha: 0.4))
    context.addPath(bodyPath)
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()

    // Cielo nocturno.
    context.drawLinearGradient(gradient([color(0x4A3A9E), color(0x2A1F66), color(0x110D2B)], [0, 0.5, 1]),
                               start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    // Estrellas.
    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (180, 560, 5, 0.7), (230, 870, 4, 0.6), (420, 860, 6, 0.85), (520, 780, 4, 0.5), (600, 880, 5, 0.75),
        (870, 600, 5, 0.7), (850, 420, 4, 0.5), (760, 520, 3, 0.45), (160, 420, 3, 0.45), (470, 700, 3, 0.4),
        (890, 880, 4, 0.55), (300, 640, 3, 0.4),
    ]
    for (x, y, radius, alpha) in stars {
        context.setFillColor(color(0xFFFFFF, alpha: alpha))
        context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    // Luna creciente con un halo suave.
    let moon = CGPoint(x: 262, y: 790)
    context.drawRadialGradient(gradient([color(0xFFE7A0, alpha: 0.3), color(0xFFE7A0, alpha: 0)], [0, 1]),
                               startCenter: moon, startRadius: 0, endCenter: moon, endRadius: 230, options: [])
    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(color(0xFFE7A0))
    context.fillEllipse(in: CGRect(x: moon.x - 88, y: moon.y - 88, width: 176, height: 176))
    context.setBlendMode(.clear)
    context.fillEllipse(in: CGRect(x: moon.x - 42, y: moon.y - 30, width: 166, height: 166))
    context.endTransparencyLayer()
    context.restoreGState()

    // Sombra en el suelo bajo los pies.
    context.saveGState()
    context.setShadow(offset: .zero, blur: 30, color: color(0x05030F, alpha: 0.6))
    context.setFillColor(color(0x05030F, alpha: 0.45))
    context.fillEllipse(in: CGRect(x: 270, y: 172, width: 270, height: 40))
    context.restoreGState()

    // El sonámbulo: misma silueta que el ícono de la barra de menús (cuadrícula de 18 puntos), ampliada.
    let scale: CGFloat = 32
    let origin = CGPoint(x: 183, y: 148)
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0x0A0620, alpha: 0.55))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(color(0xFFFFFF))
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(50)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let head = point(7.6, 14.6)
    context.fillEllipse(in: CGRect(x: head.x - 64, y: head.y - 64, width: 128, height: 128))
    context.addLines(between: [point(7.1, 11.9), point(6.3, 7.0), point(8.9, 1.4)])
    context.addLines(between: [point(6.3, 7.0), point(5.1, 4.3), point(3.5, 1.6)])
    context.addLines(between: [point(7.0, 11.0), point(13.2, 11.0)])
    context.strokePath()
    context.endTransparencyLayer()
    context.restoreGState()

    // Las "z" que suben.
    context.setStrokeColor(color(0xD9CCFF))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for (center, size, width) in [(CGPoint(x: 565, y: 668), 46.0, 16.0), (CGPoint(x: 650, y: 740), 66.0, 20.0),
                                  (CGPoint(x: 752, y: 822), 86.0, 24.0)] as [(CGPoint, CGFloat, CGFloat)] {
        context.setLineWidth(width)
        context.addLines(between: [
            CGPoint(x: center.x - size / 2, y: center.y + size / 2), CGPoint(x: center.x + size / 2, y: center.y + size / 2),
            CGPoint(x: center.x - size / 2, y: center.y - size / 2), CGPoint(x: center.x + size / 2, y: center.y - size / 2),
        ])
        context.strokePath()
    }
    context.restoreGState()
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    drawIcon(in: context.cgContext, side: CGFloat(pixels))
    context.flushGraphics()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
}
print("Ícono generado en \(output)")
