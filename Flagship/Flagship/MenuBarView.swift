import Cocoa

class MenuBarView: NSView {

    // Core data
    private var rawUpload: String = "0 B/s"
    private var rawDownload: String = "0 B/s"
    private var currentFlag: String = "🏳️"
    private var currentIP: String = "..."
    private var cpuText = "—%"
    private var memoryText = "— G"
    private var temperatureText = "—"
    private var cpuUsage: Double?
    private var memoryUsagePercent: Double?
    private var memoryRamPercent: Double?
    private var memorySwapMB: Double?
    private var cpuTemperature: Double?
    private var instantTemperature: Double?
    private var isThermalSpike: Bool = false
    private var lastMemory: MemoryStats?

    // Reserve room for full CPU load and installed memory from launch.
    private var metricsWidth: CGFloat {
        let prefs = Preferences.shared
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let cpuWidth = prefs.showCPU ? max(textWidth("100%"), textWidth(cpuText)) : 0
        let memoryWidth = prefs.showMemory
            ? max(textWidth(String(format: "%.1f G", totalGB)), textWidth(memoryText)) : 0
        return max(cpuWidth, memoryWidth)
    }
    private var temperatureWidth: CGFloat {
        max(textWidth("100"), textWidth(temperatureText), textWidth("°C"), textWidth("↑°C"))
    }
    private func textWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: speedFont]).size().width)
    }

    private let speedFont: NSFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    private let flagFont: NSFont = NSFont.systemFont(ofSize: 14, weight: .regular) // slightly larger for emoji

    private var cachedWidth: CGFloat = 0

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    
    func updateSpeeds(upload: String, download: String) {
        self.rawUpload = upload
        self.rawDownload = download
        self.needsDisplay = true
    }
    
    func updateFlag(_ flag: String, ip: String) {
        self.currentFlag = flag
        self.currentIP = ip
        self.needsDisplay = true
    }
    
    func calculateOptimalWidth() -> CGFloat {
        let prefs = Preferences.shared

        let upStr = prefs.showArrows ? "\(rawUpload) ↑" : rawUpload
        let downStr = prefs.showArrows ? "\(rawDownload) ↓" : rawDownload
        let upSize = NSAttributedString(string: upStr, attributes: [.font: speedFont]).size()
        let downSize = NSAttributedString(string: downStr, attributes: [.font: speedFont]).size()

        var totalWidth: CGFloat = 8.0
        if prefs.showCPU || prefs.showMemory { totalWidth += metricsWidth + 5.0 }
        if prefs.showTemperature { totalWidth += temperatureWidth + 5.0 }

        let showUp = (prefs.displayMode == 0 || prefs.displayMode == 1)
        let showDown = (prefs.displayMode == 0 || prefs.displayMode == 2)

        // Text width container
        if showUp && showDown {
            totalWidth += max(upSize.width, downSize.width)
        } else if showUp {
            totalWidth += upSize.width
        } else if showDown {
            totalWidth += downSize.width
        }

        // Right side adornment (Flag or IP)
        if prefs.showFlag {
            totalWidth += 4.0 // gap
            if prefs.showIPInsteadOfFlag {
                let ipSize = NSAttributedString(string: currentIP, attributes: [.font: speedFont]).size()
                totalWidth += ipSize.width
            } else {
                let flagSize = NSAttributedString(string: currentFlag, attributes: [.font: flagFont]).size()
                totalWidth += flagSize.width
            }
        }

        cachedWidth = max(cachedWidth, ceil(totalWidth))
        return cachedWidth
    }

    func updateSystem(cpu: CPUStats, memory: MemoryStats) {
        lastMemory = memory
        cpuUsage = cpu.usagePercent
        memoryUsagePercent = memory.totalBytes > 0 ? memory.usedPercent : nil
        memoryRamPercent = memory.totalBytes > 0 ? memory.ramPercent : nil
        memorySwapMB = memory.swapUsedBytes > 0 ? memory.swapUsedMB : nil
        cpuTemperature = cpu.temperature > 0 ? cpu.temperature : nil
        instantTemperature = cpu.instantTemperature > 0 ? cpu.instantTemperature : nil
        isThermalSpike = cpu.isThermalSpike
        cpuText = String(format: "%.0f%%", min(100, max(0, cpu.usagePercent)))
        formatMemoryText()
        temperatureText = cpu.temperature > 0 ? String(format: "%.0f", cpu.temperature) : "—"
        needsDisplay = true
    }

    private func formatMemoryText() {
        guard let memory = lastMemory else { return }
        let memGB = Preferences.shared.addSwapToMenuBarMemory ? memory.usedGB : memory.ramUsedGB
        memoryText = String(format: "%.1f G", memGB)
    }

    func applyPreferences() {
        formatMemoryText()
        resetCachedWidth()
        needsDisplay = true
    }

    /// Allow the status item to shrink immediately when a metric is hidden.
    func resetCachedWidth() {
        cachedWidth = 0
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        formatMemoryText()
        let prefs = Preferences.shared
        
        let textColor = NSColor.labelColor
        let speedAttributes: [NSAttributedString.Key: Any] = [.font: speedFont, .foregroundColor: textColor]
        
        let upStr = prefs.showArrows ? "\(rawUpload) ↑" : rawUpload
        let downStr = prefs.showArrows ? "\(rawDownload) ↓" : rawDownload
        
        let upString = NSAttributedString(string: upStr, attributes: speedAttributes)
        let downString = NSAttributedString(string: downStr, attributes: speedAttributes)
        
        let upSize = upString.size()
        let downSize = downString.size()
        
        let viewWidth = self.bounds.width
        let viewHeight = self.bounds.height
        
        var currentRightEdge = viewWidth - 3.0 // Right padding

        // Same font and baselines as the two speed lines.
        let cpuColor = prefs.colorMetrics ? MetricColors.menuBarLevel(cpuUsage, warning: 50, high: 80, appearance: effectiveAppearance) : textColor
        let memoryColor = prefs.colorMetrics ? MetricColors.menuBarMemoryLevel(
            ramPercent: memoryRamPercent,
            swapMB: memorySwapMB,
            totalUsedPercent: memoryUsagePercent,
            appearance: effectiveAppearance
        ) : textColor
        let temperatureColor = prefs.colorMetrics ? MetricColors.menuBarLevel(cpuTemperature, warning: 70, high: 90, appearance: effectiveAppearance) : textColor
        func drawMetric(_ text: String, rightEdge: CGFloat, y: CGFloat, color: NSColor) {
            let string = NSAttributedString(string: text, attributes: [.font: speedFont, .foregroundColor: color])
            string.draw(at: NSPoint(x: rightEdge - string.size().width, y: y))
        }
        if prefs.showTemperature {
            let showBurst = isThermalSpike && prefs.highlightThermalSpikes
            let unitText = showBurst ? "↑°C" : "°C"
            let unitColor = (showBurst && prefs.colorMetrics)
                ? MetricColors.menuBarLevel(instantTemperature, warning: 70, high: 90, appearance: effectiveAppearance)
                : temperatureColor
            drawMetric(temperatureText, rightEdge: currentRightEdge, y: 11.5, color: temperatureColor)
            drawMetric(unitText, rightEdge: currentRightEdge, y: 1.0, color: unitColor)
            currentRightEdge -= temperatureWidth + 5.0
        }
        if prefs.showCPU || prefs.showMemory {
            if prefs.showCPU && prefs.showMemory {
                drawMetric(cpuText, rightEdge: currentRightEdge, y: 11.5, color: cpuColor)
                drawMetric(memoryText, rightEdge: currentRightEdge, y: 1.0, color: memoryColor)
            } else {
                let text = prefs.showCPU ? cpuText : memoryText
                let height = NSAttributedString(string: text, attributes: speedAttributes).size().height
                drawMetric(text, rightEdge: currentRightEdge, y: (viewHeight - height) / 2.0,
                           color: prefs.showCPU ? cpuColor : memoryColor)
            }
            currentRightEdge -= metricsWidth + 5.0
        }
        
        // 1. Draw Flag or IP on the right (if enabled)
        if prefs.showFlag {
            if prefs.showIPInsteadOfFlag {
                let ipString = NSAttributedString(string: currentIP, attributes: speedAttributes)
                let ipSize = ipString.size()
                let ipY = (viewHeight - ipSize.height) / 2.0
                currentRightEdge -= ipSize.width
                ipString.draw(at: NSPoint(x: currentRightEdge, y: ipY))
            } else {
                let flagAttributes: [NSAttributedString.Key: Any] = [.font: flagFont]
                let flagString = NSAttributedString(string: currentFlag, attributes: flagAttributes)
                let flagSize = flagString.size()
                let flagY = (viewHeight - flagSize.height) / 2.0 + 1.0 // Offset for visual emoji baseline
                currentRightEdge -= flagSize.width
                flagString.draw(at: NSPoint(x: currentRightEdge, y: flagY))
            }
            currentRightEdge -= 4.0 // Gap between right-element and text
        }
        
        // 2. Draw Text Logic
        let showUp = (prefs.displayMode == 0 || prefs.displayMode == 1)
        let showDown = (prefs.displayMode == 0 || prefs.displayMode == 2)
        
        if showUp && showDown {
            upString.draw(at: NSPoint(x: currentRightEdge - upSize.width, y: 11.5))
            downString.draw(at: NSPoint(x: currentRightEdge - downSize.width, y: 1.0))
        } else if showUp {
            // Only Drawing Upload — vertically center it
            let textY = (viewHeight - upSize.height) / 2.0
            let startX = currentRightEdge - upSize.width
            upString.draw(at: NSPoint(x: startX, y: textY))
        } else if showDown {
            // Only Drawing Download — vertically center it
            let textY = (viewHeight - downSize.height) / 2.0
            let startX = currentRightEdge - downSize.width
            downString.draw(at: NSPoint(x: startX, y: textY))
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        // Pass click to the status item's button so the menu appears
        super.mouseDown(with: event)
        if let menu = self.enclosingMenuItem?.menu {
            menu.popUp(positioning: nil, at: NSPoint.zero, in: self)
        } else {
            // Forward event if wrapped in NSStatusBarButton
            self.nextResponder?.mouseDown(with: event)
        }
    }
}
