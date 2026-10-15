import SwiftUI
import VoiceCore

/// The orb: four coloured blobs turning around a white core. Their colours and their movement say who is
/// speaking, without a word: cold and drawn inwards while the user speaks, warm and pushed outwards while
/// Maé speaks. Everything is computed from the time at each frame, like the design's CSS animations, and
/// stops moving (but still changes colour) with "Reduce motion".
struct Orb<Core: View>: View {
    let look: OrbLook
    var style = OrbStyle.conversation
    /// Sound level (0…1) of whoever is speaking: it drives the blobs' breathing and the voice bars.
    var level: Float = 0
    /// What the white core shows instead of the voice bars (first launch).
    @ViewBuilder var core: Core

    @State private var animator = OrbAnimator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Fixed moment of the animation, for still pictures.
    @Environment(\.stillFrame) private var stillFrame
    @Environment(\.windowIsVisible) private var windowIsVisible

    var body: some View {
        // 60 frames per second while someone speaks (ripples, voice bars), 30 for the slow movements at rest and
        // for the capsule's small orb; none while the window cannot be seen.
        TimelineView(.animation(minimumInterval: look.ripples == .none ? 1 / 30 : 1 / 60,
                                paused: stillFrame != nil || !windowIsVisible))
        { timeline in
            let time = stillFrame ?? timeline.date.timeIntervalSinceReferenceDate
            let frame = animator.frame(at: time, look: look, style: style, level: Double(level),
                                       frozen: stillFrame != nil)
            ZStack {
                // The ripples and the floor shadow go beyond the stage: the canvas is larger than it. Drawn on
                // its own layer, so the rest of the window is not redrawn at every frame.
                Canvas(rendersAsynchronously: true) { context, size in
                    OrbPainter(style: style, frame: frame, time: time, reduceMotion: reduceMotion)
                        .draw(in: &context, size: size)
                }
                .frame(width: style.stage + 2 * style.margin, height: style.stage + 2 * style.margin)
                core.offset(y: OrbPainter.lift(at: time, style: style, reduceMotion: reduceMotion))
            }
        }
        .frame(width: style.stage, height: style.stage)
        .accessibilityHidden(true)
    }
}

extension Orb where Core == EmptyView {
    init(look: OrbLook, style: OrbStyle = .conversation, level: Float = 0) {
        self.init(look: look, style: style, level: level) { EmptyView() }
    }
}

extension EnvironmentValues {
    /// Set for still pictures of the screens: the moment the animations show, and the transcript complete.
    @Entry var stillFrame: Double?
}

/// What the orb shows: the target of every animated value. Changing it starts the transitions.
struct OrbLook: Equatable {
    enum Ripples { case none, inwards, outwards }

    var blobs: [RGBA]
    var glow: RGBA
    var bar: RGBA
    /// Distance of the blobs from the centre, on the design's stage.
    var radius: CGFloat
    /// Breathing of each blob (scale 1 ± breathing).
    var breathing: Double
    /// 0: the voice bars are dots, 1: they move like a voice.
    var bars: Double
    /// 1: the dots hop one after the other (thinking).
    var hop: Double
    /// Breathing of the white core.
    var core: Double
    var ripples = Ripples.none
    /// Someone speaks: the sound level drives the breathing and the voice bars.
    var followsVoice = false
    /// Coloured dots flying into the orb (first launch, while downloading).
    var particles = false

    /// The conversation's four states.
    init(_ state: PipelineState) {
        let palette = StatePalette(state)
        blobs = palette.blobs
        glow = palette.glow
        bar = palette.bar
        switch state {
        case .listening: (radius, breathing, bars, hop, core) = (28, 0.025, 0, 0, 0.02)
        case .userSpeaking: (radius, breathing, bars, hop, core, ripples) = (32, 0.06, 1, 0, 0.07, .inwards)
        case .thinking: (radius, breathing, bars, hop, core) = (80, 0.03, 0, 1, 0.02)
        case .speaking: (radius, breathing, bars, hop, core, ripples) = (54, 0.13, 1, 0, 0.05, .outwards)
        }
        followsVoice = ripples != .none
    }

    /// The capsule's small orb: closer orbits (5, 9 and 7 points) so that the blobs stay inside the capsule, and no
    /// ripples (they go around the capsule instead).
    static func capsule(_ state: PipelineState) -> OrbLook {
        var look = OrbLook(state)
        look.ripples = .none
        switch state {
        case .listening, .userSpeaking: (look.radius, look.breathing, look.core) = (5, 0.07, 0.08)
        case .thinking: (look.radius, look.breathing, look.core) = (9, 0.04, 0.03)
        case .speaking: (look.radius, look.breathing, look.core) = (7, 0.14, 0.06)
        }
        return look
    }

    /// First launch: pastels before the download, bright colours while it runs.
    static func setup(downloading: Bool) -> OrbLook {
        var look = OrbLook(.listening)
        if downloading {
            look.blobs = [Palette.coral, Palette.sun, Palette.turquoise, Palette.azure]
            look.glow = Palette.sun
        }
        look.radius = downloading ? 30 : 20
        look.breathing = downloading ? 0.07 : 0.04
        look.core = 0
        look.particles = downloading
        return look
    }
}

/// Geometry and timings of one orb: the conversation's (380-point stage), the first launch's (190) or the
/// capsule's (64).
struct OrbStyle {
    /// The five bars inside the white core: their width and spacing, their height at rest, the low and high
    /// points of their wave, and how high they hop while Maé thinks.
    struct VoiceBars {
        var width, gap, rest, low, high, hop: CGFloat
    }

    var stage: CGFloat
    var blob: CGFloat
    var coreDiameter: CGFloat
    /// Soft shadows below the core: opacity, blur radius and offset down.
    var coreShadows: [(opacity: Double, radius: CGFloat, y: CGFloat)] = [(0.14, 17, 14), (0.06, 3, 2)]
    var floor: CGSize
    var floorBottom: CGFloat
    var floorBlur: CGFloat
    var floorShrink: Double
    /// 0: no floor shadow.
    var floorOpacity = 0.4
    /// Vertical float: from `float.0` (up) to `float.1` (down) and back, in 6 s.
    var float: (Double, Double)
    var orbitSeconds: Double
    /// Breathing period and delay of each blob.
    var talk: [(period: Double, delay: Double)]
    var radiusSeconds: Double
    var breathingSeconds: Double
    var voiceBars: VoiceBars?
    /// Room around the stage for what goes beyond it: ripples, floor shadow, blobs at their widest.
    var margin: CGFloat = 80

    static let conversation = OrbStyle(
        stage: 380, blob: 208, coreDiameter: 140, floor: CGSize(width: 200, height: 28), floorBottom: 4,
        floorBlur: 18, floorShrink: 0.82, float: (-6, 8), orbitSeconds: 24,
        talk: [(0.95, 0), (1.25, -0.4), (0.8, -0.2), (1.1, -0.7)], radiusSeconds: 1.1, breathingSeconds: 0.9,
        voiceBars: VoiceBars(width: 10, gap: 8, rest: 10, low: 6, high: 40, hop: 13))

    static let setup = OrbStyle(
        stage: 190, blob: 108, coreDiameter: 96, floor: CGSize(width: 130, height: 20), floorBottom: 0,
        floorBlur: 14, floorShrink: 0.84, float: (-4, 6), orbitSeconds: 26,
        talk: [(1.9, 0), (2.4, -1), (1.6, -0.6), (2.1, -0.3)], radiusSeconds: 1, breathingSeconds: 0.8)

    /// No floor shadow and no float: the orb sits still in its glass.
    static let capsule = OrbStyle(
        stage: 64, blob: 40, coreDiameter: 34, coreShadows: [(0.2, 5, 4)], floor: .zero, floorBottom: 0,
        floorBlur: 0, floorShrink: 1, floorOpacity: 0, float: (0, 0), orbitSeconds: 14,
        talk: [(0.95, 0), (1.25, -0.4), (0.8, -0.2), (1.1, -0.7)], radiusSeconds: 1, breathingSeconds: 0.9,
        voiceBars: VoiceBars(width: 3, gap: 2.5, rest: 3, low: 2, high: 14, hop: 5), margin: 12)
}

// MARK: - Animated values

/// A value moving towards its target, like a CSS transition: a change in the middle starts from where the
/// value is.
private struct Tween<Value> {
    var from: Value
    var to: Value
    var start = -Double.infinity
    var duration = 0.0
    var curve = Easing.ease

    init(_ value: Value) {
        from = value
        to = value
    }

    func value(at time: Double, _ mix: (Value, Value, Double) -> Value) -> Value {
        guard duration > 0, time < start + duration else { return to }
        return mix(from, to, curve(max(0, time - start) / duration))
    }

    mutating func retarget(_ target: Value, at time: Double, duration: Double, curve: CubicBezier,
                           _ mix: (Value, Value, Double) -> Value)
    {
        from = value(at: time, mix)
        to = target
        start = time
        self.duration = duration
        self.curve = curve
    }
}

private func mixNumber(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func mixColor(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA { a.mixed(with: b, t) }

/// The values of one frame.
fileprivate struct OrbFrame {
    var blobs: [RGBA]
    var glow: RGBA
    var ringColor: RGBA
    var bar: RGBA
    var radius: Double
    var breathing: Double
    var bars: Double
    var hop: Double
    var core: Double
    var ripplesIn: Double
    var ripplesOut: Double
    var particles: Double
    /// Scale of the bounce at the last change of state.
    var pop: Double
}

/// Keeps the transitions between frames. Not observed: it changes while the view draws.
@MainActor
private final class OrbAnimator {
    private var look: OrbLook?
    private var blobs: [Tween<RGBA>] = []
    private var glow = Tween(RGBA(0))
    private var ringColor = Tween(RGBA(0))
    private var bar = Tween(RGBA(0))
    private var radius = Tween(0.0)
    private var breathing = Tween(0.0)
    private var bars = Tween(0.0)
    private var hop = Tween(0.0)
    private var core = Tween(0.0)
    private var ripplesIn = Tween(0.0)
    private var ripplesOut = Tween(0.0)
    private var particles = Tween(0.0)
    private var popStart = -Double.infinity
    private var voice = 0.0
    private var lastTime: Double?

    func frame(at time: Double, look target: OrbLook, style: OrbStyle, level: Double, frozen: Bool) -> OrbFrame {
        if look == nil || frozen && look != target {
            start(target, at: time)
            if frozen { popStart = -Double.infinity }  // a still picture shows the end of every transition
        } else if look != target {
            change(to: target, at: time, style: style)
        }
        // The sound level drives the bars and the breathing; quick to rise, slower to fall.
        let heard = min(max((level - 0.2) / 0.5, 0), 1)
        if frozen {
            voice = heard
        } else {
            let elapsed = min(max(time - (lastTime ?? time), 0), 0.1)
            voice += (heard - voice) * (1 - exp(-elapsed / (heard > voice ? 0.06 : 0.25)))
        }
        lastTime = time
        let follows = target.followsVoice  // someone is speaking: the level is meaningful
        let breathingValue = breathing.value(at: time, mixNumber)
        return OrbFrame(
            blobs: blobs.map { $0.value(at: time, mixColor) },
            glow: glow.value(at: time, mixColor),
            ringColor: ringColor.value(at: time, mixColor),
            bar: bar.value(at: time, mixColor),
            radius: radius.value(at: time, mixNumber),
            breathing: follows ? breathingValue * (0.35 + 0.65 * voice) : breathingValue,
            bars: bars.value(at: time, mixNumber) * (follows ? voice : 1),
            hop: hop.value(at: time, mixNumber),
            core: core.value(at: time, mixNumber),
            ripplesIn: ripplesIn.value(at: time, mixNumber),
            ripplesOut: ripplesOut.value(at: time, mixNumber),
            particles: particles.value(at: time, mixNumber),
            pop: Self.pop(time - popStart))
    }

    private func start(_ look: OrbLook, at time: Double) {
        self.look = look
        blobs = look.blobs.map { Tween($0) }
        glow = Tween(look.glow)
        ringColor = Tween(look.glow)
        bar = Tween(look.bar)
        radius = Tween(Double(look.radius))
        breathing = Tween(look.breathing)
        bars = Tween(look.bars)
        hop = Tween(look.hop)
        core = Tween(look.core)
        ripplesIn = Tween(look.ripples == .inwards ? 1 : 0)
        ripplesOut = Tween(look.ripples == .outwards ? 1 : 0)
        particles = Tween(look.particles ? 1 : 0)
        popStart = time  // the orb bounces when it appears
    }

    private func change(to look: OrbLook, at time: Double, style: OrbStyle) {
        self.look = look
        for i in blobs.indices {
            blobs[i].retarget(look.blobs[i], at: time, duration: Timing.color, curve: Easing.ease, mixColor)
        }
        glow.retarget(look.glow, at: time, duration: 0.5, curve: Easing.ease, mixColor)
        ringColor.retarget(look.glow, at: time, duration: 0.4, curve: Easing.ease, mixColor)
        bar.retarget(look.bar, at: time, duration: 0.4, curve: Easing.ease, mixColor)
        radius.retarget(Double(look.radius), at: time, duration: style.radiusSeconds, curve: Easing.spring,
                        mixNumber)
        breathing.retarget(look.breathing, at: time, duration: style.breathingSeconds, curve: Easing.ease,
                           mixNumber)
        bars.retarget(look.bars, at: time, duration: 0.6, curve: Easing.ease, mixNumber)
        hop.retarget(look.hop, at: time, duration: 0.6, curve: Easing.ease, mixNumber)
        core.retarget(look.core, at: time, duration: 0.8, curve: Easing.ease, mixNumber)
        ripplesIn.retarget(look.ripples == .inwards ? 1 : 0, at: time, duration: 0.7, curve: Easing.ease, mixNumber)
        ripplesOut.retarget(look.ripples == .outwards ? 1 : 0, at: time, duration: 0.7, curve: Easing.ease,
                            mixNumber)
        particles.retarget(look.particles ? 1 : 0, at: time, duration: 0.6, curve: Easing.ease, mixNumber)
        popStart = time
    }

    /// The bounce: folds to 60 %, overshoots to 107 %, settles; the colours change while it is folded.
    private static func pop(_ elapsed: Double) -> Double {
        Keyframes.value(at: elapsed / Timing.pop, [(0, 1), (0.3, 0.6), (0.7, 1.07), (1, 1)], curve: Easing.pop)
    }
}

/// CSS-like keyframes: `(offset, value)` pairs, the curve applied within each interval.
enum Keyframes {
    static func value(at progress: Double, _ frames: [(Double, Double)], curve: CubicBezier = Easing.smooth)
        -> Double
    {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if progress <= first.0 { return first.1 }
        if progress >= last.0 { return last.1 }
        for (a, b) in zip(frames, frames.dropFirst()) where progress <= b.0 {
            let t = curve((progress - a.0) / (b.0 - a.0))
            return a.1 + (b.1 - a.1) * t
        }
        return last.1
    }

    /// Progress (0…1) of a looping animation of `period` seconds that started `delay` seconds late.
    static func loop(_ time: Double, period: Double, delay: Double = 0) -> Double {
        let x = (time - delay) / period
        return x - x.rounded(.down)
    }

    /// Same, playing forwards then backwards (CSS `alternate`).
    static func alternate(_ time: Double, period: Double, delay: Double) -> Double {
        let x = (time - delay) / period
        let cycle = x - 2 * (x / 2).rounded(.down)
        return cycle <= 1 ? cycle : 2 - cycle
    }
}

// MARK: - Drawing

fileprivate struct OrbPainter {
    let style: OrbStyle
    let frame: OrbFrame
    let time: Double
    let reduceMotion: Bool

    /// The design's blob shape at the three steps of its morphing: CSS border radii in %, horizontal then
    /// vertical (top-left, top-right, bottom-right, bottom-left), and a rotation.
    private static let morph: [(radii: [Double], rotation: Double)] = [
        ([58, 42, 55, 45, 48, 58, 42, 52], 0),
        ([44, 56, 40, 60, 58, 44, 56, 42], 24),
        ([54, 46, 60, 40, 42, 56, 44, 58], -18),
    ]
    /// Morphing period and delay of each blob, and its distance factor on its arm.
    private static let blobs: [(period: Double, delay: Double, reach: Double)] = [
        (7, 0, 1), (9, -3, 0.8), (8, -5, 1.15), (6.5, -2, 0.92),
    ]

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let s = (size.width - 2 * style.margin) / style.stage
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let still = reduceMotion

        // Floor shadow: the only blur of the orb.
        if style.floorOpacity > 0 {
            let floorScale = still ? 1 : Keyframes.value(at: Keyframes.loop(time, period: 6),
                                                         [(0, 1), (0.5, style.floorShrink), (1, 1)])
            let floorWidth = style.floor.width * s * floorScale, floorHeight = style.floor.height * s * floorScale
            let floorCenter = CGPoint(x: center.x,
                                      y: center.y + (style.stage / 2 - style.floorBottom - style.floor.height / 2) * s)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: style.floorBlur * s))
                layer.opacity = style.floorOpacity
                layer.fill(Path(ellipseIn: CGRect(x: floorCenter.x - floorWidth / 2,
                                                  y: floorCenter.y - floorHeight / 2,
                                                  width: floorWidth, height: floorHeight)),
                           with: .color(frame.glow.color))
            }
        }

        // The orb floats up and down.
        let orbCenter = CGPoint(x: center.x, y: center.y + Self.lift(at: time, style: style, reduceMotion: still) * s)

        drawRipples(in: &context, center: orbCenter, scale: s)
        drawBlobs(in: &context, center: orbCenter, scale: s)
        if frame.particles > 0.001, !still { drawParticles(in: &context, center: orbCenter, scale: s) }
        drawCore(in: &context, center: orbCenter, scale: s)
    }

    private func drawRipples(in context: inout GraphicsContext, center: CGPoint, scale s: CGFloat) {
        for (visibility, inwards) in [(frame.ripplesOut, false), (frame.ripplesIn, true)] where visibility > 0.001 {
            for ring in 0..<3 {
                let p = Keyframes.loop(time, period: 3, delay: Double(ring))
                let grow = Easing.ripple(p)
                let ringScale = inwards ? 1.8 + (0.8 - 1.8) * grow : 0.8 + (1.75 - 0.8) * grow
                let peak = inwards ? 0.35 : 0.14
                let opacity = Keyframes.value(at: p, [(0, 0), (peak, inwards ? 0.65 : 0.6), (1, 0)],
                                              curve: Easing.ripple)
                let radius = (122 - 1.25) * ringScale * s
                let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: 2 * radius, height: 2 * radius))
                context.stroke(circle, with: .color(frame.ringColor.opacity(opacity * visibility).color),
                               lineWidth: 2.5 * ringScale * s)
            }
        }
    }

    private func drawBlobs(in context: inout GraphicsContext, center: CGPoint, scale s: CGFloat) {
        let orbit = reduceMotion ? 0 : Keyframes.loop(time, period: style.orbitSeconds) * 2 * .pi
        for (i, blob) in Self.blobs.enumerated() {
            let arm = orbit + Double(i) * .pi / 2
            let reach = frame.radius * blob.reach * frame.pop * Double(s)
            let position = CGPoint(x: center.x + cos(arm) * reach, y: center.y + sin(arm) * reach)
            // Morphing: radii and rotation move between the three steps, forwards then backwards.
            let step = reduceMotion ? 0 : Keyframes.alternate(time, period: blob.period, delay: blob.delay)
            let (radii, rotation) = Self.morphShape(at: step)
            let talk = style.talk[i]
            let breathing = Keyframes.value(at: Keyframes.loop(time, period: talk.period, delay: talk.delay),
                                            [(0, 1 - frame.breathing), (0.5, 1 + frame.breathing),
                                             (1, 1 - frame.breathing)])
            let side = style.blob * s * breathing * frame.pop
            let shape = Self.blobPath(size: side, radii: radii)
                .applying(CGAffineTransform(rotationAngle: arm + rotation * .pi / 180))
                .applying(CGAffineTransform(translationX: position.x, y: position.y))
            context.fill(shape, with: .color(frame.blobs[i].color))
        }
    }

    /// Vertical float of the orb, in points of the stage.
    static func lift(at time: Double, style: OrbStyle, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return Keyframes.value(at: Keyframes.loop(time, period: 6),
                               [(0, style.float.0), (0.5, style.float.1), (1, style.float.0)])
    }

    private static func morphShape(at step: Double) -> ([Double], Double) {
        let index = step <= 0.5 ? 0 : 1
        let t = Easing.smooth(step <= 0.5 ? step / 0.5 : (step - 0.5) / 0.5)
        let a = morph[index], b = morph[index + 1]
        let radii = zip(a.radii, b.radii).map { $0 + ($1 - $0) * t }
        return (radii, a.rotation + (b.rotation - a.rotation) * t)
    }

    /// A square of side `size`, centred on the origin, with CSS elliptical corner radii (in %).
    private static func blobPath(size: CGFloat, radii r: [Double]) -> Path {
        let half = size / 2
        let k: CGFloat = 0.5523  // quarter ellipse as a Bézier curve
        let h = r[0..<4].map { CGFloat($0) / 100 * size }  // top-left, top-right, bottom-right, bottom-left
        let v = r[4..<8].map { CGFloat($0) / 100 * size }
        let left = -half, right = half, top = -half, bottom = half
        var path = Path()
        path.move(to: CGPoint(x: left + h[0], y: top))
        path.addLine(to: CGPoint(x: right - h[1], y: top))
        path.addCurve(to: CGPoint(x: right, y: top + v[1]),
                      control1: CGPoint(x: right - h[1] + k * h[1], y: top),
                      control2: CGPoint(x: right, y: top + v[1] - k * v[1]))
        path.addLine(to: CGPoint(x: right, y: bottom - v[2]))
        path.addCurve(to: CGPoint(x: right - h[2], y: bottom),
                      control1: CGPoint(x: right, y: bottom - v[2] + k * v[2]),
                      control2: CGPoint(x: right - h[2] + k * h[2], y: bottom))
        path.addLine(to: CGPoint(x: left + h[3], y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom - v[3]),
                      control1: CGPoint(x: left + h[3] - k * h[3], y: bottom),
                      control2: CGPoint(x: left, y: bottom - v[3] + k * v[3]))
        path.addLine(to: CGPoint(x: left, y: top + v[0]))
        path.addCurve(to: CGPoint(x: left + h[0], y: top),
                      control1: CGPoint(x: left, y: top + v[0] - k * v[0]),
                      control2: CGPoint(x: left + h[0] - k * h[0], y: top))
        path.closeSubpath()
        return path
    }

    /// First launch: dots of the four colours flying into the orb, from every side.
    private func drawParticles(in context: inout GraphicsContext, center: CGPoint, scale s: CGFloat) {
        let colors = [Palette.coral, Palette.sun, Palette.turquoise, Palette.azure]
        let delays = [0, -1.5, -0.7, -2.1, -1.1, -0.3, -1.8, -0.9]
        let curve = CubicBezier(0.45, 0, 0.75, 0.4)
        for (i, delay) in delays.enumerated() {
            let p = Keyframes.loop(time, period: 2.4, delay: delay)
            let distance = (106 + (48 - 106) * curve(p)) * s
            let opacity = Keyframes.value(at: p, [(0, 0), (0.22, 1), (0.85, 1), (1, 0)], curve: curve)
            let dotScale = Keyframes.value(at: p, [(0, 0.5), (0.22, 1), (1, 0.4)], curve: curve)
            let angle = Double(i) * .pi / 4
            let dot = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let radius = 4.5 * dotScale * s
            context.fill(Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius, width: 2 * radius,
                                                height: 2 * radius)),
                         with: .color(colors[i % 4].opacity(opacity * frame.particles).color))
        }
    }

    private func drawCore(in context: inout GraphicsContext, center: CGPoint, scale s: CGFloat) {
        let breathing = Keyframes.value(at: Keyframes.loop(time, period: 1.3),
                                        [(0, 1 - frame.core), (0.5, 1 + frame.core), (1, 1 - frame.core)])
        let radius = style.coreDiameter / 2 * s * breathing
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius,
                                          height: 2 * radius))
        // shadow-core: soft shadows below the white disc.
        for shadow in style.coreShadows {
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: Palette.ink.opacity(shadow.opacity).color, radius: shadow.radius * s,
                                        x: 0, y: shadow.y * s))
                layer.fill(disc, with: .color(.white))
            }
        }
        guard let voice = style.voiceBars else { return }

        // Five voice bars: dots at rest, a wave while someone speaks, hopping one after the other while
        // Maé thinks.
        let bars: [(reach: Double, period: Double, delay: Double)] = [
            (0.55, 0.72, -0.3), (0.85, 0.55, -0.1), (1, 0.9, -0.5), (0.8, 0.63, -0.2), (0.6, 0.8, -0.4),
        ]
        let unit = s * breathing  // the bars sit inside the core and breathe with it
        let width = voice.width * unit, gap = voice.gap * unit
        var x = center.x - (5 * width + 4 * gap) / 2
        for (i, bar) in bars.enumerated() {
            let wave = Keyframes.value(at: Keyframes.loop(time, period: bar.period, delay: bar.delay),
                                       [(0, voice.low), (0.5, voice.high), (1, voice.low)])
            let height = (voice.rest + frame.bars * bar.reach * wave) * unit
            let hop = Keyframes.value(at: Keyframes.loop(time, period: 1.3, delay: Double(i) * 0.13),
                                      [(0, 0), (0.28, -voice.hop), (0.55, 0), (1, 0)]) * frame.hop * unit
            let rect = CGRect(x: x, y: center.y - height / 2 + hop, width: width, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: min(width, height) / 2),
                         with: .color(frame.bar.color))
            x += width + gap
        }
    }
}

// MARK: - Halos

/// The two flat white discs behind the orb, breathing slowly.
struct OrbHalos: View {
    var inner: CGFloat = 560
    var outer: CGFloat = 800
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.stillFrame) private var stillFrame

    var body: some View {
        ZStack {
            Circle().fill(Palette.haloOuter).frame(width: outer, height: outer)
            Circle().fill(Palette.halo).frame(width: inner, height: inner)
        }
        .scaleEffect(grown ? 1.035 : 1)
        .frame(width: outer, height: outer)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .repeatsWhileVisible($grown, .easeInOut(duration: 3.5), enabled: !reduceMotion && stillFrame == nil)
    }
}
