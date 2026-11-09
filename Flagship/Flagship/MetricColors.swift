import Cocoa

enum MetricAlertLevel {
    case normal
    case warning
    case critical
}

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

    /// Evaluates memory alert level using physical RAM % and active Swap usage.
    /// - Normal (Green): Physical RAM <= 85% AND Swap < 1024 MB
    /// - Warning (Orange): Physical RAM > 85% OR Swap in 1024...3072 MB
    /// - Critical (Red): Physical RAM >= 92% OR Swap >= 3072 MB (or total used >= 105%)
    static func memoryAlertLevel(ramPercent: Double?, swapMB: Double?,
                                 totalUsedPercent: Double? = nil) -> MetricAlertLevel {
        guard let ram = ramPercent, ram.isFinite else { return .normal }
        let swap = swapMB ?? 0.0
        let total = totalUsedPercent ?? ram

        if ram >= 92.0 || swap >= 3072.0 || total >= 105.0 {
            return .critical
        } else if ram >= 85.0 || swap >= 1024.0 {
            return .warning
        } else {
            return .normal
        }
    }

    static func memoryLevel(ramPercent: Double?, swapMB: Double?,
                            totalUsedPercent: Double? = nil) -> NSColor {
        switch memoryAlertLevel(ramPercent: ramPercent, swapMB: swapMB, totalUsedPercent: totalUsedPercent) {
        case .critical:
            return .systemRed
        case .warning:
            return .systemOrange
        case .normal:
            return .systemGreen
        }
    }

    static func menuBarMemoryLevel(ramPercent: Double?, swapMB: Double?,
                                  totalUsedPercent: Double? = nil,
                                  appearance: NSAppearance) -> NSColor {
        let alert = memoryAlertLevel(ramPercent: ramPercent, swapMB: swapMB, totalUsedPercent: totalUsedPercent)
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch alert {
        case .critical:
            rgb = dark ? (215, 157, 152) : (156, 55, 53)
        case .warning:
            rgb = dark ? (211, 179, 131) : (128, 80, 26)
        case .normal:
            rgb = dark ? (156, 195, 163) : (45, 101, 64)
        }
        return NSColor(calibratedRed: rgb.0 / 255, green: rgb.1 / 255,
                       blue: rgb.2 / 255, alpha: 1)
    }
}
