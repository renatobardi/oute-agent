import AppKit
import TrayCore

/// Desenha a sakura do `TrayCore` (#563). Na barra de menu ela sai sem cor (template, pintada pelo sistema), como
/// os símbolos do menu (#473). No ícone do app, que o macOS também mostra na notificação, ela sai com as cores do
/// logo no `studio.css` do agent-studio (tema claro).
enum SakuraIcon {
    /// `--sakura-petal`: `oklch(0.88 0.05 5)`, em sRGB.
    private static let petal = CGColor(srgbRed: 0.963, green: 0.794, blue: 0.827, alpha: 1)
    /// `--sakura-ink` no claro = `--foreground`: `oklch(0.147 0.004 49.25)`.
    private static let ink = CGColor(srgbRed: 0.047, green: 0.039, blue: 0.036, alpha: 1)
    /// Fundo e borda do ícone do app: `--sidebar` e `--border`.
    private static let ground = CGColor(srgbRed: 0.981, green: 0.981, blue: 0.978, alpha: 1)
    private static let edge = CGColor(srgbRed: 0.907, green: 0.898, blue: 0.893, alpha: 1)

    /// O ícone da barra de menu: só o traço, para o sistema pintar de preto ou branco.
    static let bar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect, petalFill: nil, ink: CGColor(gray: 0, alpha: 1))
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Grava o `.icns` do app. Roda sem tela: o `oute tray install` chama o binário com `--write-icon <arquivo>`.
    static func writeAppIcon(to url: URL) -> Bool {
        var entries: [IconFile.Entry] = []
        for size in IconFile.appSizes {
            guard let png = appIconPNG(pixels: size.pixels) else { return false }
            entries.append(IconFile.Entry(type: size.type, png: png))
        }
        do {
            try IconFile.icns(entries).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// A sakura como imagem de uma notificação: um PNG novo num arquivo temporário. O macOS move o arquivo anexado
    /// para a guarda dele, então cada notificação precisa do seu. `nil` = sem imagem; a notificação sai igual.
    static func notificationImage() -> URL? {
        guard let png = appIconPNG(pixels: 256) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oute-tray-sakura-\(UUID().uuidString).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// O ícone do app num quadrado de `pixels`: fundo claro de cantos redondos e a flor com a pétala rosa.
    private static func appIconPNG(pixels: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else { return nil }
        let side = CGFloat(pixels)
        // a grade do ícone do macOS: a forma ocupa 824 de 1024, com o resto de margem
        let plate = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.098, dy: side * 0.098)
        let radius = plate.width * 0.225
        context.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(ground)
        context.fillPath()
        context.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(edge)
        context.setLineWidth(max(1, side / 256))
        context.strokePath()
        draw(in: context, rect: plate.insetBy(dx: plate.width * 0.13, dy: plate.width * 0.13), petalFill: petal, ink: ink)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A flor dentro de `rect`, na ordem do SVG: pétalas, estames e pontos. `petalFill` nulo = pétala só no traço.
    private static func draw(in context: CGContext, rect: CGRect, petalFill: CGColor?, ink: CGColor) {
        guard let petalShape = path(Sakura.petalPath), let stamenShape = path(Sakura.stamenPath) else { return }
        context.saveGState()
        // a caixa do SVG (100 × 100, y para baixo) em `rect`
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / CGFloat(Sakura.box), y: -rect.height / CGFloat(Sakura.box))
        context.setStrokeColor(ink)
        context.setFillColor(petalFill ?? ink)
        context.setLineJoin(.round)
        context.setLineWidth(CGFloat(Sakura.petalStroke))
        for angle in Sakura.petalAngles {
            turned(context, by: angle) {
                context.addPath(petalShape)
                context.drawPath(using: petalFill == nil ? .stroke : .fillStroke)
            }
        }
        context.setLineCap(.round)
        context.setLineWidth(CGFloat(Sakura.stamenStroke))
        context.setFillColor(ink)
        for angle in Sakura.stamenAngles {
            turned(context, by: angle) {
                context.addPath(stamenShape)
                context.strokePath()
                context.fillEllipse(in: circle(Sakura.stamenDot, radius: Sakura.stamenDotRadius))
            }
        }
        context.fillEllipse(in: circle(Sakura.center, radius: Sakura.heartRadius))
        context.restoreGState()
    }

    /// Como o `rotate(graus 50 50)` do SVG: gira em volta do centro da caixa só durante `body`.
    private static func turned(_ context: CGContext, by degrees: Double, _ body: () -> Void) {
        context.saveGState()
        context.translateBy(x: CGFloat(Sakura.center.x), y: CGFloat(Sakura.center.y))
        context.rotate(by: CGFloat(degrees) * .pi / 180)
        context.translateBy(x: -CGFloat(Sakura.center.x), y: -CGFloat(Sakura.center.y))
        body()
        context.restoreGState()
    }

    private static func circle(_ center: Sakura.Point, radius: Double) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private static func path(_ text: String) -> CGPath? {
        guard let segments = Sakura.segments(text) else { return nil }
        let path = CGMutablePath()
        for segment in segments {
            switch segment {
            case .move(let point): path.move(to: cg(point))
            case .line(let point): path.addLine(to: cg(point))
            case .curve(let control1, let control2, let end): path.addCurve(to: cg(end), control1: cg(control1), control2: cg(control2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    private static func cg(_ point: Sakura.Point) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }
}
