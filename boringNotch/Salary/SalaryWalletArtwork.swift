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
            let fullness = progress.isFinite ? min(1, max(0, progress)) : 0
            if compact {
                let scale = min(size.width / 24, size.height / 24)
                var local = context
                local.translateBy(x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
                local.scaleBy(x: scale, y: scale)
                CompactWalletDrawing(fullness: fullness).draw(in: local)
            } else {
                let scale = min(size.width / 120, size.height / 100)
                var local = context
                local.translateBy(x: (size.width - 120 * scale) / 2, y: (size.height - 100 * scale) / 2)
                local.scaleBy(x: scale, y: scale)
                ExpandedWalletDrawing(fullness: fullness).draw(in: local)
            }
        }
    }
}

// MARK: - Palette

private enum WalletColors {
    // Velvety matte soft-silicone mints matched to Approved B
    static let mintSpecular = Color(red: 0.84, green: 0.97, blue: 0.86)
    static let mintHighlight = Color(red: 0.67, green: 0.90, blue: 0.74)
    static let mintLight = Color(red: 0.53, green: 0.82, blue: 0.64)
    static let mintMid = Color(red: 0.40, green: 0.72, blue: 0.53)
    static let mintDeep = Color(red: 0.25, green: 0.53, blue: 0.37)
    static let mintShadow = Color(red: 0.15, green: 0.37, blue: 0.25)
    static let mintAmbient = Color(red: 0.09, green: 0.25, blue: 0.17)

    // Recessed mouth cavity greens
    static let cavityTop = Color(red: 0.10, green: 0.24, blue: 0.17)
    static let cavityWall = Color(red: 0.27, green: 0.53, blue: 0.38)
    static let cavityGlow = Color(red: 0.36, green: 0.64, blue: 0.47)
    static let cavityDeep = Color(red: 0.06, green: 0.16, blue: 0.11)

    // Warm 3D golds for clasp and coins
    static let goldSpecular = Color(red: 1.00, green: 0.96, blue: 0.80)
    static let goldLight = Color(red: 0.98, green: 0.86, blue: 0.55)
    static let goldMid = Color(red: 0.91, green: 0.72, blue: 0.36)
    static let goldRich = Color(red: 0.78, green: 0.56, blue: 0.22)
    static let goldShadow = Color(red: 0.55, green: 0.36, blue: 0.13)
    static let goldDark = Color(red: 0.38, green: 0.24, blue: 0.08)
}

// MARK: - Expanded / Preview Drawing (120x100 Normalized Space)

private struct ExpandedWalletDrawing {
    let fullness: Double

    // Smoothly eases out between 0% and 28% so empty folds melt into a smooth inflated bulb
    private var sag: Double {
        let raw = max(0, 1 - fullness / 0.28)
        return raw * raw * (3 - 2 * raw)
    }

    private var rise: Double {
        pow(fullness, 0.88)
    }

    private let bottomY: CGFloat = 92.5

    // Lip corners rise substantially as the silicone belly inflates into a tall round sphere
    private var lipCornerY: CGFloat {
        CGFloat(63.5 - 27.5 * rise)
    }

    // Deep U-shaped front collar dip at 0% that flattens gently as the belly fills
    private var lipDip: CGFloat {
        CGFloat(1.8 + 4.5 * pow(1 - fullness, 1.35) + 5.8 * sag)
    }

    private var lipCenterY: CGFloat {
        lipCornerY + lipDip
    }

    private var lipHalfW: CGFloat {
        CGFloat(36.0 + 1.5 * (1 - sag) - 1.3 * fullness)
    }

    private var archHalfW: CGFloat {
        lipHalfW + 1.6
    }

    // Exact Y coordinate of the gold arch centerline apex at x = 60
    private var archApexY: CGFloat {
        let archClearance = 24.0 - 5.6 * pow(fullness, 0.85)
        return lipCornerY - CGFloat(archClearance)
    }

    private var equatorY: CGFloat {
        CGFloat(77.5 - 12.0 * rise + 6.5 * sag)
    }

    private var bellyHalfW: CGFloat {
        CGFloat(47.6 + 3.4 * fullness + 3.0 * sag)
    }

    func draw(in context: GraphicsContext) {
        drawGroundShadow(in: context)
        drawCavity(in: context)
        drawCoins(in: context)
        drawSculptedClaspFrame(in: context)
        drawPouchBody(in: context)
        drawRolledLip(in: context)
        drawKissLockBeads(in: context)
    }

    // MARK: 1. Ground Shadow

    private func drawGroundShadow(in context: GraphicsContext) {
        let shadowHalfW = bellyHalfW * CGFloat(0.92 + 0.04 * sag)
        let outerRect = CGRect(x: 60 - shadowHalfW, y: bottomY - 3.6, width: shadowHalfW * 2, height: 8.6)
        context.fill(
            Path(ellipseIn: outerRect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0.60), location: 0.0),
                    .init(color: .black.opacity(0.32), location: 0.55),
                    .init(color: .black.opacity(0.0), location: 1.0)
                ]),
                center: CGPoint(x: 60, y: outerRect.midY),
                startRadius: 2,
                endRadius: shadowHalfW
            )
        )

        let coreHalfW = shadowHalfW * 0.70
        let coreRect = CGRect(x: 60 - coreHalfW, y: bottomY - 1.8, width: coreHalfW * 2, height: 4.5)
        context.fill(
            Path(ellipseIn: coreRect),
            with: .radialGradient(
                Gradient(colors: [.black.opacity(0.68), .black.opacity(0.0)]),
                center: CGPoint(x: 60, y: coreRect.midY),
                startRadius: 1,
                endRadius: coreHalfW
            )
        )
    }

    // MARK: 2. Recessed Mouth Cavity

    private var cavityPath: Path {
        let lx = 60 - archHalfW
        let rx = 60 + archHalfW
        let baseY = lipCornerY + 2.5
        let ctrlY = (archApexY - 0.25 * baseY) / 0.75
        return Path { p in
            p.move(to: CGPoint(x: lx, y: baseY))
            p.addCurve(
                to: CGPoint(x: rx, y: baseY),
                control1: CGPoint(x: lx + 1.5, y: ctrlY),
                control2: CGPoint(x: rx - 1.5, y: ctrlY)
            )
            p.addCurve(
                to: CGPoint(x: lx, y: baseY),
                control1: CGPoint(x: 60 + lipHalfW * 0.55, y: lipCenterY + 10),
                control2: CGPoint(x: 60 - lipHalfW * 0.55, y: lipCenterY + 10)
            )
            p.closeSubpath()
        }
    }

    private func drawCavity(in context: GraphicsContext) {
        var cav = context
        let path = cavityPath
        cav.clip(to: path)

        // Base deep interior gradient
        cav.fill(
            path,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.cavityTop, location: 0.0),
                    .init(color: WalletColors.cavityWall, location: 0.45),
                    .init(color: WalletColors.cavityDeep, location: 1.0)
                ]),
                startPoint: CGPoint(x: 60, y: archApexY),
                endPoint: CGPoint(x: 60, y: lipCenterY + 6)
            )
        )

        // Soft lit inner back wall dome
        let domeCenter = CGPoint(x: 58, y: archApexY + (lipCenterY - archApexY) * 0.48)
        cav.fill(
            Path(ellipseIn: CGRect(x: 24, y: archApexY + 1, width: 72, height: 34)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: WalletColors.cavityGlow.opacity(0.85), location: 0.0),
                    .init(color: WalletColors.cavityWall.opacity(0.42), location: 0.62),
                    .init(color: WalletColors.cavityTop.opacity(0.0), location: 1.0)
                ]),
                center: domeCenter,
                startRadius: 2,
                endRadius: 36
            )
        )

        // Empty-state inner bowl floor & soft step (visible at 0%..25%)
        let floorVisibility = max(0, 1 - fullness * 2.5)
        if floorVisibility > 0.01 {
            let floorY = lipCenterY - 5.2
            let floorRect = CGRect(x: 28, y: floorY - 5.5, width: 64, height: 15)
            cav.fill(
                Path(ellipseIn: floorRect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: WalletColors.cavityDeep.opacity(0.68 * floorVisibility), location: 0.0),
                        .init(color: WalletColors.cavityTop.opacity(0.35 * floorVisibility), location: 0.70),
                        .init(color: WalletColors.cavityTop.opacity(0.0), location: 1.0)
                    ]),
                    center: CGPoint(x: 60, y: floorY + 1.5),
                    startRadius: 2,
                    endRadius: 32
                )
            )

            var rimPath = Path()
            rimPath.move(to: CGPoint(x: 29, y: floorY - 2.2))
            rimPath.addCurve(
                to: CGPoint(x: 91, y: floorY - 2.2),
                control1: CGPoint(x: 45, y: floorY - 5.6),
                control2: CGPoint(x: 75, y: floorY - 5.6)
            )
            cav.stroke(
                rimPath,
                with: .color(WalletColors.mintLight.opacity(0.24 * floorVisibility)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
        }

        // Inner arch overhang shadow
        let innerShadowArch = archCurve(apexY: archApexY + 2.8, halfWidth: archHalfW - 0.8, baseY: lipCornerY + 2.5)
        cav.stroke(
            innerShadowArch,
            with: .color(WalletColors.cavityDeep.opacity(0.75)),
            style: StrokeStyle(lineWidth: 4.0, lineCap: .round)
        )
    }

    // MARK: 3. 3D Tilted Individual Coins

    private struct CoinSpec {
        let x: CGFloat
        let y: CGFloat
        let rx: CGFloat
        let ry: CGFloat
        let angleDegrees: Double
        let rimDX: CGFloat
        let rimDY: CGFloat
        let appearAt: Double
    }

    private func drawCoins(in context: GraphicsContext) {
        guard fullness > 0.015 else { return }

        var layer = context
        layer.clip(to: cavityPath)

        // Smooth fade-in only at the very start (0% -> 5%)
        let globalAlpha = min(1.0, max(0.0, (fullness - 0.015) / 0.05))
        layer.opacity = globalAlpha

        let t = CGFloat(fullness)
        // Anchor coin heights relative to the lip line so coins visibly rise out of the mouth
        let lipY = lipCenterY

        let coins: [CoinSpec] = [
            // 1. Back-left coin (tucked in left corner of arch at 45%..100%)
            CoinSpec(
                x: 40.5 - 2.0 * t,
                y: lipY + 12.0 - 20.8 * t,
                rx: 12.4,
                ry: 9.4,
                angleDegrees: 18.0,
                rimDX: -1.4,
                rimDY: 3.0,
                appearAt: 0.28
            ),
            // 2. Back-right coin (tucked in right corner of arch at 40%..100%)
            CoinSpec(
                x: 74.5 + 2.2 * t,
                y: lipY + 10.5 - 18.8 * t,
                rx: 12.8,
                ry: 9.8,
                angleDegrees: -18.0,
                rimDX: -1.6,
                rimDY: 3.0,
                appearAt: 0.25
            ),
            // 3. Far-right low coin edge (visible at 70%..100% tucked under right coin)
            CoinSpec(
                x: 80.5,
                y: lipY + 10.0 - 11.8 * t,
                rx: 11.5,
                ry: 7.5,
                angleDegrees: -10.0,
                rimDX: -1.2,
                rimDY: 3.2,
                appearAt: 0.55
            ),
            // 4. Center-back coin (bridges gap between left and right coins at 30%..80%)
            CoinSpec(
                x: 56.5,
                y: lipY + 7.5 - 14.5 * t,
                rx: 13.0,
                ry: 8.2,
                angleDegrees: 4.0,
                rimDX: -0.8,
                rimDY: 3.2,
                appearAt: 0.18
            ),
            // 5. Left-front coin (at 25%: low flat coin on left; at 50%..75%: rises and tilts nicely)
            CoinSpec(
                x: 43.0 - 2.2 * t,
                y: lipY + 1.4 - 9.0 * t,
                rx: 13.6,
                ry: 5.8 + 4.6 * t,
                angleDegrees: Double(-4.0 - 10.0 * t),
                rimDX: -1.2,
                rimDY: 3.4,
                appearAt: 0.02
            ),
            // 6. Right-front coin (at 25%..75%: prominent tilted right coin showing circular face)
            CoinSpec(
                x: 71.5 + 2.8 * t,
                y: lipY - 0.8 - 6.8 * t,
                rx: 13.8,
                ry: 10.2 + 0.8 * t,
                angleDegrees: -19.0,
                rimDX: -1.8,
                rimDY: 3.4,
                appearAt: 0.02
            ),
            // 7. Hero center-front coin (rises from pocket at 42%..100% to crown the 75% & 100% states)
            CoinSpec(
                x: 56.5,
                y: lipY + 14.5 - 24.8 * t,
                rx: 14.4,
                ry: 11.8,
                angleDegrees: -14.0,
                rimDX: -2.2,
                rimDY: 3.5,
                appearAt: 0.34
            )
        ]

        for spec in coins {
            let coinAlpha = min(1.0, max(0.0, (fullness - spec.appearAt) / 0.10))
            guard coinAlpha > 0.01 else { continue }
            drawSingleCoin(in: layer, spec: spec, alpha: coinAlpha)
        }
    }

    private func drawSingleCoin(in context: GraphicsContext, spec: CoinSpec, alpha: Double) {
        var coin = context
        coin.opacity *= alpha
        coin.translateBy(x: spec.x, y: spec.y)
        coin.rotate(by: .degrees(spec.angleDegrees))

        let rx = spec.rx
        let ry = spec.ry
        let faceRect = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)
        let rimRect = faceRect.offsetBy(dx: spec.rimDX, dy: spec.rimDY)

        // 1. Soft ambient drop shadow onto underlying coins / cavity
        let shadowRect = rimRect.offsetBy(dx: -0.6, dy: 1.8)
        coin.fill(Path(ellipseIn: shadowRect), with: .color(.black.opacity(0.32)))

        // 2. 3D cylindrical rim / edge (convex hull of face ellipse and offset rim ellipse)
        let rimDepth = hypot(spec.rimDX, spec.rimDY)
        let rimAngle = atan2(spec.rimDY, spec.rimDX) - .pi / 2
        var rimCtx = coin
        rimCtx.rotate(by: .radians(Double(rimAngle)))

        var sideWall = Path()
        sideWall.move(to: CGPoint(x: -rx, y: 0))
        sideWall.addLine(to: CGPoint(x: -rx, y: rimDepth))
        sideWall.addCurve(
            to: CGPoint(x: 0, y: ry + rimDepth),
            control1: CGPoint(x: -rx, y: ry * 0.55 + rimDepth),
            control2: CGPoint(x: -rx * 0.55, y: ry + rimDepth)
        )
        sideWall.addCurve(
            to: CGPoint(x: rx, y: rimDepth),
            control1: CGPoint(x: rx * 0.55, y: ry + rimDepth),
            control2: CGPoint(x: rx, y: ry * 0.55 + rimDepth)
        )
        sideWall.addLine(to: CGPoint(x: rx, y: 0))
        sideWall.closeSubpath()

        rimCtx.fill(
            sideWall,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.goldShadow, location: 0.0),
                    .init(color: WalletColors.goldRich, location: 0.22),
                    .init(color: WalletColors.goldLight, location: 0.48),
                    .init(color: WalletColors.goldMid, location: 0.76),
                    .init(color: WalletColors.goldShadow, location: 1.0)
                ]),
                startPoint: CGPoint(x: -rx, y: rimDepth),
                endPoint: CGPoint(x: rx, y: rimDepth)
            )
        )

        // 3. Coin front face (outer raised bevel ring)
        let facePath = Path(ellipseIn: faceRect)
        coin.fill(
            facePath,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.goldSpecular, location: 0.0),
                    .init(color: WalletColors.goldLight, location: 0.42),
                    .init(color: WalletColors.goldMid, location: 0.80),
                    .init(color: WalletColors.goldRich, location: 1.0)
                ]),
                startPoint: CGPoint(x: -rx * 0.75, y: -ry * 0.75),
                endPoint: CGPoint(x: rx * 0.75, y: ry * 0.75)
            )
        )

        // 4. Soft recessed inner circular disc (chunky raised coin rim without harsh dark wire lines)
        let innerRect = faceRect.insetBy(dx: rx * 0.23, dy: ry * 0.23)
        let innerPath = Path(ellipseIn: innerRect)

        // Subtle inner bevel step shadow (shifted slightly down-right inside the recess)
        coin.fill(
            innerPath,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.goldRich.opacity(0.90), location: 0.0),
                    .init(color: WalletColors.goldMid, location: 0.32),
                    .init(color: WalletColors.goldLight, location: 0.78),
                    .init(color: WalletColors.goldSpecular, location: 1.0)
                ]),
                startPoint: CGPoint(x: innerRect.minX, y: innerRect.minY),
                endPoint: CGPoint(x: innerRect.maxX, y: innerRect.maxY)
            )
        )

        // Soft inner rim bevel highlight/shadow
        coin.stroke(
            innerPath,
            with: .linearGradient(
                Gradient(colors: [
                    WalletColors.goldRich.opacity(0.55),
                    WalletColors.goldSpecular.opacity(0.80)
                ]),
                startPoint: CGPoint(x: innerRect.minX, y: innerRect.minY),
                endPoint: CGPoint(x: innerRect.maxX, y: innerRect.maxY)
            ),
            lineWidth: 0.9
        )

        // Outer coin edge specular sheen
        coin.stroke(
            facePath,
            with: .linearGradient(
                Gradient(colors: [
                    WalletColors.goldSpecular.opacity(0.88),
                    WalletColors.goldRich.opacity(0.35)
                ]),
                startPoint: CGPoint(x: -rx, y: -ry),
                endPoint: CGPoint(x: rx, y: ry)
            ),
            lineWidth: 0.75
        )
    }

    // MARK: 4. Sculpted Cast-Gold Clasp Frame & Kiss-Lock Beads

    private func archCurve(apexY: CGFloat, halfWidth: CGFloat, baseY: CGFloat) -> Path {
        let lx = 60 - halfWidth
        let rx = 60 + halfWidth
        let ctrlY = (apexY - 0.25 * baseY) / 0.75
        return Path { p in
            p.move(to: CGPoint(x: lx, y: baseY))
            p.addCurve(
                to: CGPoint(x: rx, y: baseY),
                control1: CGPoint(x: lx + 1.2, y: ctrlY),
                control2: CGPoint(x: rx - 1.2, y: ctrlY)
            )
        }
    }

    // Closed variable-thickness sculpted gold arch contour that tapers smoothly into rounded side lugs
    private var sculptedArchBandPath: Path {
        let outerHalfW = archHalfW + 2.4
        let innerHalfW = archHalfW - 2.3
        let outerBaseY = lipCornerY + 4.2
        let innerBaseY = lipCornerY + 2.2
        let outerApexY = archApexY - 2.8
        let innerApexY = archApexY + 2.7

        let outerCtrlY = (outerApexY - 0.25 * outerBaseY) / 0.75
        let innerCtrlY = (innerApexY - 0.25 * innerBaseY) / 0.75

        let olx = 60 - outerHalfW
        let orx = 60 + outerHalfW
        let ilx = 60 - innerHalfW
        let irx = 60 + innerHalfW

        return Path { p in
            p.move(to: CGPoint(x: olx, y: outerBaseY))
            // Outer arch curve from left lug to right lug
            p.addCurve(
                to: CGPoint(x: orx, y: outerBaseY),
                control1: CGPoint(x: olx + 1.0, y: outerCtrlY),
                control2: CGPoint(x: orx - 1.0, y: outerCtrlY)
            )
            // Rounded right hinge tip wrapping the right shoulder
            p.addQuadCurve(
                to: CGPoint(x: irx, y: innerBaseY),
                control: CGPoint(x: orx - 0.8, y: outerBaseY + 2.6)
            )
            // Inner arch curve from right shoulder back to left shoulder
            p.addCurve(
                to: CGPoint(x: ilx, y: innerBaseY),
                control1: CGPoint(x: irx - 1.2, y: innerCtrlY),
                control2: CGPoint(x: ilx + 1.2, y: innerCtrlY)
            )
            // Rounded left hinge tip wrapping the left shoulder
            p.addQuadCurve(
                to: CGPoint(x: olx, y: outerBaseY),
                control: CGPoint(x: olx + 0.8, y: outerBaseY + 2.6)
            )
            p.closeSubpath()
        }
    }

    private func drawSculptedClaspFrame(in context: GraphicsContext) {
        let band = sculptedArchBandPath

        // 1. Main warm-gold cast body fill
        context.fill(
            band,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.goldRich, location: 0.0),
                    .init(color: WalletColors.goldLight, location: 0.26),
                    .init(color: WalletColors.goldSpecular, location: 0.48),
                    .init(color: WalletColors.goldMid, location: 0.76),
                    .init(color: WalletColors.goldRich, location: 1.0)
                ]),
                startPoint: CGPoint(x: 60 - archHalfW, y: archApexY),
                endPoint: CGPoint(x: 60 + archHalfW, y: lipCornerY + 4)
            )
        )

        var archClip = context
        archClip.clip(to: band)

        // 2. Inner/lower bronze-gold bevel facing down into the mouth cavity
        let innerBevel = archCurve(apexY: archApexY + 2.2, halfWidth: archHalfW - 1.6, baseY: lipCornerY + 2.5)
        archClip.stroke(
            innerBevel,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.goldShadow.opacity(0.85), location: 0.0),
                    .init(color: WalletColors.goldRich.opacity(0.85), location: 0.50),
                    .init(color: WalletColors.goldShadow.opacity(0.85), location: 1.0)
                ]),
                startPoint: CGPoint(x: 60 - archHalfW, y: lipCornerY),
                endPoint: CGPoint(x: 60 + archHalfW, y: lipCornerY)
            ),
            style: StrokeStyle(lineWidth: 3.4, lineCap: .round)
        )

        // 3. Bright creamy-gold upper bevel ridge along the outer arch crest
        let outerBevel = archCurve(apexY: archApexY - 1.7, halfWidth: archHalfW + 1.2, baseY: lipCornerY + 2.8)
        archClip.stroke(
            outerBevel,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.goldLight.opacity(0.35), location: 0.0),
                    .init(color: WalletColors.goldSpecular.opacity(0.95), location: 0.45),
                    .init(color: WalletColors.goldLight.opacity(0.35), location: 1.0)
                ]),
                startPoint: CGPoint(x: 60 - archHalfW, y: archApexY),
                endPoint: CGPoint(x: 60 + archHalfW, y: archApexY)
            ),
            style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
        )
    }

    private func drawKissLockBeads(in context: GraphicsContext) {
        let archTopY = archApexY - 2.6

        // Sculpted curved stems emerging from the central bridge of the arch
        var stems = Path()
        stems.move(to: CGPoint(x: 58.6, y: archTopY + 0.8))
        stems.addQuadCurve(
            to: CGPoint(x: 54.8, y: archTopY - 4.2),
            control: CGPoint(x: 56.8, y: archTopY - 1.2)
        )
        stems.move(to: CGPoint(x: 61.4, y: archTopY + 0.8))
        stems.addQuadCurve(
            to: CGPoint(x: 65.2, y: archTopY - 4.2),
            control: CGPoint(x: 63.2, y: archTopY - 1.2)
        )

        context.stroke(
            stems,
            with: .linearGradient(
                Gradient(colors: [WalletColors.goldSpecular, WalletColors.goldMid, WalletColors.goldShadow]),
                startPoint: CGPoint(x: 54, y: archTopY - 4),
                endPoint: CGPoint(x: 66, y: archTopY + 1)
            ),
            style: StrokeStyle(lineWidth: 3.0, lineCap: .round)
        )

        // Two plump 3D spherical gold kiss-lock beads
        let beadRadius: CGFloat = 4.6
        let beadY = archTopY - 5.6
        for beadX: CGFloat in [54.6, 65.4] {
            let beadRect = CGRect(
                x: beadX - beadRadius,
                y: beadY - beadRadius,
                width: beadRadius * 2,
                height: beadRadius * 2
            )
            let beadPath = Path(ellipseIn: beadRect)

            context.fill(
                beadPath,
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: WalletColors.goldSpecular, location: 0.0),
                        .init(color: WalletColors.goldLight, location: 0.32),
                        .init(color: WalletColors.goldMid, location: 0.68),
                        .init(color: WalletColors.goldShadow, location: 1.0)
                    ]),
                    center: CGPoint(x: beadX - 1.4, y: beadY - 1.6),
                    startRadius: 0.2,
                    endRadius: beadRadius * 1.32
                )
            )

            context.stroke(
                beadPath,
                with: .linearGradient(
                    Gradient(colors: [
                        WalletColors.goldSpecular.opacity(0.75),
                        WalletColors.goldShadow.opacity(0.45)
                    ]),
                    startPoint: CGPoint(x: beadRect.minX, y: beadRect.minY),
                    endPoint: CGPoint(x: beadRect.maxX, y: beadRect.maxY)
                ),
                lineWidth: 0.5
            )
        }
    }

    // MARK: 5. Silicone Pouch Body & Airbrushed 0% Soft Folds

    private var pouchPath: Path {
        let lx = 60 - lipHalfW
        let rx = 60 + lipHalfW
        let eqRight = 60 + bellyHalfW
        let eqLeft = 60 - bellyHalfW

        // Rounded shoulders that swell outward immediately from the clasp lugs
        let shoulderOut = CGFloat(3.2 * sag + (9.5 + 4.8 * fullness) * (1 - sag))
        let upperBellySpan = equatorY - lipCornerY
        let c1Y = lipCornerY + upperBellySpan * CGFloat(0.44 * sag + 0.24 * (1 - sag))
        let c2Y = equatorY - upperBellySpan * CGFloat(0.32 * sag + 0.46 * (1 - sag))

        // Smooth C1 tangent-continuous lower cheeks down to ground baseline
        let lowerBellySpan = bottomY - equatorY
        let lowerTension = lowerBellySpan * CGFloat(0.64 * sag + 0.74 * (1 - sag))
        let baseFlatness = CGFloat(40.0 * sag + (33.5 - 2.0 * fullness) * (1 - sag))

        return Path { p in
            p.move(to: CGPoint(x: lx, y: lipCornerY))
            p.addCurve(
                to: CGPoint(x: rx, y: lipCornerY),
                control1: CGPoint(x: 60 - lipHalfW * 0.45, y: lipCenterY + lipDip * 0.33),
                control2: CGPoint(x: 60 + lipHalfW * 0.45, y: lipCenterY + lipDip * 0.33)
            )
            p.addCurve(
                to: CGPoint(x: eqRight, y: equatorY),
                control1: CGPoint(x: rx + shoulderOut, y: c1Y),
                control2: CGPoint(x: eqRight, y: c2Y)
            )
            p.addCurve(
                to: CGPoint(x: 60, y: bottomY),
                control1: CGPoint(x: eqRight, y: equatorY + lowerTension),
                control2: CGPoint(x: 60 + baseFlatness, y: bottomY)
            )
            p.addCurve(
                to: CGPoint(x: eqLeft, y: equatorY),
                control1: CGPoint(x: 60 - baseFlatness, y: bottomY),
                control2: CGPoint(x: eqLeft, y: equatorY + lowerTension)
            )
            p.addCurve(
                to: CGPoint(x: lx, y: lipCornerY),
                control1: CGPoint(x: eqLeft, y: c2Y),
                control2: CGPoint(x: lx - shoulderOut, y: c1Y)
            )
            p.closeSubpath()
        }
    }

    private func drawPouchBody(in context: GraphicsContext) {
        let body = pouchPath

        // 1. Base vertical matte silicone gradient
        context.fill(
            body,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.mintLight, location: 0.0),
                    .init(color: WalletColors.mintMid, location: 0.48),
                    .init(color: WalletColors.mintDeep, location: 0.84),
                    .init(color: WalletColors.mintShadow, location: 1.0)
                ]),
                startPoint: CGPoint(x: 56, y: lipCornerY),
                endPoint: CGPoint(x: 62, y: bottomY)
            )
        )

        var clipped = context
        clipped.clip(to: body)

        // 2. Broad, velvety 3D spherical highlight across the upper-front belly
        let highlightCenterY = lipCenterY + (bottomY - lipCenterY) * CGFloat(0.35 - 0.04 * fullness)
        let highlightCenter = CGPoint(x: 53.5, y: highlightCenterY)
        let highlightRx = bellyHalfW * 1.05
        let highlightRy = max(16.0, (bottomY - lipCornerY) * 0.65)
        let highlightRect = CGRect(
            x: highlightCenter.x - highlightRx,
            y: highlightCenter.y - highlightRy,
            width: highlightRx * 2,
            height: highlightRy * 2
        )
        clipped.fill(
            Path(ellipseIn: highlightRect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: WalletColors.mintHighlight.opacity(0.68), location: 0.0),
                    .init(color: WalletColors.mintLight.opacity(0.36), location: 0.50),
                    .init(color: WalletColors.mintMid.opacity(0.0), location: 1.0)
                ]),
                center: highlightCenter,
                startRadius: 4,
                endRadius: highlightRx
            )
        )

        // 3. Soft lower-belly ambient occlusion & peripheral turn-of-form shading
        clipped.fill(
            body,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.65),
                    .init(color: WalletColors.mintAmbient.opacity(0.55), location: 1.0)
                ]),
                startPoint: CGPoint(x: 60, y: lipCornerY),
                endPoint: CGPoint(x: 60, y: bottomY)
            )
        )

        // 4. Softly sculpted, diffused 3D silicone folds when empty (0% -> 25%)
        if sag > 0.005 {
            var softFolds = clipped
            softFolds.addFilter(.blur(radius: 1.9))
            drawEmptyStateFolds(in: softFolds)
        }

        // 5. Diffused overhang shadow & corner gather dimples beneath the rolled lip
        var softLipShadow = clipped
        softLipShadow.addFilter(.blur(radius: 1.2))
        let underLip = lipCurvePath(verticalOffset: 2.8)
        softLipShadow.stroke(
            underLip,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.mintShadow.opacity(0.42), location: 0.0),
                    .init(color: WalletColors.mintDeep.opacity(0.34 + 0.30 * sag), location: 0.5),
                    .init(color: WalletColors.mintShadow.opacity(0.42), location: 1.0)
                ]),
                startPoint: CGPoint(x: 60 - lipHalfW, y: lipCornerY),
                endPoint: CGPoint(x: 60 + lipHalfW, y: lipCornerY)
            ),
            style: StrokeStyle(lineWidth: 3.6, lineCap: .round)
        )

        // Subtle corner gather dimples near the gold clasp ends
        let gatherAlpha = 0.38 * (0.4 + 0.6 * fullness)
        var gathers = Path()
        let lx = 60 - lipHalfW
        let rx = 60 + lipHalfW
        gathers.move(to: CGPoint(x: lx + 2.2, y: lipCornerY + 2.2))
        gathers.addQuadCurve(
            to: CGPoint(x: lx + 8.0, y: lipCornerY + 6.8),
            control: CGPoint(x: lx + 3.8, y: lipCornerY + 5.6)
        )
        gathers.move(to: CGPoint(x: rx - 2.2, y: lipCornerY + 2.2))
        gathers.addQuadCurve(
            to: CGPoint(x: rx - 8.0, y: lipCornerY + 6.8),
            control: CGPoint(x: rx - 3.8, y: lipCornerY + 5.6)
        )
        clipped.stroke(
            gathers,
            with: .color(WalletColors.mintShadow.opacity(gatherAlpha)),
            style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
        )
    }

    private func drawEmptyStateFolds(in context: GraphicsContext) {
        let s = sag
        let shift = CGFloat((1 - s) * 3.5)

        // 1. Deep U-collar valley crease under the slumped front lip
        var upperCrease = Path()
        upperCrease.move(to: CGPoint(x: 20, y: 71.0 - shift))
        upperCrease.addCurve(
            to: CGPoint(x: 96, y: 83.5 - shift * 0.5),
            control1: CGPoint(x: 42, y: 84.5 - shift),
            control2: CGPoint(x: 74, y: 82.0 - shift)
        )
        context.stroke(
            upperCrease,
            with: .color(WalletColors.mintShadow.opacity(0.65 * s)),
            style: StrokeStyle(lineWidth: 4.2, lineCap: .round)
        )

        // 2. Plump diagonal silicone fold lobe sweeping from left cushion across center to lower-right
        var mainFoldLobe = Path()
        mainFoldLobe.move(to: CGPoint(x: 13, y: 81.5 - shift * 0.5))
        mainFoldLobe.addCurve(
            to: CGPoint(x: 95, y: 87.5),
            control1: CGPoint(x: 38, y: 87.8 - shift * 0.5),
            control2: CGPoint(x: 70, y: 85.0 - shift * 0.5)
        )
        context.stroke(
            mainFoldLobe,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.mintHighlight.opacity(0.65 * s), location: 0.0),
                    .init(color: WalletColors.mintSpecular.opacity(0.75 * s), location: 0.42),
                    .init(color: WalletColors.mintHighlight.opacity(0.45 * s), location: 1.0)
                ]),
                startPoint: CGPoint(x: 14, y: 81),
                endPoint: CGPoint(x: 95, y: 88)
            ),
            style: StrokeStyle(lineWidth: 5.5, lineCap: .round)
        )

        // 3. Lower right-hand valley tuck & right cushion lobe (matches the asymmetric soft fold at 0% in B)
        var lowerRightCrease = Path()
        lowerRightCrease.move(to: CGPoint(x: 36, y: 89.0))
        lowerRightCrease.addCurve(
            to: CGPoint(x: 103, y: 79.5 - shift * 0.5),
            control1: CGPoint(x: 62, y: 90.5),
            control2: CGPoint(x: 86, y: 85.0)
        )
        context.stroke(
            lowerRightCrease,
            with: .color(WalletColors.mintAmbient.opacity(0.60 * s)),
            style: StrokeStyle(lineWidth: 3.6, lineCap: .round)
        )

        var lowerRightLobe = Path()
        lowerRightLobe.move(to: CGPoint(x: 54, y: 90.2))
        lowerRightLobe.addCurve(
            to: CGPoint(x: 107, y: 83.0 - shift * 0.5),
            control1: CGPoint(x: 74, y: 91.2),
            control2: CGPoint(x: 94, y: 87.5)
        )
        context.stroke(
            lowerRightLobe,
            with: .color(WalletColors.mintHighlight.opacity(0.62 * s)),
            style: StrokeStyle(lineWidth: 4.6, lineCap: .round)
        )
    }

    // MARK: 6. Softly Integrated Rolled Silicone Lip

    private func lipCurvePath(verticalOffset: CGFloat = 0, horizontalInset: CGFloat = 0) -> Path {
        let lx = 60 - (lipHalfW - horizontalInset)
        let rx = 60 + (lipHalfW - horizontalInset)
        let cornerY = lipCornerY + verticalOffset
        let centerControlY = lipCenterY + lipDip * 0.33 + verticalOffset
        return Path { p in
            p.move(to: CGPoint(x: lx, y: cornerY))
            p.addCurve(
                to: CGPoint(x: rx, y: cornerY),
                control1: CGPoint(x: 60 - (lipHalfW - horizontalInset) * 0.45, y: centerControlY),
                control2: CGPoint(x: 60 + (lipHalfW - horizontalInset) * 0.45, y: centerControlY)
            )
        }
    }

    private func drawRolledLip(in context: GraphicsContext) {
        // Plump rolled collar body blended with soft mint tones
        let mainLip = lipCurvePath(verticalOffset: 0.5, horizontalInset: 0.4)
        context.stroke(
            mainLip,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.mintMid, location: 0.0),
                    .init(color: WalletColors.mintLight, location: 0.20),
                    .init(color: WalletColors.mintHighlight, location: 0.50),
                    .init(color: WalletColors.mintLight, location: 0.80),
                    .init(color: WalletColors.mintMid, location: 1.0)
                ]),
                startPoint: CGPoint(x: 60 - lipHalfW, y: lipCornerY),
                endPoint: CGPoint(x: 60 + lipHalfW, y: lipCornerY)
            ),
            style: StrokeStyle(lineWidth: 4.2, lineCap: .round)
        )

        // Soft upper lip highlight (matte silicone sheen, not stark white)
        let topRim = lipCurvePath(verticalOffset: -0.5, horizontalInset: 2.0)
        context.stroke(
            topRim,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.mintHighlight.opacity(0.15), location: 0.0),
                    .init(color: WalletColors.mintSpecular.opacity(0.68), location: 0.48),
                    .init(color: WalletColors.mintHighlight.opacity(0.15), location: 1.0)
                ]),
                startPoint: CGPoint(x: 60 - lipHalfW, y: lipCornerY),
                endPoint: CGPoint(x: 60 + lipHalfW, y: lipCornerY)
            ),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }
}

// MARK: - Compact Drawing (24x24 Normalized Space for 22x22 Notch Icon)

private struct CompactWalletDrawing {
    let fullness: Double

    private var sag: Double {
        let raw = max(0, 1 - fullness / 0.30)
        return raw * raw * (3 - 2 * raw)
    }

    private var rise: Double {
        pow(fullness, 0.86)
    }

    private let bottomY: CGFloat = 21.2

    // At 0%: low collapsed collar (y=17.4); at 100%: tall plump pouch (y=11.4)
    private var lipCornerY: CGFloat {
        CGFloat(17.4 - 6.0 * rise)
    }

    private var lipDip: CGFloat {
        CGFloat(0.65 + 0.95 * pow(1 - fullness, 1.2))
    }

    private var lipCenterY: CGFloat {
        lipCornerY + lipDip
    }

    // Arch stays generous so a crisp dark negative-space crescent always remains above the coins
    private var archApexY: CGFloat {
        CGFloat(8.6 - 3.4 * rise)
    }

    private var equatorY: CGFloat {
        CGFloat(19.4 - 2.6 * rise + 0.4 * sag)
    }

    private var bellyHalfW: CGFloat {
        CGFloat(9.2 + 0.4 * fullness + 0.5 * sag)
    }

    private var lipHalfW: CGFloat {
        CGFloat(7.3 - 0.1 * fullness)
    }

    func draw(in context: GraphicsContext) {
        // 1. High-contrast recessed dark-green cavity
        let cavity = cavityPath
        context.fill(
            cavity,
            with: .color(Color(red: 0.04, green: 0.13, blue: 0.09))
        )

        // 2. Bold, thick warm-gold arch (guaranteed readable at 22x22)
        context.stroke(
            archPath,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: WalletColors.goldLight, location: 0.0),
                    .init(color: WalletColors.goldSpecular, location: 0.48),
                    .init(color: WalletColors.goldMid, location: 1.0)
                ]),
                startPoint: CGPoint(x: 4.5, y: archApexY),
                endPoint: CGPoint(x: 19.5, y: lipCornerY)
            ),
            style: StrokeStyle(lineWidth: 2.05, lineCap: .round)
        )

        // 3. Clean 2-dome gold coin silhouette inside cavity with preserved dark negative space above
        if fullness > 0.03 {
            var coinsCtx = context
            coinsCtx.clip(to: cavity)
            drawCompactCoins(in: coinsCtx)
        }

        // 4. Plump, high-contrast mint silicone pouch silhouette
        let body = pouchPath
        context.fill(
            body,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.62, green: 0.91, blue: 0.72), location: 0.0),
                    .init(color: Color(red: 0.48, green: 0.82, blue: 0.61), location: 0.60),
                    .init(color: Color(red: 0.35, green: 0.68, blue: 0.49), location: 1.0)
                ]),
                startPoint: CGPoint(x: 11, y: lipCornerY),
                endPoint: CGPoint(x: 13, y: bottomY)
            )
        )

        // 5. Crisp top lip highlight & subtle corner gather marks
        context.stroke(
            lipPath,
            with: .color(WalletColors.mintSpecular.opacity(0.75)),
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round)
        )

        // 6. Two distinct kiss-lock beads with short stems at crown
        drawCompactBeads(in: context)
    }

    private var archPath: Path {
        let halfW = lipHalfW + 0.25
        let lx = 12 - halfW
        let rx = 12 + halfW
        let baseY = lipCornerY + 0.5
        let ctrlY = (archApexY - 0.25 * baseY) / 0.75
        return Path { p in
            p.move(to: CGPoint(x: lx, y: baseY))
            p.addCurve(
                to: CGPoint(x: rx, y: baseY),
                control1: CGPoint(x: lx + 0.4, y: ctrlY),
                control2: CGPoint(x: rx - 0.4, y: ctrlY)
            )
        }
    }

    private var cavityPath: Path {
        let halfW = lipHalfW + 0.15
        let lx = 12 - halfW
        let rx = 12 + halfW
        let baseY = lipCornerY + 0.6
        let ctrlY = (archApexY - 0.25 * baseY) / 0.75
        return Path { p in
            p.move(to: CGPoint(x: lx, y: baseY))
            p.addCurve(
                to: CGPoint(x: rx, y: baseY),
                control1: CGPoint(x: lx + 0.4, y: ctrlY),
                control2: CGPoint(x: rx - 0.4, y: ctrlY)
            )
            p.addLine(to: CGPoint(x: rx, y: lipCenterY + 2.5))
            p.addLine(to: CGPoint(x: lx, y: lipCenterY + 2.5))
            p.closeSubpath()
        }
    }

    private var lipPath: Path {
        let lx = 12 - lipHalfW
        let rx = 12 + lipHalfW
        return Path { p in
            p.move(to: CGPoint(x: lx, y: lipCornerY))
            p.addCurve(
                to: CGPoint(x: rx, y: lipCornerY),
                control1: CGPoint(x: 12 - lipHalfW * 0.45, y: lipCenterY + lipDip * 0.35),
                control2: CGPoint(x: 12 + lipHalfW * 0.45, y: lipCenterY + lipDip * 0.35)
            )
        }
    }

    private var pouchPath: Path {
        let lx = 12 - lipHalfW
        let rx = 12 + lipHalfW
        let eqRight = 12 + bellyHalfW
        let eqLeft = 12 - bellyHalfW
        let shoulderOut = CGFloat(1.2 * sag + (1.8 + 0.7 * fullness) * (1 - sag))
        let upperSpan = equatorY - lipCornerY
        let lowerSpan = bottomY - equatorY
        let baseFlatness = CGFloat(7.8 * sag + 6.8 * (1 - sag))

        return Path { p in
            p.move(to: CGPoint(x: lx, y: lipCornerY))
            p.addCurve(
                to: CGPoint(x: rx, y: lipCornerY),
                control1: CGPoint(x: 12 - lipHalfW * 0.45, y: lipCenterY + lipDip * 0.35),
                control2: CGPoint(x: 12 + lipHalfW * 0.45, y: lipCenterY + lipDip * 0.35)
            )
            p.addCurve(
                to: CGPoint(x: eqRight, y: equatorY),
                control1: CGPoint(x: rx + shoulderOut, y: lipCornerY + upperSpan * 0.28),
                control2: CGPoint(x: eqRight, y: equatorY - upperSpan * 0.42)
            )
            p.addCurve(
                to: CGPoint(x: 12, y: bottomY),
                control1: CGPoint(x: eqRight, y: equatorY + lowerSpan * 0.74),
                control2: CGPoint(x: 12 + baseFlatness, y: bottomY)
            )
            p.addCurve(
                to: CGPoint(x: eqLeft, y: equatorY),
                control1: CGPoint(x: 12 - baseFlatness, y: bottomY),
                control2: CGPoint(x: eqLeft, y: equatorY + lowerSpan * 0.74)
            )
            p.addCurve(
                to: CGPoint(x: lx, y: lipCornerY),
                control1: CGPoint(x: eqLeft, y: equatorY - upperSpan * 0.42),
                control2: CGPoint(x: lx - shoulderOut, y: lipCornerY + upperSpan * 0.28)
            )
            p.closeSubpath()
        }
    }

    private func drawCompactCoins(in context: GraphicsContext) {
        let alpha = min(1.0, (fullness - 0.03) / 0.08)
        var c = context
        c.opacity = alpha

        // Coins rise from just below the lip toward the middle of the cavity,
        // always keeping a crisp dark negative-space gap below archApexY.
        let t = CGFloat(fullness)
        let coinTopY = lipCenterY + 0.6 - (lipCenterY - archApexY - 2.3) * (0.28 + 0.72 * t)

        // Left coin dome & right coin dome (matching the 2-dome compact silhouette in selected-B.jpg)
        let leftRect = CGRect(x: 5.8, y: coinTopY + 0.3, width: 7.4, height: 6.2)
        let rightRect = CGRect(x: 10.6, y: coinTopY - 0.2, width: 7.6, height: 6.6)

        let coinGrad = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [WalletColors.goldSpecular, WalletColors.goldLight, WalletColors.goldMid]),
            startPoint: CGPoint(x: 8, y: coinTopY),
            endPoint: CGPoint(x: 16, y: lipCenterY + 2)
        )

        c.fill(Path(ellipseIn: leftRect), with: coinGrad)

        // Subtle warm-bronze overlap seam on the right coin so two coins read clearly without dark clutter
        let rightPath = Path(ellipseIn: rightRect)
        c.fill(rightPath, with: coinGrad)
        c.stroke(rightPath, with: .color(WalletColors.goldShadow.opacity(0.75)), lineWidth: 0.75)
    }

    private func drawCompactBeads(in context: GraphicsContext) {
        let archTopY = archApexY - 0.9
        var stems = Path()
        stems.move(to: CGPoint(x: 11.4, y: archTopY + 0.4))
        stems.addLine(to: CGPoint(x: 10.5, y: archTopY - 1.2))
        stems.move(to: CGPoint(x: 12.6, y: archTopY + 0.4))
        stems.addLine(to: CGPoint(x: 13.5, y: archTopY - 1.2))
        context.stroke(
            stems,
            with: .color(WalletColors.goldLight),
            style: StrokeStyle(lineWidth: 1.15, lineCap: .round)
        )

        let beadY = archTopY - 1.4
        let r: CGFloat = 1.25
        for bx: CGFloat in [10.45, 13.55] {
            let rect = CGRect(x: bx - r, y: beadY - r, width: r * 2, height: r * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [WalletColors.goldSpecular, WalletColors.goldLight, WalletColors.goldRich]),
                    center: CGPoint(x: bx - 0.3, y: beadY - 0.3),
                    startRadius: 0,
                    endRadius: r * 1.3
                )
            )
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(0..<5) { n in
                VStack(spacing: 8) {
                    SalaryWalletArtwork(progress: Double(n) / 4)
                        .frame(width: 132, height: 110)
                    Text("\(n * 25)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        HStack(spacing: 18) {
            ForEach(0..<5) { n in
                SalaryWalletArtwork(progress: Double(n) / 4, compact: true)
                    .frame(width: 22, height: 22)
            }
        }
    }
    .padding(24)
    .background(.black)
}
