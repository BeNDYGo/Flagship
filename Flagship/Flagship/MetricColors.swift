import Cocoa

enum MetricColors {
    /// Small menu-bar glyphs need quieter colors with more luminance contrast
    /// than the saturated accent colors used by the larger dashboard charts.
    static func menuBarLevel(_ value: Double?, warning: Double, high: Double,
                             appearance: NSAppearance) -> NSColor {
        guard let value = value, value.isFinite else { return .labelColor }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rgb: (CGFloat, CGFloat, CGFloat)
        if value >= high {
            rgb = dark ? (215, 157, 152) : (156, 55, 53)
        } else if value >= warning {
            rgb = dark ? (211, 179, 131) : (128, 80, 26)
        } else {
            rgb = dark ? (156, 195, 163) : (45, 101, 64)
        }
        return NSColor(calibratedRed: rgb.0 / 255, green: rgb.1 / 255,
                       blue: rgb.2 / 255, alpha: 1)
    }

    static func level(_ value: Double?, warning: Double, high: Double) -> NSColor {
        guard let value = value, value.isFinite else { return .labelColor }
        return value >= high ? .systemRed : value >= warning ? .systemOrange : .systemGreen
    }
}
