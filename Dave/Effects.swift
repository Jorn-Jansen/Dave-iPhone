import CoreMotion
import SwiftUI
import UIKit

// The effects around Dave (not in the Legacy theme): the sound ring, sparks and comets around the orb, the Siri-like glow along
// the screen's edges, stars that move when you tilt the phone, the thinking orbs, and little taps you feel.

/// Around the big orb: a ring of bars that moves with your voice, ripples while you talk, sparks orbiting it, and two comets
/// racing around it while Dave thinks. Drawn around a 96-point orb, in a bigger square.
struct OrbEffects: View {
    let state: Brain.State
    let level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let r: CGFloat = 48
                let voice = CGFloat(level)
                let colours: [Color] = [.davePurple, .davePink, .daveCyan, .daveViolet]

                // Ripples spreading out while you talk
                if state == .listening {
                    for k in 0..<3 {
                        let phase = (t * 0.75 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                        let radius = r + 10 + CGFloat(phase) * 62
                        let fade = (1 - phase) * (1 - phase)
                        context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                                       with: .color(Color.daveCyan.opacity(fade * (0.25 + Double(voice) * 0.7))), lineWidth: 1 + 2.5 * (1 - phase))
                    }
                }

                // The sound ring: bars that dance with your voice (listening) or gently while Dave talks
                if state == .listening || state == .speaking {
                    let bars = 56
                    for i in 0..<bars {
                        let a = Double(i) / Double(bars) * 2 * .pi + t * 0.4
                        let wobble = 0.5 + 0.5 * sin(t * 5.5 + Double(i) * 0.8)
                        let amount = state == .listening ? voice : 0.28 + 0.22 * CGFloat(sin(t * 6.3 + Double(i) * 0.45))
                        let length = 3 + amount * 30 * CGFloat(0.55 + 0.45 * wobble) + 2 * CGFloat(wobble)
                        var bar = Path()
                        bar.move(to: point(centre, a, r + 8))
                        bar.addLine(to: point(centre, a, r + 8 + length))
                        let colour = colours[(i * colours.count / bars) % colours.count]
                        context.stroke(bar, with: .color(colour.opacity(0.32)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        context.stroke(bar, with: .color(colour), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    }
                }

                // Sparks orbiting the orb: a few when idle, more and faster when he's busy
                let sparks = state == .idle ? 6 : 14
                for i in 0..<sparks {
                    let speed = (0.5 + Double(i % 5) * 0.14) * (state == .thinking ? 2.6 : state == .idle ? 0.7 : 1.3) * (i % 2 == 0 ? 1 : -1)
                    let a = t * speed + Double(i) * 2.4
                    let radius = r + 16 + CGFloat(i % 4) * 9 + CGFloat(sin(t * 1.3 + Double(i))) * 4
                    let p = point(centre, a, radius)
                    let s = 1.3 + CGFloat(i % 3) * 0.8
                    let colour = colours[i % colours.count]
                    context.fill(Path(ellipseIn: CGRect(x: p.x - s * 4, y: p.y - s * 4, width: s * 8, height: s * 8)), with: .color(colour.opacity(0.22)))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2)), with: .color(.white.opacity(0.9)))
                }

                // Thinking: two comets racing around the orb, with fading tails
                if state == .thinking {
                    for k in 0..<2 {
                        let head = t * 2.6 + Double(k) * .pi
                        for j in 0..<26 {
                            let f = 1 - Double(j) / 26
                            let p = point(centre, head - Double(j) * 0.07, r + 5)
                            let s = 0.8 + 3 * CGFloat(f)
                            context.fill(Path(ellipseIn: CGRect(x: p.x - s * 2.5, y: p.y - s * 2.5, width: s * 5, height: s * 5)),
                                         with: .color((k == 0 ? Color.daveCyan : Color.davePink).opacity(0.25 * f)))
                            context.fill(Path(ellipseIn: CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2)), with: .color(.white.opacity(f)))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func point(_ c: CGPoint, _ angle: Double, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: c.x + CGFloat(cos(angle)) * radius, y: c.y + CGFloat(sin(angle)) * radius)
    }
}

/// Like Siri: light glowing along the edges of the screen while Dave listens (moving with your voice), thinks or talks.
struct ScreenGlow: View {
    let state: Brain.State
    let level: Float

    var body: some View {
        let strength: Double = state == .listening ? 1 : state == .thinking ? 0.65 : state == .speaking ? 0.4 : 0
        TimelineView(.animation(paused: strength == 0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let gradient = AngularGradient(colors: [.davePurple, .davePink, .daveCyan, .daveViolet, .davePurple], center: .center,
                                           angle: .degrees(t * 80))
            let width = 8 + CGFloat(state == .listening ? level : 0.15) * 16
            ZStack {
                RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(gradient, lineWidth: width).blur(radius: 14)
                RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(gradient, lineWidth: 2.5).blur(radius: 1.5)
            }
        }
        .opacity(strength)
        .animation(.easeInOut(duration: 0.45), value: strength)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// How the phone is tilted (smoothed), so the background can move along: depth, like looking through a window.
final class Tilt: ObservableObject {
    static let shared = Tilt()
    @Published var x: CGFloat = 0
    @Published var y: CGFloat = 0
    private let motion = CMMotionManager()

    private init() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            self.x += (CGFloat(g.x) - self.x) * 0.12
            self.y += (CGFloat(g.y + 0.6) - self.y) * 0.12 // held upright is the middle
        }
    }
}

/// Stars that twinkle, at different depths: the far ones move less when you tilt the phone.
struct Stars: View {
    @ObservedObject private var tilt = Tilt.shared
    private static let field: [(x: CGFloat, y: CGFloat, depth: CGFloat, size: CGFloat, phase: Double)] = (0..<70).map { i in
        func r(_ k: Int) -> CGFloat { CGFloat((sin(Double(i * 7919 + k * 104729)) + 1) / 2) } // the same stars every time
        return (r(1), r(2), 0.3 + r(3) * 0.7, 0.5 + r(4) * 1.3, Double(r(5)) * 6.28)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for s in Self.field {
                    let twinkle = 0.45 + 0.55 * sin(t * (1 + Double(s.depth)) + s.phase)
                    let x = s.x * size.width - tilt.x * 26 * s.depth, y = s.y * size.height + tilt.y * 26 * s.depth
                    context.fill(Path(ellipseIn: CGRect(x: x - s.size, y: y - s.size, width: s.size * 2, height: s.size * 2)),
                                 with: .color(.white.opacity((0.2 + 0.6 * twinkle) * Double(s.depth))))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Dave is thinking: three little orbs bouncing in a wave, in a glass bubble in the chat.
struct ThinkingOrbs: View {
    var body: some View {
        HStack {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 7) {
                    ForEach(0..<3) { i in
                        let hop = max(0, sin(t * 6 - Double(i) * 0.8))
                        Circle()
                            .fill(RadialGradient(colors: [.white, .daveCyan, .davePurple], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 7))
                            .frame(width: 10, height: 10)
                            .shadow(color: .daveCyan.opacity(0.8), radius: 6)
                            .scaleEffect(1 + 0.25 * hop)
                            .offset(y: -7 * hop)
                            .opacity(0.55 + 0.45 * hop)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.daveCyan.opacity(0.35)))
                .shadow(color: .davePurple.opacity(0.35), radius: 14)
            }
            Spacer()
        }
        .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
    }
}

/// How a new message arrives: from a blur, a bit lower and smaller, springing into place.
struct Arrive: ViewModifier {
    let active: Bool
    let fromUser: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 8 : 0)
            .scaleEffect(active ? 0.9 : 1, anchor: fromUser ? .bottomTrailing : .bottomLeading)
            .offset(x: active && fromUser ? 30 : 0, y: active ? 14 : 0)
            .opacity(active ? 0 : 1)
    }
}

/// Little taps you feel: when Dave starts and stops listening, and when his answer arrives.
enum Haptics {
    static func listen() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heard() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func answer() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.8) }
}
