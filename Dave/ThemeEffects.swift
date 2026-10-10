import SwiftUI
import UIKit

// Each theme's own effects, the same as on the PC: northern lights (Aurora), flames and embers (Ember), slime dripping
// (Toxic), a water surface and light rays (Ocean), cherry blossom petals (Sakura), stars and shooting stars (Midnight).
// Around the big orb, and behind everything. Stronger while you or Dave talk. Particles are worked out from the time
// (each one keeps coming back with a new random start), so nothing needs to be kept between frames.

enum ThemeFX {
    // MARK: Helpers

    /// A random number 0..1 that's always the same for the same [a] and [b].
    static func rnd(_ a: Int, _ b: Int) -> CGFloat {
        let x = sin(Double(a) * 12.9898 + Double(b) * 78.233) * 43758.5453
        return CGFloat(x - floor(x))
    }

    static func smooth(_ x: Double) -> CGFloat { CGFloat(0.5 + 0.5 * sin(x)) }

    /// Fully in the middle, smoothly down to nothing at both ends of an edge, so effects close neatly.
    static func taper(_ u: CGFloat, zone: CGFloat = 0.3) -> CGFloat {
        let x = min(1, max(0, min(u, 1 - u) / zone))
        return x * x * (3 - 2 * x)
    }

    /// Particle [i] of [n], living [life] seconds and then starting again: how far along its life it is (0..1), and a
    /// number that's different every life (for its random start).
    static func cycle(_ i: Int, _ n: Int, life: Double, _ t: Double) -> (age: CGFloat, seed: Int) {
        let x = t / life + Double(i) / Double(n) + Double(i) * 0.37
        return (CGFloat(x - floor(x)), Int(floor(x)) * 131 + i * 7)
    }

    /// The theme's colours: main, accent, bright, middle.
    static var palette: [Color] { [.davePurple, .davePink, .daveCyan, .daveViolet] }

    /// A colour smoothly in between the theme's colours, [x] going round them.
    static func along(_ x: Double) -> Color {
        let colours = palette
        let p = (x - floor(x)) * Double(colours.count)
        let i = Int(p) % colours.count
        return mix(colours[i], colours[(i + 1) % colours.count], CGFloat(p - floor(p)))
    }

    static func mix(_ a: Color, _ b: Color, _ f: CGFloat) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(a).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(b).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: Double(r1 + (r2 - r1) * f), green: Double(g1 + (g2 - g1) * f), blue: Double(b1 + (b2 - b1) * f))
    }

    private static func circle(_ p: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    /// A point on the upper part of a circle (where things rise from), with its outward direction; [u] 0..1 from left to right.
    private static func upper(_ c: CGPoint, _ r: CGFloat, _ u: CGFloat) -> (CGPoint, CGVector) {
        let a = Double.pi * (1.08 + 0.84 * Double(u))
        let d = CGVector(dx: cos(a), dy: sin(a))
        return (CGPoint(x: c.x + d.dx * r, y: c.y + d.dy * r), d)
    }

    /// A point on the lower part of a circle (where things drip from); [u] 0..1 from right to left.
    private static func lower(_ c: CGPoint, _ r: CGFloat, _ u: CGFloat) -> CGPoint {
        let a = Double.pi * (0.18 + 0.64 * Double(u))
        return CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
    }

    // MARK: Around the orb

    /// The theme's effect around the big orb (centre [c], radius [r]); drawn behind it, so it seems to come from its edge.
    static func aroundOrb(_ g: inout GraphicsContext, centre c: CGPoint, r: CGFloat, voice v: CGFloat, t: Double) {
        let strength = min(1.6, 0.6 + v * 1.2)
        switch Theme.current.id {
        case "aurora":
            // Curtains of light rising from the top, waving and shifting colour
            let n = 46
            for i in 0...n {
                let u = CGFloat(i) / CGFloat(n)
                let (p, d) = upper(c, r - 2, u)
                let wave = 0.35 + 0.65 * smooth(Double(u) * 7 + t * 0.7) * smooth(Double(u) * 17 - t * 1.3 + 1)
                let height = (22 + v * 34) * wave * strength * taper(u)
                if height < 2 { continue }
                let end = CGPoint(x: p.x + d.dx * height, y: p.y + d.dy * height)
                let colour = along(Double(u) * 0.7 + t * 0.04)
                var line = Path()
                line.move(to: p)
                line.addLine(to: end)
                g.stroke(line, with: .linearGradient(Gradient(colors: [colour.opacity(0.85), colour.opacity(0)]), startPoint: p, endPoint: end), lineWidth: 4)
            }
        case "ember":
            // Flames licking up from the top, flickering, and embers rising from them
            let gold = Color(red: 1, green: 0.93, blue: 0.67)
            for i in stride(from: 0, through: 40, by: 2) {
                let u = CGFloat(i) / 40
                let fade = taper(u)
                if fade < 0.04 { continue }
                let (p, d) = upper(c, r - 1, u)
                let side = CGVector(dx: -d.dy, dy: d.dx)
                let flicker = 0.5 * smooth(t * 9 + Double(i) * 1.7) + 0.5 * smooth(t * 13.7 + Double(i) * 0.9)
                let height = ((14 + v * 26) * (0.45 + 0.55 * flicker) * strength + 4) * fade
                let width = 11 * (0.4 + 0.6 * fade), lean = 3 * CGFloat(sin(t * 6 + Double(i))) * fade
                let tip = CGPoint(x: p.x + d.dx * height + side.dx * lean, y: p.y + d.dy * height + side.dy * lean)
                let left = CGPoint(x: p.x - side.dx * width / 2, y: p.y - side.dy * width / 2)
                let right = CGPoint(x: p.x + side.dx * width / 2, y: p.y + side.dy * width / 2)
                var flame = Path()
                flame.move(to: left)
                flame.addCurve(to: tip, control1: CGPoint(x: left.x + d.dx * height * 0.55, y: left.y + d.dy * height * 0.55),
                               control2: CGPoint(x: tip.x - side.dx * 2, y: tip.y - side.dy * 2))
                flame.addCurve(to: right, control1: CGPoint(x: tip.x + side.dx * 2, y: tip.y + side.dy * 2),
                               control2: CGPoint(x: right.x + d.dx * height * 0.55, y: right.y + d.dy * height * 0.55))
                flame.closeSubpath()
                g.fill(flame, with: .linearGradient(Gradient(colors: [gold.opacity(0.92), Color.davePink.opacity(0.8), Color.davePurple.opacity(0)]),
                                                    startPoint: p, endPoint: tip))
            }
            for i in 0..<16 {
                let (age, seed) = cycle(i, 16, life: 1.5 + 0.5 * Double(rnd(i, 0)), t)
                let (p, d) = upper(c, r, 0.1 + 0.8 * rnd(seed, 1))
                let rise = age * (42 + v * 30)
                let x = p.x + d.dx * rise * 0.5 + 4 * CGFloat(sin(t * 3 + Double(seed)))
                let y = p.y + d.dy * rise * 0.5 - rise
                let size = (1 + 1.3 * rnd(seed, 2)) * (1 - age * 0.5)
                let colour = mix(.daveCyan, .davePurple, age)
                g.fill(circle(CGPoint(x: x, y: y), size * 3), with: .color(colour.opacity(Double(0.3 * (1 - age)))))
                g.fill(circle(CGPoint(x: x, y: y), size), with: .color(colour.opacity(Double(1 - age))))
            }
        case "toxic":
            // Slime hanging from the bottom, slowly swelling, and drops that grow and fall off
            for i in 0..<6 {
                let p = lower(c, r - 1, (CGFloat(i) + 0.5) / 6)
                let b = (2.5 + 3 * smooth(t * 1.3 + Double(i) * 1.7)) * (0.8 + v)
                g.fill(Path(ellipseIn: CGRect(x: p.x - b * 2, y: p.y - b, width: b * 4, height: b * 3.2)), with: .color(Color.davePink.opacity(0.25)))
                g.fill(Path(ellipseIn: CGRect(x: p.x - b * 1.3, y: p.y - b * 0.6, width: b * 2.6, height: b * 2.1)), with: .color(Color.davePink.opacity(0.9)))
            }
            for i in 0..<6 {
                let (age, seed) = cycle(i, 6, life: 1.8 + 0.6 * Double(rnd(i, 3)), t)
                let p = lower(c, r, 0.1 + 0.8 * rnd(seed, 1))
                let size = 2 + 1.5 * rnd(seed, 2)
                let hang: CGFloat = 0.35
                let y: CGFloat, s: CGFloat, o: CGFloat
                if age < hang { y = p.y + 2 + age / hang * 3; s = size * (0.4 + 0.6 * age / hang); o = 1 }
                else { let k = (age - hang) / (1 - hang); y = p.y + 5 + k * k * 48; s = size; o = 1 - k }
                g.fill(Path(ellipseIn: CGRect(x: p.x - s, y: y - s * 1.3, width: s * 2, height: s * 2.6)), with: .color(Color.davePink.opacity(Double(o))))
            }
        case "ocean":
            // A water surface along the top, with waves running along it and foam on the crest
            let n = 40
            var base: [CGPoint] = [], crest: [CGPoint] = []
            for i in 0...n {
                let u = CGFloat(i) / CGFloat(n)
                let (p, d) = upper(c, r - 1, u)
                let h = (7 + 3 * CGFloat(sin(Double(u) * 14 - t * 3)) + 2 * CGFloat(sin(Double(u) * 31 + t * 2.2)) + v * 9) * strength * taper(u)
                base.append(p)
                crest.append(CGPoint(x: p.x + d.dx * h, y: p.y + d.dy * h))
            }
            var water = Path()
            water.addLines(base)
            water.addLines(crest.reversed())
            water.closeSubpath()
            g.fill(water, with: .linearGradient(Gradient(colors: [Color.daveCyan.opacity(0.8), Color.davePurple.opacity(0.3)]),
                                                startPoint: CGPoint(x: c.x, y: c.y - r - 22), endPoint: CGPoint(x: c.x, y: c.y - r + 12)))
            var foam = Path()
            foam.addLines(crest)
            g.stroke(foam, with: .color(.white.opacity(0.65)), lineWidth: 1.6)
        case "sakura":
            // Cherry blossom petals drifting down past the orb
            for i in 0..<10 {
                let (age, seed) = cycle(i, 10, life: 3 + 1.2 * Double(rnd(i, 4)), t)
                let x = c.x - 100 + rnd(seed, 1) * 130 + age * 75 + 8 * CGFloat(sin(t * 1.7 + Double(seed)))
                let y = c.y - 100 + age * 200
                petal(&g, CGPoint(x: x, y: y), size: 3.5 + 2 * rnd(seed, 2), angle: Double(rnd(seed, 3)) * 360 + Double(age) * 260,
                      opacity: Double(sin(Double(age) * .pi)))
            }
        case "midnight":
            // Stars twinkling around the orb, and now and then a shooting star
            for i in 0..<14 {
                let a = Double(rnd(i, 1)) * 2 * .pi
                let dist = r + 12 + rnd(i, 2) * 34
                let p = CGPoint(x: c.x + CGFloat(cos(a)) * dist, y: c.y + CGFloat(sin(a)) * dist)
                let twinkle = smooth(t * (1.2 + Double(rnd(i, 3)) * 1.5) + Double(i))
                let s = (0.6 + 1.2 * rnd(i, 4)) * (0.5 + twinkle * (0.5 + v))
                g.fill(circle(p, s * 3), with: .color(Color.daveCyan.opacity(Double(0.18 * twinkle))))
                g.fill(circle(p, s), with: .color(.white.opacity(Double(0.35 + 0.65 * twinkle))))
                if rnd(i, 5) > 0.6 { sparkle(&g, p, s * 4 * twinkle, opacity: Double(0.7 * twinkle)) }
            }
            for i in 0..<2 {
                let (age, seed) = cycle(i, 2, life: 5, t)
                if age > 0.16 { continue }
                let k = age / 0.16
                let start = CGPoint(x: c.x - 90 + rnd(seed, 1) * 60, y: c.y - 90 + rnd(seed, 2) * 40)
                shootingStar(&g, from: start, k: k, length: 120)
            }
        default:
            break
        }
    }

    // MARK: Behind everything

    /// The theme's effect over the whole background.
    static func backdrop(_ g: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, h = size.height
        switch Theme.current.id {
        case "aurora":
            // Northern lights hanging down from the top, waving slowly
            g.drawLayer { layer in
                layer.addFilter(.blur(radius: 12))
                layer.blendMode = .plusLighter
                for x in stride(from: CGFloat(-10), through: w + 10, by: 7) {
                    let u = Double(x / w)
                    let height = h * (0.14 + 0.16 * smooth(u * 6 + t * 0.35) * smooth(u * 13 - t * 0.6 + 2))
                    let sway = 14 * CGFloat(sin(t * 0.5 + u * 8))
                    let colour = along(u * 0.8 + t * 0.03)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: -10))
                    line.addLine(to: CGPoint(x: x + sway, y: height))
                    layer.stroke(line, with: .linearGradient(Gradient(colors: [colour.opacity(0.5), colour.opacity(0)]),
                                                             startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x, y: height)), lineWidth: 10)
                }
            }
        case "ember":
            // A fire glow along the bottom, and embers rising from it
            let glow = CGRect(x: 0, y: h * 0.68, width: w, height: h * 0.32)
            let flicker = 0.85 + 0.15 * smooth(t * 3.1) * smooth(t * 4.7 + 1)
            g.fill(Path(glow), with: .linearGradient(Gradient(colors: [Color.davePurple.opacity(0), Color.davePurple.opacity(Double(0.32 * flicker))]),
                                                     startPoint: CGPoint(x: 0, y: glow.minY), endPoint: CGPoint(x: 0, y: h)))
            for i in 0..<28 {
                let (age, seed) = cycle(i, 28, life: 3 + 2 * Double(rnd(i, 0)), t)
                let x = rnd(seed, 1) * w + 22 * CGFloat(sin(t * 1.3 + Double(seed)))
                let y = h + 10 - age * h * (0.45 + 0.25 * rnd(seed, 2))
                let s = (1 + 1.6 * rnd(seed, 3)) * (1 - age * 0.6)
                let colour = mix(.daveCyan, .davePurple, age)
                g.fill(circle(CGPoint(x: x, y: y), s * 3.5), with: .color(colour.opacity(Double(0.22 * (1 - age)))))
                g.fill(circle(CGPoint(x: x, y: y), s), with: .color(colour.opacity(Double(0.9 * (1 - age)))))
            }
        case "toxic":
            // A slime edge along the top with drops falling from it, and a green haze
            g.drawLayer { layer in
                layer.addFilter(.blur(radius: 40))
                for k in 0..<3 {
                    let x = w * (0.2 + 0.3 * CGFloat(k)) + 40 * CGFloat(sin(t * 0.2 + Double(k) * 2))
                    let y = h * (0.35 + 0.2 * CGFloat(k % 2)) + 30 * CGFloat(cos(t * 0.15 + Double(k)))
                    layer.fill(Path(ellipseIn: CGRect(x: x - 120, y: y - 80, width: 240, height: 160)), with: .color(Color.davePink.opacity(0.08)))
                }
            }
            var slime = Path()
            slime.move(to: CGPoint(x: 0, y: 0))
            for x in stride(from: CGFloat(0), through: w, by: 6) {
                let y = 16 + 5 * CGFloat(sin(Double(x) * 0.03 + t * 0.9)) + 9 * pow(smooth(Double(x) * 0.045 + 1.3), 6)
                slime.addLine(to: CGPoint(x: x, y: y))
            }
            slime.addLine(to: CGPoint(x: w, y: 0))
            slime.closeSubpath()
            g.fill(slime, with: .linearGradient(Gradient(colors: [Color.davePurple.opacity(0.55), Color.davePink.opacity(0.35)]),
                                                startPoint: .zero, endPoint: CGPoint(x: 0, y: 30)))
            for i in 0..<7 {
                let (age, seed) = cycle(i, 7, life: 3.2 + Double(rnd(i, 1)), t)
                let x = rnd(seed, 2) * w
                let s = 2.5 + 2 * rnd(seed, 3)
                let hang: CGFloat = 0.3
                let y: CGFloat, o: CGFloat
                if age < hang { y = 22 + age / hang * 6; o = 1 } else { let k = (age - hang) / (1 - hang); y = 28 + k * k * h * 0.55; o = 1 - k }
                g.fill(Path(ellipseIn: CGRect(x: x - s, y: y - s * 1.3, width: s * 2, height: s * 2.6)), with: .color(Color.davePink.opacity(Double(0.8 * o))))
            }
        case "ocean":
            // Light rays falling in from the surface, and waves rolling along the bottom
            g.drawLayer { layer in
                layer.addFilter(.blur(radius: 8))
                for k in 0..<5 {
                    let x0 = w * (0.08 + 0.21 * CGFloat(k)) + 30 * CGFloat(sin(t * 0.2 + Double(k)))
                    let shine = 0.5 + 0.5 * smooth(t * 0.5 + Double(k) * 1.9)
                    var ray = Path()
                    ray.move(to: CGPoint(x: x0 - 14, y: -10))
                    ray.addLine(to: CGPoint(x: x0 + 14, y: -10))
                    ray.addLine(to: CGPoint(x: x0 + 90, y: h * 0.7))
                    ray.addLine(to: CGPoint(x: x0 + 20, y: h * 0.7))
                    ray.closeSubpath()
                    layer.fill(ray, with: .linearGradient(Gradient(colors: [Color.daveCyan.opacity(Double(0.16 * shine)), Color.daveCyan.opacity(0)]),
                                                          startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x0 + 50, y: h * 0.7)))
                }
            }
            for k in 0..<2 {
                var wave = Path()
                wave.move(to: CGPoint(x: 0, y: h))
                for x in stride(from: CGFloat(0), through: w + 6, by: 6) {
                    let y = h - 46 - CGFloat(k) * 20 + 9 * CGFloat(sin(Double(x) * 0.02 + t * (0.8 + 0.3 * Double(k)) + Double(k) * 2))
                    wave.addLine(to: CGPoint(x: x, y: y))
                }
                wave.addLine(to: CGPoint(x: w, y: h))
                wave.closeSubpath()
                g.fill(wave, with: .color((k == 0 ? Color.davePurple : Color.daveCyan).opacity(k == 0 ? 0.2 : 0.12)))
            }
        case "sakura":
            // Petals drifting across the screen
            for i in 0..<18 {
                let (age, seed) = cycle(i, 18, life: 7 + 3 * Double(rnd(i, 0)), t)
                let x = rnd(seed, 1) * w * 1.2 - w * 0.2 + age * w * 0.35 + 18 * CGFloat(sin(t * 1.1 + Double(seed)))
                let y = -20 + age * (h + 40)
                petal(&g, CGPoint(x: x, y: y), size: 4 + 3 * rnd(seed, 2), angle: Double(rnd(seed, 3)) * 360 + Double(age) * 400,
                      opacity: 0.75 * Double(min(1, sin(Double(age) * .pi) * 3)))
            }
        case "midnight":
            // (the stars themselves are drawn by Stars) now and then a shooting star
            for i in 0..<2 {
                let (age, seed) = cycle(i, 2, life: 7 + 2 * Double(rnd(i, 0)), t)
                if age > 0.1 { continue }
                let start = CGPoint(x: rnd(seed, 1) * w * 0.6, y: rnd(seed, 2) * h * 0.4)
                shootingStar(&g, from: start, k: age / 0.1, length: w * 0.5)
            }
        default:
            break
        }
    }

    // MARK: Shapes

    private static func petal(_ g: inout GraphicsContext, _ p: CGPoint, size: CGFloat, angle: Double, opacity: Double) {
        var c = g
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: .degrees(angle))
        c.opacity = max(0, opacity)
        var shape = Path()
        shape.move(to: CGPoint(x: -size, y: 0))
        shape.addQuadCurve(to: CGPoint(x: size, y: 0), control: CGPoint(x: 0, y: -size * 1.1))
        shape.addQuadCurve(to: CGPoint(x: -size, y: 0), control: CGPoint(x: 0, y: size * 1.1))
        c.fill(shape, with: .linearGradient(Gradient(colors: [Color.daveCyan, Color.davePurple]),
                                            startPoint: CGPoint(x: -size, y: 0), endPoint: CGPoint(x: size, y: 0)))
    }

    private static func sparkle(_ g: inout GraphicsContext, _ p: CGPoint, _ r: CGFloat, opacity: Double) {
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - r, y: p.y))
        cross.addLine(to: CGPoint(x: p.x + r, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - r))
        cross.addLine(to: CGPoint(x: p.x, y: p.y + r))
        g.stroke(cross, with: .color(.white.opacity(opacity)), lineWidth: 0.8)
    }

    /// A shooting star [k] (0..1) of the way along its path, with a tail.
    private static func shootingStar(_ g: inout GraphicsContext, from start: CGPoint, k: CGFloat, length: CGFloat) {
        let head = CGPoint(x: start.x + length * k, y: start.y + length * 0.45 * k)
        let tailLength = 34 * (1 - abs(k * 2 - 1)) + 6
        let tail = CGPoint(x: head.x - tailLength, y: head.y - tailLength * 0.45)
        let fade = Double(sin(k * .pi))
        var line = Path()
        line.move(to: tail)
        line.addLine(to: head)
        g.stroke(line, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(fade)]), startPoint: tail, endPoint: head),
                 style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        g.fill(circle(head, 1.8), with: .color(.white.opacity(fade)))
    }
}

/// The theme's effect behind everything (the background itself is drawn by AuroraBackground).
struct ThemeBackdrop: View {
    var body: some View {
        ZStack {
            if Theme.current.id == "midnight" { Stars() }
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in ThemeFX.backdrop(&context, size: size, t: t) }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - The glow along the screen's edges

/// Like on the PC: thin neon lines stacked along the screen's edges, drawn in by two orbs. When Dave starts, they leave
/// the bottom middle in opposite directions and race around; the edge lights up behind them and fades away again further
/// back. Faster, with longer trails, while you talk.
struct ScreenGlow: View {
    let state: Brain.State
    let level: Float
    @State private var clock = GlowClock()

    var body: some View {
        let strength: Double = state == .listening ? 1 : state == .thinking ? 0.85 : state == .speaking ? 0.75 : 0
        TimelineView(.animation(paused: strength == 0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                clock.advance(t: t, level: Double(level))
                EdgeLines.draw(&context, size: size, t: t, level: clock.level, travel: clock.travel)
            }
        }
        .opacity(strength)
        .animation(.easeInOut(duration: 0.45), value: strength)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Kept between frames: how far the orbs have gone, and the voice level, smoothed.
final class GlowClock {
    private(set) var travel = 0.0, level = 0.0
    private var last = -10.0, started = 0.0

    func advance(t: Double, level target: Double) {
        if t - last > 0.4 { travel = 0; started = t; level = target; last = t } // appearing (again): the orbs start over
        let dt = min(0.1, t - last)
        last = t
        // follow the voice smoothly: quick to rise, slower to settle
        level += (target - level) * (1 - exp((target > level ? -10 : -3.5) * dt))
        // quick at first (they meet at the top in about two seconds), then cruising
        travel += (0.09 + level * 0.12 + 0.8 * exp(-(t - started) / 0.5)) * dt
    }
}

enum EdgeLines {
    /// The screen's corner radius (iPhone 13).
    static let corner: CGFloat = 47

    private struct Line { let depth, swell, width: CGFloat; let opacity: Double; let waves: [(Double, Double, Double)] }

    private static let lines: [Line] = (0..<6).map { k in
        let s: Double = k % 2 == 0 ? 1 : -1, kk = Double(k)
        return Line(depth: 2.5 + CGFloat(k) * 3.4 + CGFloat(k * k) * 0.2, swell: 1.8 + CGFloat(k) * 0.9, width: 2 - CGFloat(k) * 0.12,
                    opacity: 0.95 - kk * 0.1,
                    waves: [(3 + kk, s * (0.6 + kk * 0.12), 0.5), (7 + kk * 2, -s * (1.1 + kk * 0.1), 0.3), (13 + kk, 1.7, 0.2)])
    }

    static func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, level: Double, travel: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let breathe = 0.9 + 0.1 * sin(t * 1.3)
        let curves = lines.map { line in
            curve(rect, depth: line.depth * CGFloat(breathe * (1 + level * 0.5)), swell: line.swell * CGFloat(1 + level * 2.2), waves: line.waves, t: t)
        }
        let colours = Gradient(colors: [.davePurple, .daveCyan, .davePink, .daveCyan, .davePurple])
        let shading = GraphicsContext.Shading.conicGradient(colours, center: centre, angle: .degrees(t * 30))

        // Where the orbs are, along the edge
        let start = bottomMiddle(rect.insetBy(dx: lines[0].depth, dy: lines[0].depth), radius: radius(lines[0].depth))
        let a = start + travel, b = start - travel
        let orbA = on(curves[0], a), orbB = on(curves[0], b)
        let uA = edgeU(orbA, rect), uB = edgeU(orbB, rect), trail = 0.45 + level * 0.25

        g.drawLayer { layer in
            // A soft glow between and around the lines, so they melt into one band
            layer.drawLayer { glow in
                glow.addFilter(.blur(radius: 7))
                var haze = Path(rect.insetBy(dx: -4, dy: -4))
                haze.addLines(curves[3])
                haze.closeSubpath()
                glow.fill(haze, with: shading, style: FillStyle(eoFill: true))
                for k in curves.indices {
                    var c = glow
                    c.opacity = lines[k].opacity * 0.5
                    c.stroke(closed(curves[k]), with: shading, lineWidth: lines[k].width * 4)
                }
            }
            for k in curves.indices {
                var c = layer
                c.opacity = lines[k].opacity
                c.stroke(closed(curves[k]), with: shading, style: StrokeStyle(lineWidth: lines[k].width, lineJoin: .round))
            }
            // Only where the orbs have just been: a mask that goes around the screen from its middle
            layer.blendMode = .destinationIn
            layer.fill(Path(rect), with: .conicGradient(revealMask(rect, uA: uA, uB: uB, travel: travel, trail: trail), center: centre, angle: .zero))
        }

        orb(&g, curves[0], at: a, direction: 1, colour: .daveCyan, level: level)
        orb(&g, curves[0], at: b, direction: -1, colour: .davePink, level: level)
    }

    /// How visible the edge is all the way around, as a conic gradient from the middle of the screen: for each direction,
    /// the spot where it meets the screen's edge.
    private static func revealMask(_ rect: CGRect, uA: Double, uB: Double, travel: Double, trail: Double) -> Gradient {
        let steps = 240
        let stops: [Gradient.Stop] = (0...steps).map { i in
            let s = Double(i) / Double(steps), angle = s * 2 * .pi
            let d = CGVector(dx: cos(angle), dy: sin(angle))
            let reach = min(abs(d.dx) > 1e-6 ? rect.width / 2 / abs(d.dx) : .infinity, abs(d.dy) > 1e-6 ? rect.height / 2 / abs(d.dy) : .infinity)
            let p = CGPoint(x: rect.midX + d.dx * reach, y: rect.midY + d.dy * reach)
            let u = edgeU(p, rect)
            let v = max(behind(uA - u, travel: travel, trail: trail), behind(u - uB, travel: travel, trail: trail))
            return Gradient.Stop(color: .white.opacity(v), location: s)
        }
        return Gradient(stops: stops)
    }

    /// How visible a spot is that an orb passed [behind] (of a round) ago: full right behind it, fading away further back,
    /// a soft start just in front of it, and nothing where it hasn't been yet.
    private static func behind(_ value: Double, travel: Double, trail: Double) -> Double {
        let x = value - floor(value), ahead = 0.03
        if x > 1 - ahead {
            let a = (x - (1 - ahead)) / ahead
            return a * a * (3 - 2 * a) * min(1, max(0, travel / ahead))
        }
        if x > travel + ahead { return 0 }
        let f = min(1, max(0, 1 - x / trail)), fresh = min(1, max(0, (travel + ahead - x) / ahead))
        return f * f * (3 - 2 * f) * fresh * fresh * (3 - 2 * fresh)
    }

    /// Where a point is along the screen's edge (0..1 clockwise from the top left), seen from the middle of the screen.
    private static func edgeU(_ p: CGPoint, _ rect: CGRect) -> Double {
        let w = Double(rect.width), h = Double(rect.height)
        let dx = Double(p.x - rect.midX), dy = Double(p.y - rect.midY)
        let tx = abs(dx) > 1e-9 ? w / 2 / abs(dx) : .infinity, ty = abs(dy) > 1e-9 ? h / 2 / abs(dy) : .infinity
        let k = min(tx, ty)
        let x = w / 2 + dx * k, y = h / 2 + dy * k, around = 2 * (w + h)
        if ty <= tx { return dy < 0 ? x / around : (w + h + (w - x)) / around } // top / bottom
        return dx > 0 ? (w + y) / around : (2 * w + h + (h - y)) / around        // right / left
    }

    private static func radius(_ depth: CGFloat) -> CGFloat { max(6, corner - depth * 0.8) }

    /// A wavy line around the screen [depth] in from the edge, following its round corners.
    private static func curve(_ rect: CGRect, depth: CGFloat, swell: CGFloat, waves: [(Double, Double, Double)], t: Double) -> [CGPoint] {
        let inner = rect.insetBy(dx: depth, dy: depth), r = radius(depth), n = 260
        return (0..<n).map { i in
            let u = Double(i) / Double(n)
            let (p, normal) = rounded(inner, r, u)
            var wave = 0.0
            for (count, speed, weight) in waves { wave += weight * sin(2 * .pi * count * u + t * speed * 2.2 + count) }
            return CGPoint(x: p.x + normal.dx * CGFloat(wave) * swell, y: p.y + normal.dy * CGFloat(wave) * swell)
        }
    }

    private static func closed(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// A point on a rounded rectangle, [u] going once around clockwise from the top left, with its inward direction.
    private static func rounded(_ r: CGRect, _ radius: CGFloat, _ u: Double) -> (CGPoint, CGVector) {
        let sx = r.width - 2 * radius, sy = r.height - 2 * radius, arc = .pi * radius / 2
        var d = CGFloat(u - floor(u)) * (2 * sx + 2 * sy + 4 * arc)
        func corner(_ cx: CGFloat, _ cy: CGFloat, _ start: Double, _ along: CGFloat) -> (CGPoint, CGVector) {
            let a = start + Double(along / radius)
            let dir = CGVector(dx: cos(a), dy: sin(a))
            return (CGPoint(x: cx + dir.dx * radius, y: cy + dir.dy * radius), CGVector(dx: -dir.dx, dy: -dir.dy))
        }
        if d < sx { return (CGPoint(x: r.minX + radius + d, y: r.minY), CGVector(dx: 0, dy: 1)) }
        d -= sx
        if d < arc { return corner(r.maxX - radius, r.minY + radius, -.pi / 2, d) }
        d -= arc
        if d < sy { return (CGPoint(x: r.maxX, y: r.minY + radius + d), CGVector(dx: -1, dy: 0)) }
        d -= sy
        if d < arc { return corner(r.maxX - radius, r.maxY - radius, 0, d) }
        d -= arc
        if d < sx { return (CGPoint(x: r.maxX - radius - d, y: r.maxY), CGVector(dx: 0, dy: -1)) }
        d -= sx
        if d < arc { return corner(r.minX + radius, r.maxY - radius, .pi / 2, d) }
        d -= arc
        if d < sy { return (CGPoint(x: r.minX, y: r.maxY - radius - d), CGVector(dx: 1, dy: 0)) }
        d -= sy
        return corner(r.minX + radius, r.minY + radius, .pi, d)
    }

    /// Where the bottom middle is along such a rounded rectangle.
    private static func bottomMiddle(_ r: CGRect, radius: CGFloat) -> Double {
        let sx = r.width - 2 * radius, sy = r.height - 2 * radius, arc = .pi * radius / 2
        return Double((sx + arc + sy + arc + sx / 2) / (2 * sx + 2 * sy + 4 * arc))
    }

    /// The point [u] of a round along a line, in between its points too (so the orbs glide).
    private static func on(_ points: [CGPoint], _ u: Double) -> CGPoint {
        let n = points.count
        var i = (u - floor(u)) * Double(n)
        if i >= Double(n) { i -= Double(n) }
        let a = Int(i), f = CGFloat(i - Double(a))
        let p0 = points[a % n], p1 = points[(a + 1) % n]
        return CGPoint(x: p0.x + (p1.x - p0.x) * f, y: p0.y + (p1.y - p0.y) * f)
    }

    /// A ball of light (a coloured glow with a white core) going in [direction], with a tail fading out behind it.
    private static func orb(_ g: inout GraphicsContext, _ points: [CGPoint], at u: Double, direction: Double, colour: Color, level: Double) {
        let n = Double(points.count), tail = 22
        for j in stride(from: tail, through: 1, by: -1) {
            let p0 = on(points, u - direction * Double(j) / n), p1 = on(points, u - direction * Double(j - 1) / n)
            let f = 1 - Double(j) / Double(tail)
            var piece = Path()
            piece.move(to: p0)
            piece.addLine(to: p1)
            g.stroke(piece, with: .color(colour.opacity(0.32 * f * f)), lineWidth: CGFloat(12 * f + 2))
            g.stroke(piece, with: .color(ThemeFX.mix(colour, .white, CGFloat(f)).opacity(0.9 * f)), lineWidth: CGFloat(1.5 + 3 * f * (1 + level)))
        }
        let p = on(points, u)
        let r = CGFloat(16 + level * 10)
        g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
               with: .radialGradient(Gradient(colors: [ThemeFX.mix(colour, .white, 0.6).opacity(0.85), colour.opacity(0)]), center: p, startRadius: 0, endRadius: r))
        let core = r * 0.32
        g.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)),
               with: .radialGradient(Gradient(colors: [.white, .white.opacity(0.9), .white.opacity(0)]), center: p, startRadius: 0, endRadius: core))
    }
}
