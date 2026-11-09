import Cocoa

final class MetricsDashboardView: NSView {
    let history: MetricsHistory
    var isMenuOpen = false
    override var isFlipped: Bool { true }

    private var topProcesses: TopProcessesSnapshot?
    private var selectedCategory: ProcessCategory = .cpu
    private let tabContainerRect = NSRect(x: 188, y: 313, width: 162, height: 21)

    init(history: MetricsHistory) {
        self.history = history
        super.init(frame: NSRect(x: 0, y: 0, width: 364, height: 448))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Live CPU, memory, temperature, energy consumption history and top active processes")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateTopProcesses(_ snapshot: TopProcessesSnapshot) {
        self.topProcesses = snapshot
        if isMenuOpen { needsDisplay = true }
    }

    func refresh() {
        if isMenuOpen { needsDisplay = true }
    }

    private func formatMilliwatts(_ mw: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        let valStr = formatter.string(from: NSNumber(value: mw)) ?? String(format: "%.0f", mw)
        return "\(valStr) mW"
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
        let latest = system.last.flatMap { now - $0.time < 10 ? $0 : nil }
        label("LIVE ACTIVITY", rect: NSRect(x: 14, y: 10, width: 200, height: 16),
              size: 10, weight: .semibold, color: .labelColor)
        label("5 MIN", rect: NSRect(x: 290, y: 10, width: 60, height: 16), alignment: .right)

        let cpuRect = NSRect(x: 10, y: 34, width: 167, height: 126)
        let ramRect = NSRect(x: 187, y: 34, width: 167, height: 126)
        let tempRect = NSRect(x: 10, y: 170, width: 167, height: 126)
        let energyRect = NSRect(x: 187, y: 170, width: 167, height: 126)
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

        // Energy / Power Consumption Card (mW)
        let energyColor: NSColor
        let energyValueText: String
        let energyDetailText: String

        if let mw = latest?.powerMW {
            if mw >= 25_000 {
                energyColor = .systemRed
            } else if mw >= 12_000 {
                energyColor = .systemOrange
            } else {
                energyColor = .systemTeal
            }
            energyValueText = formatMilliwatts(mw)
            if mw >= 1000.0 {
                energyDetailText = String(format: "%.2f W total system draw", mw / 1000.0)
            } else {
                energyDetailText = "Low idle power"
            }
        } else {
            energyColor = .systemTeal
            energyValueText = "—"
            energyDetailText = "Waiting for sensor sample"
        }

        card(energyRect, title: "ENERGY", value: energyValueText,
             detail: energyDetailText, tint: energyColor)

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

        // Plot Energy consumption (mW)
        let energyPoints = system.map { ($0.time, $0.powerMW) }
        let maxObservedPower = energyPoints.compactMap { $0.1 }.max() ?? 10_000
        let energyMax = max(8_000.0, maxObservedPower * 1.15)
        plot(energyPoints, in: plotRect(energyRect), maxValue: energyMax, now: now,
             grid: true, maxGap: 15) { val in
            if val >= 25_000 { return .systemRed }
            if val >= 12_000 { return .systemOrange }
            return .systemTeal
        }

        // ==========================================
        // TOP PROCESSES SECTION
        // ==========================================

        // Divider
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 14, y: 306))
        divider.line(to: NSPoint(x: 350, y: 306))
        divider.lineWidth = 0.5
        divider.stroke()

        // Section Title
        label("TOP PROCESSES", rect: NSRect(x: 14, y: 316, width: 140, height: 16),
              size: 10, weight: .semibold, color: .labelColor)

        // Segmented Pill Control (CPU / RAM / Energy)
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: tabContainerRect, xRadius: 5.5, yRadius: 5.5).fill()

        let categories = ProcessCategory.allCases
        let segWidth = tabContainerRect.width / CGFloat(categories.count)
        for (idx, cat) in categories.enumerated() {
            let isSelected = (selectedCategory == cat)
            let tabX = tabContainerRect.minX + CGFloat(idx) * segWidth
            let tabRect = NSRect(x: tabX, y: tabContainerRect.minY, width: segWidth, height: tabContainerRect.height)

            if isSelected {
                NSColor.labelColor.withAlphaComponent(0.13).setFill()
                let pillRect = NSRect(x: tabRect.minX + 1.5, y: tabRect.minY + 1.5, width: tabRect.width - 3.0, height: tabRect.height - 3.0)
                NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4).fill()
            }

            label(cat.title,
                  rect: NSRect(x: tabRect.minX, y: tabRect.minY + 3.0, width: tabRect.width, height: 14),
                  size: 9.5,
                  weight: isSelected ? .medium : .regular,
                  color: isSelected ? .labelColor : .secondaryLabelColor,
                  alignment: .center)
        }

        // Process Rows
        let items: [ProcessDisplayItem]
        switch selectedCategory {
        case .cpu: items = topProcesses?.cpu ?? []
        case .memory: items = topProcesses?.memory ?? []
        case .energy: items = topProcesses?.energy ?? []
        }

        if items.isEmpty {
            label("Sampling active processes…", rect: NSRect(x: 14, y: 378, width: 336, height: 16),
                  size: 10, color: .tertiaryLabelColor, alignment: .center)
        } else {
            for (i, item) in items.prefix(5).enumerated() {
                let rowY = 340.0 + CGFloat(i) * 21.0

                // 1. Icon (16x16)
                let iconRect = NSRect(x: 14, y: rowY + 1.5, width: 16, height: 16)
                if let icon = item.icon {
                    icon.draw(in: iconRect)
                } else {
                    NSColor.labelColor.withAlphaComponent(0.15).setFill()
                    NSBezierPath(ovalIn: iconRect.insetBy(dx: 1, dy: 1)).fill()
                }

                // 2. Name (width expanded to 138 pt for better readability)
                let nameRect = NSRect(x: 36, y: rowY + 2, width: 138, height: 15)
                label(item.name, rect: nameRect, size: 10.5, weight: .regular, color: .labelColor)

                // 3. Wide Visual Gauge Bar
                let barRect = NSRect(x: 180, y: rowY + 7, width: 110, height: 5.5)
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 2.75, yRadius: 2.75).fill()

                let fillWidth = max(2.5, min(barRect.width, barRect.width * CGFloat(item.fraction)))
                let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
                let cornerRadius = min(fillWidth / 2.0, 2.75)

                let gaugeColor: NSColor
                switch selectedCategory {
                case .cpu:
                    if item.normalizedCpuPercent >= 50.0 {
                        gaugeColor = .systemRed
                    } else if item.normalizedCpuPercent >= 25.0 {
                        gaugeColor = .systemOrange
                    } else {
                        gaugeColor = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1.0)
                    }
                case .memory:
                    if item.fraction >= 0.40 {
                        gaugeColor = .systemOrange
                    } else if item.fraction >= 0.20 {
                        gaugeColor = .systemPurple
                    } else {
                        gaugeColor = .systemBlue
                    }
                case .energy:
                    if item.fraction >= 0.60 {
                        gaugeColor = NSColor(srgbRed: 1.0, green: 0.25, blue: 0.40, alpha: 1.0)
                    } else if item.fraction >= 0.30 {
                        gaugeColor = .systemOrange
                    } else {
                        gaugeColor = .systemTeal
                    }
                }

                gaugeColor.setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

                // 4. Formatted Value
                let valRect = NSRect(x: 296, y: rowY + 2, width: 54, height: 15)
                label(item.formattedValue, rect: valRect,
                      size: 10, weight: .medium, color: .secondaryLabelColor, alignment: .right)
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        // 1. Tab switching (swallow event so NSMenu does not dismiss)
        if tabContainerRect.contains(loc) {
            let segWidth = tabContainerRect.width / CGFloat(ProcessCategory.allCases.count)
            let index = Int((loc.x - tabContainerRect.minX) / segWidth)
            if let cat = ProcessCategory(rawValue: index), cat != selectedCategory {
                selectedCategory = cat
                needsDisplay = true
            }
            return
        }

        // Clicking on process rows does nothing; pass other clicks to super
        super.mouseDown(with: event)
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
