import Cocoa

final class MetricsDashboardView: NSView {
    let history: MetricsHistory
    var isMenuOpen = false
    override var isFlipped: Bool { true }

    init(history: MetricsHistory) {
        self.history = history
        super.init(frame: NSRect(x: 0, y: 0, width: 364, height: 306))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Live CPU, memory, temperature and network history for the last five minutes")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        if isMenuOpen { needsDisplay = true }
    }

    private func label(_ text: String, rect: NSRect, size: CGFloat = 10,
                       weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor,
                       alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    private func color(_ value: Double, warning: Double, high: Double) -> NSColor {
        MetricColors.level(value, warning: warning, high: high)
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date.timeIntervalSinceReferenceDate
        let system = history.system.filter { $0.time >= now - history.duration }
        let network = history.network.filter { $0.time >= now - history.duration }
        let latest = system.last.flatMap { now - $0.time < 10 ? $0 : nil }
        let net = network.last.flatMap { now - $0.time < 15 ? $0 : nil }
        label("LIVE ACTIVITY", rect: NSRect(x: 14, y: 10, width: 200, height: 16),
              size: 10, weight: .semibold, color: .labelColor)
        label("5 MIN", rect: NSRect(x: 290, y: 10, width: 60, height: 16), alignment: .right)

        let cpuRect = NSRect(x: 10, y: 34, width: 167, height: 126)
        let ramRect = NSRect(x: 187, y: 34, width: 167, height: 126)
        let tempRect = NSRect(x: 10, y: 170, width: 167, height: 126)
        let netRect = NSRect(x: 187, y: 170, width: 167, height: 126)
        let cpuColor = color(latest?.cpu ?? 0, warning: 50, high: 80)
        let ramColor = color(latest?.memoryPercent ?? 0, warning: 70, high: 90)
        let tempColor = color(latest?.temperature ?? 0, warning: 70, high: 90)

        card(cpuRect, title: "CPU", value: latest.map { String(format: "%.0f%%", $0.cpu) } ?? "—",
             detail: "Total processor load", tint: cpuColor)
        card(ramRect, title: "MEMORY", value: latest.map { String(format: "%.1f GB", $0.memoryGB) } ?? "—",
             detail: latest.map { String(format: "%.0f%% of %.0f GB", $0.memoryPercent, $0.totalMemoryGB) } ?? "Waiting for sample", tint: ramColor)
        let tempDetailText: String
        let tempWindow = Preferences.shared.temperatureAveragingWindow
        if let latest = latest, let avg = latest.temperature {
            if tempWindow <= 1 {
                tempDetailText = "Instant sensor mean"
            } else if latest.isThermalSpike, let inst = latest.instantTemperature {
                tempDetailText = String(format: "Now: %.0f°C (burst) • %ds", inst, tempWindow)
            } else if let inst = latest.instantTemperature, abs(inst - avg) >= 3.0 {
                tempDetailText = String(format: "Now: %.0f°C • %ds avg", inst, tempWindow)
            } else {
                tempDetailText = String(format: "Rolling %ds average", tempWindow)
            }
        } else {
            tempDetailText = "Mean across CPU sensors"
        }

        card(tempRect, title: "CPU TEMPERATURE", value: latest?.temperature.map { String(format: "%.0f °C", $0) } ?? "—",
             detail: tempDetailText, tint: tempColor)
        card(netRect, title: "NETWORK", value: "", detail: "", tint: .systemBlue)
        label(net.map { "↓ " + NetworkMonitor.formatSpeed($0.download) } ?? "↓ —",
              rect: NSRect(x: netRect.minX + 12, y: netRect.minY + 29, width: 143, height: 20),
              size: 13, weight: .medium, color: .systemBlue)
        label(net.map { "↑ " + NetworkMonitor.formatSpeed($0.upload) } ?? "↑ —",
              rect: NSRect(x: netRect.minX + 12, y: netRect.minY + 51, width: 143, height: 16),
              size: 10, color: .systemPurple)

        plot(system.map { ($0.time, Optional($0.cpu)) }, in: plotRect(cpuRect), maxValue: 100, now: now) {
            self.color($0, warning: 50, high: 80)
        }
        plot(system.map { ($0.time, Optional($0.memoryGB)) }, in: plotRect(ramRect),
             maxValue: system.last?.totalMemoryGB ?? 1, now: now) {
            let percent = $0 / max(system.last?.totalMemoryGB ?? 1, 1) * 100
            return self.color(percent, warning: 70, high: 90)
        }
        plot(system.map { ($0.time, $0.temperature) }, in: plotRect(tempRect), maxValue: 110, now: now) {
            self.color($0, warning: 70, high: 90)
        }
        let netMax = max(1000, network.map { max($0.upload, $0.download) }.max() ?? 0) * 1.1
        plot(network.map { ($0.time, Optional($0.download)) }, in: plotRect(netRect), maxValue: netMax, now: now,
             grid: true, maxGap: 15) { _ in .systemBlue }
        plot(network.map { ($0.time, Optional($0.upload)) }, in: plotRect(netRect), maxValue: netMax, now: now,
             grid: false, maxGap: 15) { _ in .systemPurple }
    }

    private func card(_ rect: NSRect, title: String, value: String, detail: String, tint: NSColor) {
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        label(title, rect: NSRect(x: rect.minX + 12, y: rect.minY + 11, width: rect.width - 24, height: 14),
              size: 9, weight: .semibold)
        label(value, rect: NSRect(x: rect.minX + 12, y: rect.minY + 28, width: rect.width - 24, height: 25),
              size: 20, weight: .medium, color: tint)
        label(detail, rect: NSRect(x: rect.minX + 12, y: rect.minY + 55, width: rect.width - 24, height: 14), size: 9)
    }

    private func plotRect(_ card: NSRect) -> NSRect {
        NSRect(x: card.minX + 12, y: card.minY + 80, width: card.width - 24, height: 34)
    }

    private func plot(_ points: [(TimeInterval, Double?)], in rect: NSRect, maxValue: Double,
                      now: TimeInterval, grid: Bool = true, maxGap: TimeInterval = 3,
                      tint: (Double) -> NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2)).addClip()
        if grid {
            NSColor.labelColor.withAlphaComponent(0.09).setStroke()
            for y in [rect.minY, rect.midY, rect.maxY] {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: rect.minX, y: y))
                line.line(to: NSPoint(x: rect.maxX, y: y))
                line.lineWidth = 0.5
                line.stroke()
            }
        }
        var previous: (TimeInterval, NSPoint)?
        for (time, value) in points {
            guard let value = value, value.isFinite, time <= now else { previous = nil; continue }
            let point = NSPoint(x: rect.minX + (time - now + history.duration) / history.duration * rect.width,
                                y: rect.maxY - min(1, max(0, value / max(1, maxValue))) * rect.height)
            let color = tint(value)
            if let last = previous, time - last.0 <= maxGap {
                let line = NSBezierPath()
                line.move(to: last.1)
                line.line(to: point)
                line.lineWidth = 1.5
                line.lineCapStyle = .round
                color.setStroke()
                line.stroke()
            } else {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)).fill()
            }
            previous = (time, point)
        }
    }
}
