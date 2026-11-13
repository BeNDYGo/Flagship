import Cocoa
import ServiceManagement

/// Native AppKit switch: keyboard focus, VoiceOver and appearance are provided by macOS.
final class NativeToggle: NSSwitch {
    var onToggle: ((Bool) -> Void)?
    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { onToggle?(isOn) }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSWindowController, NSMenuDelegate {

    private var flagToggle: NativeToggle!
    private var arrowsToggle: NativeToggle!
    private var ipToggle: NativeToggle!
    private var loginToggle: NativeToggle!
    private var interfaceDropdown: NSPopUpButton!
    private let providerTester = IPFlagFetcher()
    private var providerMenu: NSMenu!
    private var testGeneration = 0

    convenience init() {
        let windowWidth: CGFloat = 380
        let contentHeight: CGFloat = 866
        let screenVisible = NSScreen.main?.visibleFrame.height ?? 900
        let windowHeight = min(contentHeight, screenVisible - 60)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(white: 0.11, alpha: 1.0)
        window.center()
        window.level = .normal
        window.appearance = NSAppearance(named: .darkAqua)

        self.init(window: window)

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = contentHeight > windowHeight
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: contentHeight))
        scrollView.documentView = content
        window.contentView!.addSubview(scrollView)
        setupUI(in: content)
        if contentHeight > windowHeight {
            content.scroll(NSPoint(x: 0, y: contentHeight - scrollView.contentSize.height))
        }
    }

    private func setupUI(in contentView: NSView) {
        let prefs = Preferences.shared
        let w = contentView.bounds.width
        let padding: CGFloat = 20

        var y: CGFloat = contentView.bounds.height - 24

        // ── App Icon ──
        let iconSize: CGFloat = 56
        let iconView = NSImageView(frame: NSRect(x: (w - iconSize) / 2, y: y - iconSize, width: iconSize, height: iconSize))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageFrameStyle = .none
        contentView.addSubview(iconView)
        y -= iconSize + 6

        // ── App Name ──
        let nameLabel = label("Flagship", size: 14, weight: .semibold, color: .white)
        nameLabel.frame = NSRect(x: 0, y: y - 18, width: w, height: 18)
        nameLabel.alignment = .center
        contentView.addSubview(nameLabel)
        y -= 22

        // ── Version ──
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
        let vLabel = label("v\(version)", size: 11, weight: .regular, color: NSColor(white: 0.5, alpha: 1.0))
        vLabel.frame = NSRect(x: 0, y: y - 14, width: w, height: 14)
        vLabel.alignment = .center
        contentView.addSubview(vLabel)
        y -= 22

        // ── Separator ──
        contentView.addSubview(makeSep(y: y))
        y -= 14

        // ── Appearance Section ──
        let sectionLabel = label("APPEARANCE", size: 10, weight: .medium, color: NSColor(white: 0.45, alpha: 1.0))
        sectionLabel.frame = NSRect(x: padding, y: y - 12, width: 200, height: 12)
        contentView.addSubview(sectionLabel)
        y -= 20

        // Toggles
        flagToggle = addToggle(to: contentView, y: &y, padding: padding, label: "Show Country Flag", isOn: prefs.showFlag) { prefs.showFlag = $0 }
        arrowsToggle = addToggle(to: contentView, y: &y, padding: padding, label: "Show Arrows", isOn: prefs.showArrows) { prefs.showArrows = $0 }
        ipToggle = addToggle(to: contentView, y: &y, padding: padding, label: "Show IP Instead of Flag", isOn: prefs.showIPInsteadOfFlag) { prefs.showIPInsteadOfFlag = $0 }
        _ = addToggle(to: contentView, y: &y, padding: padding, label: "Show IP in Menu", isOn: prefs.showIPInMenu) { prefs.showIPInMenu = $0 }
        _ = addToggle(to: contentView, y: &y, padding: padding, label: "Show CPU Usage", isOn: prefs.showCPU) { prefs.showCPU = $0 }
        _ = addToggle(to: contentView, y: &y, padding: padding, label: "Show Memory Usage", isOn: prefs.showMemory) { prefs.showMemory = $0 }
        _ = addToggle(to: contentView, y: &y, padding: padding, label: "Add Swap to Menu Bar Memory", isOn: prefs.addSwapToMenuBarMemory) { prefs.addSwapToMenuBarMemory = $0 }
        _ = addToggle(to: contentView, y: &y, padding: padding, label: "Show CPU Temperature", isOn: prefs.showTemperature) { prefs.showTemperature = $0 }
        _ = addToggle(to: contentView, y: &y, padding: padding, label: "Highlight Thermal Bursts", isOn: prefs.highlightThermalSpikes) { prefs.highlightThermalSpikes = $0 }
        _ = addToggle(to: contentView, y: &y, padding: padding, label: "Color System Metrics", isOn: prefs.colorMetrics) { prefs.colorMetrics = $0 }

        y -= 4
        contentView.addSubview(makeSep(y: y))
        y -= 14

        // ── Behavior Section ──
        let bLabel = label("BEHAVIOR", size: 10, weight: .medium, color: NSColor(white: 0.45, alpha: 1.0))
        bLabel.frame = NSRect(x: padding, y: y - 12, width: 200, height: 12)
        contentView.addSubview(bLabel)
        y -= 20

        // Login toggle
        loginToggle = addToggle(to: contentView, y: &y, padding: padding, label: "Launch at Login", isOn: SMAppService.mainApp.status == .enabled) { [weak self] isOn in
            self?.handleLoginToggle(isOn)
        }

        // ── Monitoring Section (Interface Lock) ──
        y -= 4
        contentView.addSubview(makeSep(y: y))
        y -= 14

        let monLabel = label("MONITORING", size: 10, weight: .medium, color: NSColor(white: 0.45, alpha: 1.0))
        monLabel.frame = NSRect(x: padding, y: y - 12, width: 200, height: 12)
        contentView.addSubview(monLabel)
        y -= 22

        let intLabel = label("Lock Interface", size: 13, weight: .regular, color: NSColor(white: 0.85, alpha: 1.0))
        intLabel.frame = NSRect(x: padding, y: y - 18, width: 200, height: 16)
        contentView.addSubview(intLabel)

        let interfaces = getMonitoredInterfaces()
        interfaceDropdown = NSPopUpButton(frame: NSRect(x: w - padding - 160, y: y - 22, width: 160, height: 24))
        interfaceDropdown.font = NSFont.systemFont(ofSize: 11)
        for (displayName, rawName) in interfaces {
            let item = NSMenuItem(title: displayName, action: nil, keyEquivalent: "")
            item.representedObject = rawName
            interfaceDropdown.menu?.addItem(item)
        }
        interfaceDropdown.target = self
        interfaceDropdown.action = #selector(interfaceChanged)
        let locked = prefs.lockedInterface
        if let locked = locked {
            if !(interfaceDropdown.menu?.items.contains { $0.representedObject as? String == locked } ?? false) {
                let item = NSMenuItem(title: "\(locked) (unavailable)", action: nil, keyEquivalent: "")
                item.representedObject = locked
                interfaceDropdown.menu?.addItem(item)
            }
            for (i, item) in (interfaceDropdown.menu?.items ?? []).enumerated() {
                if item.representedObject as? String == locked {
                    interfaceDropdown.selectItem(at: i)
                    break
                }
            }
        } else {
            interfaceDropdown.selectItem(at: 0)
        }
        contentView.addSubview(interfaceDropdown)
        y -= 36

        let tempLabel = label("CPU Temp Smoothing", size: 13, weight: .regular, color: NSColor(white: 0.85, alpha: 1.0))
        tempLabel.frame = NSRect(x: padding, y: y - 18, width: 200, height: 16)
        contentView.addSubview(tempLabel)

        let tempDropdown = NSPopUpButton(frame: NSRect(x: w - padding - 160, y: y - 22, width: 160, height: 24))
        tempDropdown.font = NSFont.systemFont(ofSize: 11)
        let windows: [(String, Int)] = [
            ("15s (Default)", 15),
            ("10s Average", 10),
            ("30s Average", 30),
            ("Instant (1s)", 1)
        ]
        for (name, val) in windows {
            let item = NSMenuItem(title: name, action: #selector(tempSmoothingChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = val
            tempDropdown.menu?.addItem(item)
        }
        let curWindow = prefs.temperatureAveragingWindow
        if let idx = windows.firstIndex(where: { $0.1 == curWindow }) {
            tempDropdown.selectItem(at: idx)
        } else {
            tempDropdown.selectItem(at: 0)
        }
        contentView.addSubview(tempDropdown)
        y -= 36

        let energyLabel = label("Energy Window", size: 13, weight: .regular, color: NSColor(white: 0.85, alpha: 1.0))
        energyLabel.frame = NSRect(x: padding, y: y - 18, width: 200, height: 16)
        contentView.addSubview(energyLabel)

        let energyDropdown = NSPopUpButton(frame: NSRect(x: w - padding - 160, y: y - 22, width: 160, height: 24))
        energyDropdown.font = NSFont.systemFont(ofSize: 11)
        let energyWindows: [(String, Int)] = [
            ("1 Hour (Default)", 3600),
            ("30 Minutes", 1800),
            ("2 Hours", 7200),
            ("3 Hours", 10800),
            ("5 Hours", 18000),
            ("10 Hours", 36000)
        ]
        for (name, val) in energyWindows {
            let item = NSMenuItem(title: name, action: #selector(energySmoothingChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = val
            energyDropdown.menu?.addItem(item)
        }
        let curEnergyWindow = prefs.energyAveragingWindow
        if let idx = energyWindows.firstIndex(where: { $0.1 == curEnergyWindow }) {
            energyDropdown.selectItem(at: idx)
        } else {
            energyDropdown.selectItem(at: 0)
        }
        contentView.addSubview(energyDropdown)
        y -= 36

        energyDropdown.isEnabled = !prefs.energySinceUnplug
        _ = addToggle(to: contentView, y: &y, padding: padding, label: "Energy: Count Since Unplug", isOn: prefs.energySinceUnplug) { isOn in
            prefs.energySinceUnplug = isOn
            energyDropdown.isEnabled = !isOn
        }

        // ── Country lookup providers ──
        y -= 4
        contentView.addSubview(makeSep(y: y))
        y -= 14
        let providersLabel = label("Country Services", size: 13, weight: .regular, color: NSColor(white: 0.85, alpha: 1.0))
        providersLabel.frame = NSRect(x: padding, y: y - 18, width: 140, height: 16)
        contentView.addSubview(providersLabel)
        let providerDropdown = NSPopUpButton(frame: NSRect(x: w - padding - 160, y: y - 22, width: 160, height: 24), pullsDown: true)
        providerDropdown.font = NSFont.systemFont(ofSize: 11)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Choose Services", action: nil, keyEquivalent: ""))
        for provider in IPFlagFetcher.providers {
            let item = NSMenuItem(title: provider.name, action: #selector(providerChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.name
            menu.addItem(item)
        }
        providerMenu = menu
        providerDropdown.menu = menu
        contentView.addSubview(providerDropdown)
        updateProviderChecks()
        y -= 36

        // ── Reset Button ──
        y -= 6
        let resetBtn = NSButton(frame: NSRect(x: w - padding - 120, y: y - 28, width: 120, height: 28))
        resetBtn.title = "Reset to Defaults"
        resetBtn.bezelStyle = .rounded
        resetBtn.font = NSFont.systemFont(ofSize: 11)
        resetBtn.target = self
        resetBtn.action = #selector(resetDefaults)
        contentView.addSubview(resetBtn)
        y -= 40

        // ── Footer (clickable link) ──
        let footerField = NSTextField(frame: NSRect(x: 0, y: 10, width: w, height: 16))
        footerField.isEditable = false
        footerField.isBordered = false
        footerField.drawsBackground = false
        footerField.alignment = .center
        let centeredStyle = NSMutableParagraphStyle()
        centeredStyle.alignment = .center
        let prefix = NSMutableAttributedString(string: "Developed by ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor(white: 0.4, alpha: 1.0),
                .paragraphStyle: centeredStyle
            ])
        let linkAttr = NSMutableAttributedString(string: "BeNDYGo",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(calibratedRed: 0.2, green: 0.6, blue: 1.0, alpha: 1.0),
                .link: URL(string: "https://github.com/BeNDYGo")! as NSURL,
                .cursor: NSCursor.pointingHand,
                .paragraphStyle: centeredStyle
            ])
        prefix.append(linkAttr)
        footerField.attributedStringValue = prefix
        footerField.allowsEditingTextAttributes = true
        footerField.isSelectable = true
        contentView.addSubview(footerField)
    }

    // MARK: - Helpers

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.isEditable = false
        l.isBordered = false
        l.drawsBackground = false
        return l
    }

    private func makeSep(y: CGFloat) -> NSView {
        let sepWidth = window?.contentView?.bounds.width ?? 0
        let sep = NSView(frame: NSRect(x: 0, y: y, width: sepWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        return sep
    }

    private func addToggle(to parent: NSView, y: inout CGFloat, padding: CGFloat, label text: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> NativeToggle {
        let l = label(text, size: 13, weight: .regular, color: NSColor(white: 0.88, alpha: 1.0))
        l.frame = NSRect(x: padding + 28, y: y - 18, width: parent.bounds.width - padding * 2 - 76, height: 16)
        parent.addSubview(l)

        let toggle = NativeToggle(frame: NSRect(x: parent.bounds.width - padding - 44, y: y - 20, width: 40, height: 22))
        toggle.isOn = isOn
        toggle.onToggle = onChange
        toggle.setAccessibilityLabel(text)
        parent.addSubview(toggle)
        y -= 30
        return toggle
    }

    // MARK: - Actions

    private func updateProviderChecks() {
        let selected = Preferences.shared.enabledIPProviders
        for item in providerMenu.items {
            guard let name = item.representedObject as? String else { continue }
            item.state = selected.contains(name) ? .on : .off
            item.isEnabled = !selected.contains(name) || selected.count > 1
        }
    }

    @objc private func providerChanged(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var selected = Preferences.shared.enabledIPProviders
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
        guard !selected.isEmpty else { return }
        Preferences.shared.enabledIPProviders = selected
        updateProviderChecks()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === providerMenu else { return }
        testGeneration += 1
        let generation = testGeneration
        updateProviderChecks()
        for item in menu.items {
            if let name = item.representedObject as? String { item.title = "\(name) — Checking…" }
        }
        providerTester.testProviders { [weak self] name, result in
            guard let self = self, self.testGeneration == generation,
                  let item = self.providerMenu.items.first(where: { $0.representedObject as? String == name }) else { return }
            item.title = "\(name) — \(result)"
        }
    }

    @objc private func interfaceChanged() {
        let selected = interfaceDropdown.selectedItem?.representedObject as? String
        Preferences.shared.lockedInterface = selected
    }

    @objc private func tempSmoothingChanged(_ sender: NSMenuItem) {
        guard let val = sender.representedObject as? Int else { return }
        Preferences.shared.temperatureAveragingWindow = val
    }

    @objc private func energySmoothingChanged(_ sender: NSMenuItem) {
        guard let val = sender.representedObject as? Int else { return }
        Preferences.shared.energyAveragingWindow = val
    }

    // MARK: - Interface list (delegates to NetworkInterfaceReader)
    private func getMonitoredInterfaces() -> [(String, String?)] {
        NetworkInterfaceReader.activeInterfaces()
    }

    private func handleLoginToggle(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginToggle.isOn = SMAppService.mainApp.status == .enabled
        }
    }

    @objc func resetDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset Settings"
        alert.informativeText = "Reset all settings to defaults?"
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            Preferences.shared.resetToDefaults()
            self.window?.close()
        }
    }
}
