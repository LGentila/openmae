import SwiftUI

/// The design's line icons: a 24-point grid, round ends and joins, the colour of the text next to them.
/// They are drawn from their SVG paths rather than taken from SF Symbols, so every screen uses one family.
enum Icon {
    case microphone, speaker, sparkles, settings, history, performance, download, downloadArrow, downloadBase
    case check, smallCheck, cancel, pause, stop, chevrons

    fileprivate var elements: [IconElement] {
        switch self {
        case .microphone:
            [.roundedRect(CGRect(x: 9, y: 3, width: 6, height: 11), radius: 3),
             .path("M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3")]
        case .speaker:
            [.path("M4.5 9.5v5h3.2L12 18V6L7.7 9.5H4.5z"), .path("M15.5 9.2a4 4 0 0 1 0 5.6M18 6.8a7.5 7.5 0 0 1 0 10.4")]
        case .sparkles:
            [.path("M11 3.8l1.7 4.6 4.6 1.7-4.6 1.7L11 16.4l-1.7-4.6-4.6-1.7 4.6-1.7L11 3.8zM18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2z")]
        case .settings:
            [.path("M4 8h8M16 8h4M4 16h3M11 16h9"), .circle(CGPoint(x: 14, y: 8), radius: 2),
             .circle(CGPoint(x: 9, y: 16), radius: 2)]
        case .history:
            [.circle(CGPoint(x: 12, y: 12), radius: 8.5), .path("M12 7.5V12l3 2")]
        case .performance:
            [.circle(CGPoint(x: 12, y: 12), radius: 8.5), .path("M12 12l3.4-3.4"),
             .path("M12 6.6v.01M6.6 12h.01M17.4 12h.01")]
        case .download: Icon.downloadArrow.elements + Icon.downloadBase.elements
        case .downloadArrow: [.path("M12 4v11M7.2 10.4l4.8 4.8 4.8-4.8")]
        case .downloadBase: [.path("M5.5 19.5h13")]
        case .check: [.path("M5.5 12.8l4.2 4.2 8.8-9.5")]
        case .smallCheck: [.path("M5 12.5l4.5 4.5L19 7.5")]
        case .cancel: [.path("M7 7l10 10M17 7L7 17")]
        case .pause: [.path("M9 6.5v11M15 6.5v11")]
        case .stop: [.roundedRect(CGRect(x: 6.5, y: 6.5, width: 11, height: 11), radius: 3)]
        case .chevrons: [.path("M3 6l3-3 3 3M3 10l3 3 3-3")]
        }
    }

    /// Stroke width on the 24-point grid.
    var strokeWidth: CGFloat {
        switch self {
        case .download, .downloadArrow, .downloadBase: 2.2
        case .check: 2.8
        case .smallCheck: 3.2
        case .cancel: 2.4
        case .pause: 2.8
        case .chevrons: 1.6
        default: 1.9
        }
    }

    /// The only filled icon.
    var isFilled: Bool { self == .stop }

    fileprivate var grid: CGSize { self == .chevrons ? CGSize(width: 12, height: 16) : CGSize(width: 24, height: 24) }
}

/// An icon at a size, in the current foreground style.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 20
    /// Overrides the icon's stroke width (on the 24-point grid).
    var strokeWidth: CGFloat?
    /// How much of the line is drawn (0…1), to draw a check little by little.
    var trim: CGFloat = 1

    var body: some View {
        let shape = IconShape(icon: icon)
        let scale = size / max(icon.grid.width, icon.grid.height)
        Group {
            if icon.isFilled {
                shape.fill()
            } else {
                shape.trim(from: 0, to: trim)
                    .stroke(style: StrokeStyle(lineWidth: (strokeWidth ?? icon.strokeWidth) * scale,
                                               lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: icon.grid.width * scale, height: icon.grid.height * scale)
        .accessibilityHidden(true)
    }
}

struct IconShape: Shape {
    let icon: Icon

    func path(in rect: CGRect) -> Path {
        let grid = icon.grid
        let scale = min(rect.width / grid.width, rect.height / grid.height)
        var path = Path()
        for element in icon.elements { element.add(to: &path) }
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }
}

fileprivate enum IconElement {
    case path(String)
    case circle(CGPoint, radius: CGFloat)
    case roundedRect(CGRect, radius: CGFloat)

    func add(to path: inout Path) {
        switch self {
        case .path(let data): SVGPath.add(data, to: &path)
        case .circle(let center, let radius):
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        case .roundedRect(let rect, let radius):
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        }
    }
}

/// Reads the few SVG path commands the icons use: M, L, H, V, A and Z, absolute or relative.
fileprivate enum SVGPath {
    static func add(_ data: String, to path: inout Path) {
        var tokens = tokenize(data)[...]
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"
        func number() -> CGFloat {
            guard case .number(let value)? = tokens.popFirst() else { return 0 }
            return value
        }
        while let token = tokens.first {
            let remaining = tokens.count
            if case .command(let c) = token {
                command = c
                tokens.removeFirst()
            }
            let relative = command.isLowercase
            let origin = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                current = CGPoint(x: origin.x + number(), y: origin.y + number())
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"  // further pairs are lines
            case "L":
                current = CGPoint(x: origin.x + number(), y: origin.y + number())
                path.addLine(to: current)
            case "H":
                current.x = (relative ? current.x : 0) + number()
                path.addLine(to: current)
            case "V":
                current.y = (relative ? current.y : 0) + number()
                path.addLine(to: current)
            case "A":
                let rx = number(), ry = number()
                _ = number()  // rotation: always 0 in the icons
                let largeArc = number() != 0, sweep = number() != 0
                let end = CGPoint(x: origin.x + number(), y: origin.y + number())
                addArc(from: current, to: end, rx: rx, ry: ry, largeArc: largeArc, sweep: sweep, to: &path)
                current = end
            case "Z":
                path.closeSubpath()
                current = start
            default:
                break
            }
            if tokens.count == remaining { tokens.removeFirst() }  // never stall on something unexpected
        }
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private static func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var number = ""
        func flush() {
            if let value = Double(number) { tokens.append(.number(CGFloat(value))) }
            number = ""
        }
        for c in data {
            if c.isLetter {
                flush()
                tokens.append(.command(c))
            } else if c == "-" {
                flush()
                number = "-"
            } else if c == "." {
                if number.contains(".") { flush() }  // "2.2.8" is 2.2 then .8
                number.append(c)
            } else if c.isNumber {
                number.append(c)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// An SVG elliptical arc (without rotation), as Bézier curves of a quarter turn at most.
    private static func addArc(from p1: CGPoint, to p2: CGPoint, rx: CGFloat, ry: CGFloat, largeArc: Bool,
                               sweep: Bool, to path: inout Path)
    {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p1 != p2 else { return path.addLine(to: p2) }
        let x1 = (p1.x - p2.x) / 2, y1 = (p1.y - p2.y) / 2
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (largeArc != sweep ? 1 : -1) * max(0, numerator / denominator).squareRoot()
        let cx1 = coefficient * rx * y1 / ry, cy1 = -coefficient * ry * x1 / rx
        let center = CGPoint(x: cx1 + (p1.x + p2.x) / 2, y: cy1 + (p1.y + p2.y) / 2)
        let startAngle = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
        var delta = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - startAngle
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(segments)
        let k = 4 / 3 * tan(step / 4)
        var angle = startAngle
        for _ in 0..<segments {
            let next = angle + step
            let a = CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
            let b = CGPoint(x: center.x + rx * cos(next), y: center.y + ry * sin(next))
            path.addCurve(to: b,
                          control1: CGPoint(x: a.x - k * rx * sin(angle), y: a.y + k * ry * cos(angle)),
                          control2: CGPoint(x: b.x + k * rx * sin(next), y: b.y - k * ry * cos(next)))
            angle = next
        }
    }
}
