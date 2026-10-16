#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreText
import SwiftUI

/// The design's two families, shipped inside the app: Bricolage Grotesque for display text (wordmark, screen
/// titles, live transcript, percentage) and Figtree for the rest. Both are variable fonts under the SIL Open
/// Font License, whose text sits next to them in the app's resources.
enum Typeface: Sendable {
    case display, sans, mono

    fileprivate var fileName: String? {
        switch self {
        case .display: "BricolageGrotesque-latin-opsz"
        case .sans: "Figtree-latin-wght"
        case .mono: nil
        }
    }
}

enum Fonts {
    /// Makes the two families known to the whole app; called once at launch.
    static func register() {
        let urls = [Typeface.display, .sans].compactMap(url)
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    private static func url(_ face: Typeface) -> URL? {
        face.fileName.flatMap { Bundle.main.url(forResource: $0, withExtension: "woff2") }
    }

    /// A font at an exact weight (100…900). The display family also adapts its shapes to the size, as
    /// browsers do with optical sizing. `tabular`: figures of equal width, for numbers that line up.
    static func font(_ face: Typeface, size: CGFloat, weight: CGFloat, tabular: Bool = false) -> CTFont {
        guard let url = url(face),
              let base = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
        else { return fallback(face, size: size, weight: weight, tabular: tabular) }
        var variation: [NSNumber: NSNumber] = [axis("wght"): NSNumber(value: Double(weight))]
        if face == .display { variation[axis("opsz")] = NSNumber(value: Double(min(max(size, 12), 96))) }
        var attributes: [CFString: Any] = [kCTFontVariationAttribute: variation]
        if tabular { attributes[kCTFontFeatureSettingsAttribute] = [tabularFigures] }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static var tabularFigures: [CFString: Any] {
        [kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1]
    }

    /// Variation axis identifier: its four-letter tag as a number.
    private static func axis(_ tag: String) -> NSNumber {
        NSNumber(value: tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    /// The system's fonts: for the monospaced family, and if a font file were missing from the app.
    private static func fallback(_ face: Typeface, size: CGFloat, weight: CGFloat, tabular: Bool) -> CTFont {
        #if canImport(AppKit)
        typealias SystemFont = NSFont
        #else
        typealias SystemFont = UIFont
        #endif
        let systemWeight: SystemFont.Weight = switch weight {
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
        if face == .mono { return SystemFont.monospacedSystemFont(ofSize: size, weight: systemWeight) }
        let font = SystemFont.systemFont(ofSize: size, weight: systemWeight)
        guard tabular else { return font }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            font.fontDescriptor as CTFontDescriptor,
            [kCTFontFeatureSettingsAttribute: [tabularFigures]] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}

/// A text style of the design: family, size, weight, line height and letter spacing.
struct TextStyle: Sendable {
    let font: Font
    let size: CGFloat
    /// Letter spacing, in points.
    let tracking: CGFloat
    /// Height of one line, in points.
    let lineHeight: CGFloat
    /// Space added between lines so that they are `lineHeight` apart.
    let lineSpacing: CGFloat

    /// `letterSpacing` is in em, as in the design.
    init(_ face: Typeface, _ size: CGFloat, weight: CGFloat, lineHeight: CGFloat, letterSpacing: CGFloat = 0,
         tabular: Bool = false)
    {
        let font = Fonts.font(face, size: size, weight: weight, tabular: tabular)
        self.font = Font(font)
        self.size = size
        self.tracking = letterSpacing * size
        self.lineHeight = lineHeight
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        self.lineSpacing = max(0, lineHeight - natural)
    }
}

extension TextStyle {
    // Display family
    static let wordmark = TextStyle(.display, 18, weight: 500, lineHeight: 22, letterSpacing: -0.01)
    static let wordmarkStrong = TextStyle(.display, 18, weight: 700, lineHeight: 22, letterSpacing: -0.01)
    static let screenTitle = TextStyle(.display, 34, weight: 700, lineHeight: 34 * 1.1, letterSpacing: -0.02)
    static let transcript = TextStyle(.display, 21, weight: 500, lineHeight: 21 * 1.3, letterSpacing: -0.01)
    static let capsuleTranscript = TextStyle(.display, 16.5, weight: 500, lineHeight: 22, letterSpacing: -0.01)
    static let percentage = TextStyle(.display, 26, weight: 700, lineHeight: 26, letterSpacing: -0.02,
                                      tabular: true)
    static let percentSign = TextStyle(.display, 14, weight: 600, lineHeight: 14)

    // Interface family
    static let body = TextStyle(.sans, 15.5, weight: 400, lineHeight: 15.5 * 1.5)
    static let rowTitle = TextStyle(.sans, 15.5, weight: 600, lineHeight: 20)
    static let rowDetail = TextStyle(.sans, 12.5, weight: 400, lineHeight: 18)
    static let setting = TextStyle(.sans, 15, weight: 500, lineHeight: 20)
    static let value = TextStyle(.sans, 15, weight: 600, lineHeight: 20, tabular: true)
    static let strongValue = TextStyle(.sans, 15, weight: 700, lineHeight: 20, tabular: true)
    static let waitingValue = TextStyle(.sans, 15, weight: 500, lineHeight: 20, tabular: true)
    static let total = TextStyle(.sans, 18, weight: 700, lineHeight: 24, tabular: true)
    static let button = TextStyle(.sans, 17, weight: 600, lineHeight: 22, tabular: true)
    static let smallButton = TextStyle(.sans, 14.5, weight: 600, lineHeight: 20)
    static let label = TextStyle(.sans, 14.5, weight: 400, lineHeight: 20)
    static let chip = TextStyle(.sans, 13.5, weight: 600, lineHeight: 18)
    static let badge = TextStyle(.sans, 12.5, weight: 700, lineHeight: 16)
    static let previousLine = TextStyle(.sans, 14, weight: 400, lineHeight: 20)
    static let prompt = TextStyle(.sans, 16, weight: 400, lineHeight: 24)
    static let key = TextStyle(.sans, 14, weight: 600, lineHeight: 20)
    // The capsule: its status, the action on the right and its key (13 points there).
    static let capsuleStatus = TextStyle(.sans, 12.5, weight: 700, lineHeight: 16, letterSpacing: 0.01)
    static let capsuleAction = TextStyle(.sans, 13, weight: 500, lineHeight: 16)
    static let capsuleKey = TextStyle(.sans, 13, weight: 600, lineHeight: 16)
    static let control = TextStyle(.sans, 14, weight: 600, lineHeight: 20)  // pop-up value, chosen segment
    static let controlOff = TextStyle(.sans, 14, weight: 500, lineHeight: 20)  // other segments
    static let section = TextStyle(.sans, 12.5, weight: 700, lineHeight: 16, letterSpacing: 0.02)
    static let help = TextStyle(.sans, 12.5, weight: 400, lineHeight: 12.5 * 1.45)
    static let note = TextStyle(.sans, 12.5, weight: 400, lineHeight: 12.5 * 1.5)

    // Monospaced
    static let path = TextStyle(.mono, 11.5, weight: 400, lineHeight: 11.5 * 1.5)
}

extension View {
    func textStyle(_ style: TextStyle) -> some View {
        font(style.font).tracking(style.tracking).lineSpacing(style.lineSpacing)
    }
}

extension Text {
    /// The style's font and letter spacing on a piece of text (to join texts of several styles).
    func styled(_ style: TextStyle) -> Text {
        font(style.font).tracking(style.tracking)
    }
}
