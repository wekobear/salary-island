import SwiftUI

/// A continuously deformable, layered vector purse. No clock or salary state lives here.
struct SalaryWalletArtwork: View, Animatable {
    var progress: Double
    var compact = false
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 120, size.height / 100)
            context.translateBy(x: (size.width - 120 * scale) / 2, y: (size.height - 100 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let fullness = progress.isFinite ? min(1, max(0, progress)) : 0
            WalletDrawing(fullness: fullness, compact: compact).draw(in: context)
        }
    }
}

private struct WalletDrawing {
    let fullness: Double
    let compact: Bool
    private let pale = Color(red: 0.78, green: 0.98, blue: 0.77)
    private let mint = Color(red: 0.48, green: 0.78, blue: 0.58)
    private let shade = Color(red: 0.23, green: 0.51, blue: 0.38)
    private let goldLight = Color(red: 1, green: 0.92, blue: 0.69)
    private let gold = Color(red: 0.98, green: 0.78, blue: 0.40)
    private let goldShade = Color(red: 0.58, green: 0.36, blue: 0.14)
    private var top: CGFloat { 75 - 35 * fullness }

    func draw(in context: GraphicsContext) {
        // All shapes use the same 120x100 slot and y=93 ground baseline.
        if !compact {
            var shadow = context
            shadow.addFilter(.blur(radius: 3))
            shadow.fill(Path(ellipseIn: CGRect(x: 20, y: 89, width: 82, height: 7)), with: .color(.black.opacity(0.6)))
        }
        context.fill(cavity, with: .linearGradient(Gradient(colors: [shade, Color(red: 0.08, green: 0.24, blue: 0.17)]),
                                                   startPoint: CGPoint(x: 55, y: top - 26), endPoint: CGPoint(x: 60, y: top + 5)))
        context.stroke(arch, with: goldGradient, style: StrokeStyle(lineWidth: compact ? 5 : 4.4, lineCap: .round))
        if !compact {
            var highlight = context
            highlight.translateBy(x: 0, y: -0.7)
            highlight.stroke(arch, with: .color(goldLight.opacity(0.65)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }

        var coins = context
        coins.clip(to: cavity)
        if fullness > 0.015 {
            if compact {
                let level = top + 4 - 22 * fullness
                coins.fill(Path(roundedRect: CGRect(x: 36, y: level, width: 48, height: 30), cornerRadius: 8),
                           with: .linearGradient(Gradient(colors: [goldLight, gold]), startPoint: CGPoint(x: 40, y: level), endPoint: CGPoint(x: 75, y: level + 20)))
            } else {
                coinStack(in: &coins, x: 39, rise: 17 * fullness, width: 24, opacity: min(1, fullness * 5))
                coinStack(in: &coins, x: 68, rise: max(0, 27 * fullness - 4), width: 24, opacity: min(1, max(0, (fullness - 0.18) * 5)))
                coinStack(in: &coins, x: 54, rise: max(0, 31 * fullness - 10), width: 22, opacity: min(1, max(0, (fullness - 0.42) * 5)))
            }
        }

        context.fill(pouch, with: .linearGradient(Gradient(stops: [
            .init(color: pale, location: 0), .init(color: mint, location: 0.48), .init(color: shade, location: 1)
        ]), startPoint: CGPoint(x: 20, y: top - 12), endPoint: CGPoint(x: 94, y: 110)))
        if !compact {
            var soft = context
            soft.clip(to: pouch)
            soft.addFilter(.blur(radius: 5))
            soft.fill(Path(ellipseIn: CGRect(x: 19, y: top - 6, width: 78, height: 28 + 17 * fullness)),
                      with: .radialGradient(Gradient(colors: [pale.opacity(0.4), pale.opacity(0)]),
                                            center: CGPoint(x: 49, y: top + 7), startRadius: 1, endRadius: 46))
            let creaseOpacity = (1 - fullness) * 0.34
            soft.stroke(crease, with: .color(shade.opacity(creaseOpacity)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        context.stroke(lip, with: .linearGradient(Gradient(colors: [pale, mint]), startPoint: CGPoint(x: 25, y: top), endPoint: CGPoint(x: 95, y: top + 6)),
                       style: StrokeStyle(lineWidth: compact ? 3.0 : 3.7, lineCap: .round))
        clasp(in: context)
    }

    private var goldGradient: GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [.init(color: goldLight, location: 0), .init(color: gold, location: 0.5), .init(color: goldShade, location: 1)]),
                        startPoint: CGPoint(x: 36, y: top - 30), endPoint: CGPoint(x: 90, y: top + 4))
    }

    private var cavity: Path {
        Path { p in
            p.move(to: CGPoint(x: 25, y: top + 4))
            p.addCurve(to: CGPoint(x: 95, y: top + 4), control1: CGPoint(x: 25, y: top - 36), control2: CGPoint(x: 95, y: top - 36))
            p.addCurve(to: CGPoint(x: 25, y: top + 4), control1: CGPoint(x: 82, y: top + 14), control2: CGPoint(x: 38, y: top + 14))
            p.closeSubpath()
        }
    }

    private var arch: Path {
        Path { p in
            p.move(to: CGPoint(x: 25, y: top + 1))
            p.addCurve(to: CGPoint(x: 95, y: top + 1), control1: CGPoint(x: 25, y: top - 37), control2: CGPoint(x: 95, y: top - 37))
        }
    }

    private var pouch: Path {
        Path { p in
            p.move(to: CGPoint(x: 26, y: top))
            p.addCurve(to: CGPoint(x: 94, y: top), control1: CGPoint(x: 43, y: top + 7), control2: CGPoint(x: 77, y: top + 7))
            p.addCurve(to: CGPoint(x: 106, y: 79), control1: CGPoint(x: 96, y: top + 11), control2: CGPoint(x: 108, y: 69 + 7 * (1 - fullness)))
            p.addCurve(to: CGPoint(x: 88, y: 92), control1: CGPoint(x: 106, y: 89), control2: CGPoint(x: 99, y: 92))
            p.addCurve(to: CGPoint(x: 32, y: 92), control1: CGPoint(x: 72, y: 94), control2: CGPoint(x: 48, y: 94))
            p.addCurve(to: CGPoint(x: 14, y: 79), control1: CGPoint(x: 21, y: 92), control2: CGPoint(x: 14, y: 89))
            p.addCurve(to: CGPoint(x: 26, y: top), control1: CGPoint(x: 12, y: 69 + 7 * (1 - fullness)), control2: CGPoint(x: 24, y: top + 11))
            p.closeSubpath()
        }
    }

    private var lip: Path {
        Path { p in
            p.move(to: CGPoint(x: 26, y: top))
            p.addCurve(to: CGPoint(x: 94, y: top), control1: CGPoint(x: 43, y: top + 7), control2: CGPoint(x: 77, y: top + 7))
        }
    }

    private var crease: Path {
        Path { p in
            p.move(to: CGPoint(x: 22, y: 84))
            p.addCurve(to: CGPoint(x: 98, y: 84), control1: CGPoint(x: 42, y: 90), control2: CGPoint(x: 78, y: 90))
        }
    }

    private func coinStack(in context: inout GraphicsContext, x: CGFloat, rise: Double, width: CGFloat, opacity: Double) {
        guard opacity > 0 else { return }
        var layer = context
        layer.opacity = opacity
        let y = top + 3 - rise
        let rect = CGRect(x: x - width / 2, y: y, width: width, height: 22)
        layer.fill(Path(roundedRect: rect, cornerRadius: 3), with: .linearGradient(Gradient(colors: [gold, goldShade, gold]),
                     startPoint: CGPoint(x: rect.minX, y: y), endPoint: CGPoint(x: rect.maxX, y: y + 5)))
        for row in 1...4 {
            let yy = y + CGFloat(row) * 4
            layer.stroke(Path(ellipseIn: CGRect(x: rect.minX, y: yy, width: width, height: 6)), with: .color(goldLight.opacity(0.65)), lineWidth: 0.8)
        }
        let face = Path(ellipseIn: CGRect(x: rect.minX, y: y - 3, width: width, height: 8))
        layer.fill(face, with: .linearGradient(Gradient(colors: [goldLight, gold]), startPoint: CGPoint(x: x, y: y - 3), endPoint: CGPoint(x: x, y: y + 5)))
        layer.stroke(face, with: .color(goldLight.opacity(0.75)), lineWidth: 0.9)
    }

    private func clasp(in context: GraphicsContext) {
        let y = top - 27
        var stems = Path()
        stems.move(to: CGPoint(x: 55, y: y + 1)); stems.addLine(to: CGPoint(x: 57, y: y - 6))
        stems.move(to: CGPoint(x: 65, y: y + 1)); stems.addLine(to: CGPoint(x: 63, y: y - 6))
        context.stroke(stems, with: goldGradient, style: StrokeStyle(lineWidth: compact ? 3.8 : 3.2, lineCap: .round))
        for x: CGFloat in [55, 65] {
            let bead = Path(ellipseIn: CGRect(x: x - 4.5, y: y - 11, width: 9, height: 9))
            context.fill(bead, with: .radialGradient(Gradient(colors: [goldLight, gold, goldShade]),
                           center: CGPoint(x: x - 1.5, y: y - 9), startRadius: 0, endRadius: 8))
        }
    }
}

#Preview {
    HStack(alignment: .bottom, spacing: 10) {
        ForEach(0..<5) { n in
            VStack {
                SalaryWalletArtwork(progress: Double(n) / 4).frame(width: 120, height: 100)
                SalaryWalletArtwork(progress: Double(n) / 4, compact: true).frame(width: 22, height: 22)
            }
        }
    }.padding().background(.black)
}
