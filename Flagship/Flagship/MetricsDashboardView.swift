import Cocoa

final class MetricsDashboardView: NSView {
    let history: MetricsHistory
    var isMenuOpen = false
    override var isFlipped: Bool { true }

    private var topProcesses: TopProcessesSnapshot?
    private var selectedCategory: ProcessCategory = .energy
    private static let fullHeight: CGFloat = 408
    /// Vertical space occupied by the tiles (cards + gap before the divider).
    private static let cardsBlockHeight: CGFloat = 232
    private let headerToggleRect = NSRect(x: 0, y: 0, width: 200, height: 30)

    private var isCollapsed: Bool { Preferences.shared.liveActivityCollapsed }
    /// Shift applied to the "top processes" section when tiles are hidden.
    private var sectionOffset: CGFloat { isCollapsed ? -Self.cardsBlockHeight : 0 }
    private var tabContainerRect: NSRect {
        NSRect(x: 188, y: 273 + sectionOffset, width: 162, height: 21)
    }

    init(history: MetricsHistory) {
        self.history = history
        super.init(frame: NSRect(x: 0, y: 0, width: 364, height: Self.fullHeight))
        applyCollapsedLayout()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Live CPU, memory, temperature, network history and top active processes")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyCollapsedLayout() {
        let height = Self.fullHeight + sectionOffset
        if frame.height != height { setFrameSize(NSSize(width: 364, height: height)) }
    }

    private func toggleCollapsed() {
        Preferences.shared.liveActivityCollapsed.toggle()
        applyCollapsedLayout()
        needsDisplay = true
    }

    private func drawDisclosureTriangle(at origin: NSPoint, expanded: Bool) {
        let path = NSBezierPath()
        if expanded {
            path.move(to: NSPoint(x: origin.x, y: origin.y))
            path.line(to: NSPoint(x: origin.x + 8, y: origin.y))
            path.line(to: NSPoint(x: origin.x + 4, y: origin.y + 5))
        } else {
            path.move(to: NSPoint(x: origin.x + 1, y: origin.y - 1))
            path.line(to: NSPoint(x: origin.x + 6, y: origin.y + 2.5))
            path.line(to: NSPoint(x: origin.x + 1, y: origin.y + 6))
        }
        path.close()
        NSColor.secondaryLabelColor.setFill()
        path.fill()
    }

    func updateTopProcesses(_ snapshot: TopProcessesSnapshot) {
        self.topProcesses = snapshot
        if isMenuOpen { needsDisplay = true }
    }

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
        drawDisclosureTriangle(at: NSPoint(x: 14, y: 14), expanded: !isCollapsed)
        label("LIVE ACTIVITY", rect: NSRect(x: 28, y: 10, width: 186, height: 16),
              size: 10, weight: .semibold, color: .labelColor)
        if !isCollapsed {
            label("5 MIN", rect: NSRect(x: 290, y: 10, width: 60, height: 16), alignment: .right)
        }

        if !isCollapsed {
            let cpuRect = NSRect(x: 10, y: 34, width: 167, height: 106)
            let ramRect = NSRect(x: 187, y: 34, width: 167, height: 106)
            let tempRect = NSRect(x: 10, y: 150, width: 167, height: 106)
            let netRect = NSRect(x: 187, y: 150, width: 167, height: 106)
            let cpuColor = color(latest?.cpu ?? 0, warning: 50, high: 80)
            let ramColor = MetricColors.memoryLevel(ramPercent: latest?.ramPercent,
                                                    swapMB: latest?.swapUsedMB,
                                                    totalUsedPercent: latest?.memoryPercent)
            let tempColor = color(latest?.temperature ?? 0, warning: 70, high: 90)

            card(cpuRect, title: "CPU", value: latest.map { String(format: "%.0f%%", $0.cpu) } ?? "—", tint: cpuColor)
            let ramGB = latest?.ramUsedGB ?? (latest?.memoryGB ?? 0)
            let swapMB = latest?.swapUsedMB ?? 0
            let totalUsedGB = latest?.memoryGB ?? ramGB

            let ramTitleSuffix: String
            if latest != nil {
                let ramText = ramGB >= 1 ? String(format: "%.1fGB", ramGB) : String(format: "%.0fMB", ramGB * 1024)
                let swapText = swapMB >= 1024 ? String(format: "%.1fGB", swapMB / 1024) : String(format: "%.0fMB", swapMB)
                ramTitleSuffix = " · \(ramText) RAM + \(swapText) SWAP"
            } else {
                ramTitleSuffix = ""
            }
            card(ramRect, title: "MEMORY", titleSuffix: ramTitleSuffix, value: latest.map { _ in String(format: "%.1f GB", totalUsedGB) } ?? "—",
                 tint: ramColor)
            card(tempRect, title: "CPU TEMPERATURE", value: latest?.temperature.map { String(format: "%.0f °C", $0) } ?? "—",
                 tint: tempColor)
            card(netRect, title: "NETWORK", value: "", tint: .systemBlue)
            let netColumnWidth = (netRect.width - 20) / 2
            label(net.map { "↓ " + NetworkMonitor.formatSpeed($0.download) } ?? "↓ —",
                  rect: NSRect(x: netRect.minX + 10, y: netRect.minY + 31, width: netColumnWidth, height: 18),
                  size: 11, weight: .medium, color: .systemBlue)
            label(net.map { "↑ " + NetworkMonitor.formatSpeed($0.upload) } ?? "↑ —",
                  rect: NSRect(x: netRect.minX + 10 + netColumnWidth, y: netRect.minY + 31, width: netColumnWidth, height: 18),
                  size: 11, weight: .medium, color: .systemPurple)

            plot(system.map { ($0.time, Optional($0.cpu)) }, in: plotRect(cpuRect), maxValue: 100, now: now, fill: true) {
                self.color($0, warning: 50, high: 80)
            }
            let currentSwapMB = system.last?.swapUsedMB
            plot(system.map { ($0.time, Optional($0.memoryGB)) }, in: plotRect(ramRect),
                 maxValue: system.last?.totalMemoryGB ?? 1, now: now, fill: true) {
                let percent = $0 / max(system.last?.totalMemoryGB ?? 1, 1) * 100
                return MetricColors.memoryLevel(ramPercent: percent, swapMB: currentSwapMB)
            }
            plot(system.map { ($0.time, $0.temperature) }, in: plotRect(tempRect), maxValue: 110, now: now, fill: true) {
                self.color($0, warning: 70, high: 90)
            }
            let netMax = max(1000, network.map { max($0.upload, $0.download) }.max() ?? 0) * 1.1
            plot(network.map { ($0.time, Optional($0.download)) }, in: plotRect(netRect), maxValue: netMax, now: now,
                 grid: true, maxGap: 15) { _ in .systemBlue }
            plot(network.map { ($0.time, Optional($0.upload)) }, in: plotRect(netRect), maxValue: netMax, now: now,
                 grid: false, maxGap: 15) { _ in .systemPurple }
        }

        // ==========================================
        // TOP PROCESSES SECTION
        // ==========================================

        // Divider
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 14, y: 266 + sectionOffset))
        divider.line(to: NSPoint(x: 350, y: 266 + sectionOffset))
        divider.lineWidth = 0.5
        divider.stroke()

        // Section Title
        let sectionTitle: String
        if selectedCategory == .energy {
            let win = Preferences.shared.energyAveragingWindow
            if Preferences.shared.energySinceUnplug, let mins = topProcesses?.energySinceUnplugMinutes {
                sectionTitle = mins >= 60 ? "SINCE UNPLUG · \(mins / 60)H \(mins % 60)M" : "SINCE UNPLUG · \(mins)M"
            } else if win >= 3600 {
                let hours = win / 3600
                sectionTitle = "TOP PROCESSES (\(hours)H ENERGY)"
            } else {
                let mins = win / 60
                sectionTitle = "TOP PROCESSES (\(mins)M ENERGY)"
            }
        } else {
            sectionTitle = "TOP PROCESSES"
        }
        label(sectionTitle, rect: NSRect(x: 14, y: 276 + sectionOffset, width: 164, height: 16),
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
            label("Sampling active processes…", rect: NSRect(x: 14, y: 338 + sectionOffset, width: 336, height: 16),
                  size: 10, color: .tertiaryLabelColor, alignment: .center)
        } else {
            for (i, item) in items.prefix(5).enumerated() {
                let rowY = 300.0 + sectionOffset + CGFloat(i) * 21.0

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
                    // Color by absolute drain rate (% of battery per hour)
                    if item.energyRatePerHour >= 8.0 {
                        gaugeColor = NSColor(srgbRed: 1.0, green: 0.25, blue: 0.40, alpha: 1.0)
                    } else if item.energyRatePerHour >= 3.0 {
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

        // 0. Collapse / expand the tiles
        if headerToggleRect.contains(loc) {
            toggleCollapsed()
            return
        }

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

    private func card(_ rect: NSRect, title: String, titleSuffix: String = "", value: String, tint: NSColor) {
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        if titleSuffix.isEmpty {
            label(title, rect: NSRect(x: rect.minX + 12, y: rect.minY + 11, width: rect.width - 24, height: 14),
                  size: 9, weight: .semibold)
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
            ])
            text.append(NSAttributedString(string: titleSuffix, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
            ]))
            text.draw(in: NSRect(x: rect.minX + 12, y: rect.minY + 11, width: rect.width - 16, height: 14))
        }
        label(value, rect: NSRect(x: rect.minX + 12, y: rect.minY + 27, width: rect.width - 24, height: 25),
              size: 20, weight: .medium, color: tint)
    }

    private func plotRect(_ card: NSRect) -> NSRect {
        NSRect(x: card.minX + 12, y: card.minY + 60, width: card.width - 24, height: 34)
    }

    private func plot(_ points: [(TimeInterval, Double?)], in rect: NSRect, maxValue: Double,
                      now: TimeInterval, grid: Bool = true, fill: Bool = false, maxGap: TimeInterval = 3,
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
                if fill {
                    NSGraphicsContext.saveGraphicsState()
                    let area = NSBezierPath()
                    area.move(to: last.1)
                    area.line(to: point)
                    area.line(to: NSPoint(x: point.x, y: rect.maxY))
                    area.line(to: NSPoint(x: last.1.x, y: rect.maxY))
                    area.close()
                    area.addClip()
                    NSGradient(starting: color.withAlphaComponent(0.30), ending: color.withAlphaComponent(0))?
                        .draw(from: NSPoint(x: 0, y: min(last.1.y, point.y)), to: NSPoint(x: 0, y: rect.maxY), options: [])
                    NSGraphicsContext.restoreGraphicsState()
                }
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
