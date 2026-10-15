import AppKit
import SwiftUI
import VoiceCore

/// OpenMaé's icon in the menu bar, its only presence once the window is closed: an outline at rest, which macOS
/// tints like its own icons on a light or dark bar; a disc of the state's colour with three breathing bars while
/// Maé listens, thinks or speaks. Its menu brings the window back or quits.
@MainActor
final class MenuBarIcon {
    let item: NSStatusItem
    private let activeIcon = ActiveMenuBarIcon()
    /// nil: at rest.
    private var state: PipelineState?
    private var actions: [MenuAction] = []

    /// The design's icon on its 24-point grid: a circle of radius 9.2 (rest) or a disc of radius 10 (active), and
    /// three bars.
    nonisolated static let bars = [CGRect(x: 7.9, y: 9.6, width: 2.2, height: 4.8),
                                   CGRect(x: 10.9, y: 7, width: 2.2, height: 10),
                                   CGRect(x: 13.9, y: 8.6, width: 2.2, height: 6.8)]
    /// Size in the menu bar.
    nonisolated static let side: CGFloat = 22

    init(showWindow: @escaping () -> Void) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        let showAction = MenuAction(showWindow)
        actions = [showAction]
        let showItem = NSMenuItem(title: String(localized: "Show \(AppIdentity.name)"),
                                  action: #selector(MenuAction.run), keyEquivalent: "")
        showItem.target = showAction
        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit \(AppIdentity.name)"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        if let button = item.button {
            activeIcon.frame = button.bounds
            activeIcon.autoresizingMask = [.width, .height]
            button.addSubview(activeIcon)
        }
        show(nil, force: true)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeIcon.animate() }
        }
    }

    /// The conversation's state; nil or `.listening`: at rest.
    func show(_ state: PipelineState?, force: Bool = false) {
        let state = state == .listening ? nil : state
        guard force || state != self.state else { return }
        let wasActive = self.state != nil
        self.state = state
        guard let button = item.button else { return }
        if let state {
            button.image = nil
            activeIcon.isHidden = false
            activeIcon.show(StatePalette(state).glow, animated: wasActive)
            button.setAccessibilityLabel(String(localized: "\(AppIdentity.name) (active)"))
        } else {
            button.image = Self.restImage
            activeIcon.isHidden = true
            activeIcon.stop()
            button.setAccessibilityLabel(String(localized: "\(AppIdentity.name) (idle)"))
        }
    }

    /// At rest: the outline and the bars, as a template image (macOS gives it the menu bar's colour).
    static let restImage: NSImage = {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let s = rect.width / 24
            NSColor.black.set()
            let circle = NSBezierPath(ovalIn: CGRect(x: 2.8 * s, y: 2.8 * s, width: 18.4 * s, height: 18.4 * s))
            circle.lineWidth = 1.8 * s
            circle.stroke()
            for bar in bars {
                let frame = CGRect(x: bar.minX * s, y: bar.minY * s, width: bar.width * s, height: bar.height * s)
                NSBezierPath(roundedRect: frame, xRadius: 1.1 * s, yRadius: 1.1 * s).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// The active icon: a disc of radius 10 (azure while the user speaks, sun while Maé thinks, coral while she speaks)
/// and three ink bars stretching from 45 % to 120 % of their height, each at its own pace. Core Animation plays
/// them, without the app redrawing anything; still with Reduce Motion.
final class ActiveMenuBarIcon: NSView {
    private let disc = CAShapeLayer()
    private let bars = MenuBarIcon.bars.map { _ in CALayer() }
    /// Size of the icon, in the middle of the view.
    private var side = MenuBarIcon.side
    /// Period and (negative) delay of each bar, as in the design.
    private static let paces: [(period: Double, delay: Double)] = [(0.8, 0), (0.6, -0.3), (0.95, -0.5)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(disc)
        for bar in bars {
            bar.backgroundColor = Palette.ink.cgColor
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A still picture of the icon at any size, its bars at the moment `time` of their movement (test pictures).
    static func picture(color: RGBA, side: CGFloat, time: Double) -> NSImage {
        let icon = ActiveMenuBarIcon(frame: CGRect(x: 0, y: 0, width: side, height: side))
        icon.side = side
        icon.placeLayers()
        icon.show(color, animated: false)
        icon.freeze(at: time)
        let scale: CGFloat = 2
        guard let layer = icon.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(side * scale), height: Int(side * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage() }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return NSImage() }
        return NSImage(cgImage: image, size: CGSize(width: side, height: side))
    }

    override func layout() {
        super.layout()
        placeLayers()
    }

    private func placeLayers() {
        let side = min(self.side, bounds.width, bounds.height)
        let s = side / 24
        let origin = CGPoint(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        disc.path = CGPath(ellipseIn: CGRect(x: 2 * s, y: 2 * s, width: 20 * s, height: 20 * s), transform: nil)
        for (bar, shape) in zip(bars, MenuBarIcon.bars) {
            // The bars are centred on the grid's middle line, so the layer's upward axis changes nothing.
            bar.bounds = CGRect(x: 0, y: 0, width: shape.width * s, height: shape.height * s)
            bar.position = CGPoint(x: origin.x + shape.midX * s, y: origin.y + (24 - shape.midY) * s)
            bar.cornerRadius = shape.width * s / 2
        }
        CATransaction.commit()
    }

    /// `animated`: the colour changes in 0.4 s (from one active state to another).
    func show(_ color: RGBA, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.4 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .default))  // CSS "ease"
        CATransaction.setDisableActions(!animated)
        disc.fillColor = color.cgColor
        CATransaction.commit()
        if bars.first?.animation(forKey: "breathe") == nil { animate() }
    }

    func stop() {
        bars.forEach { $0.removeAnimation(forKey: "breathe") }
    }

    /// Starts the bars, or leaves them still with Reduce Motion.
    func animate() {
        stop()
        guard !isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for (bar, pace) in zip(bars, Self.paces) {
            let breathe = CABasicAnimation(keyPath: "transform.scale.y")
            breathe.fromValue = 0.45
            breathe.toValue = 1.2
            breathe.duration = pace.period
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.timeOffset = -pace.delay  // a negative delay: the bar starts that far into its movement
            bar.add(breathe, forKey: "breathe")
        }
    }

    /// Still pictures: the bars at the moment `time` of their movement instead of moving.
    func freeze(at time: Double) {
        stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, pace) in zip(bars, Self.paces) {
            let x = Keyframes.alternate(time, period: pace.period, delay: pace.delay)
            let scale = 0.45 + (1.2 - 0.45) * Easing.smooth(x)
            bar.setAffineTransform(CGAffineTransform(scaleX: 1, y: scale))
        }
        CATransaction.commit()
    }
}

private final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() { action() }
}
