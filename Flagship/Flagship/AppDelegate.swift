import Cocoa
import Foundation
import Network

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    var menuBarView: MenuBarView!
    var networkMonitor: NetworkMonitor!
    var ipFetcher: IPFlagFetcher!
    private var currentIP: String = ""
    var settingsController: SettingsWindowController?
    var networkChangeDetector: NetworkChangeDetector!
    private let systemMonitor = SystemMonitor()
    private let processMonitor = ProcessMonitor()
    private let history = MetricsHistory()
    private lazy var dashboard = MetricsDashboardView(history: history)
    private var monitorStarted = false
    private var monitorInterface: String?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create the status item with variable length initially
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        menuBarView = MenuBarView()
        
        if let button = statusItem.button {
            button.title = ""
            menuBarView.frame = button.bounds
            menuBarView.autoresizingMask = [.width, .height]
            button.addSubview(menuBarView)
        }
        
        // Setup Menu
        let menu = NSMenu()
        menu.delegate = self
        let dashboardItem = NSMenuItem()
        dashboardItem.view = dashboard
        menu.addItem(dashboardItem)
        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh IP", action: #selector(refreshIP), keyEquivalent: "r")
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit Flagship", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        
        // Initialize Core Components
        ipFetcher = IPFlagFetcher()
        networkMonitor = NetworkMonitor()
        
        // Wire up callbacks
        networkMonitor.onSpeedUpdate = { [weak self] upload, download in
            guard let self = self else { return }
            self.menuBarView.updateSpeeds(upload: upload, download: download)
            self.updateMenuBarWidth()
        }
        
        networkMonitor.onRatesUpdate = { [weak self] upload, download in
            self?.history.append(upload: upload, download: download)
            self?.dashboard.refresh()
        }

        ipFetcher.onUpdate = { [weak self] flag, ipString in
            guard let self = self else { return }
            self.currentIP = ipString
            self.menuBarView.updateFlag(flag, ip: ipString)
            self.updateMenuBarWidth()
        }
        
        // Listen for preference changes
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: Preferences.changedNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(refreshIP), name: Preferences.ipProvidersChangedNotification, object: nil)

        // Setup network change detector (uses SCDynamicStore + NWPathMonitor + interface polling)
        // to reliably detect VPN connections/disconnections from any VPN app
        networkChangeDetector = NetworkChangeDetector()
        networkChangeDetector.onNetworkChange = { [weak self] in
            // Fetch immediately on network change for instant flag update
            self?.ipFetcher.fetchWithRetry()
        }
        networkChangeDetector.start()
        
        // Start monitoring immediately
        startNetworkMonitor()

        systemMonitor.onUpdate = { [weak self] cpu, memory in
            guard let self = self else { return }
            self.menuBarView.updateSystem(cpu: cpu, memory: memory)
            self.history.append(cpu: cpu, memory: memory)
            self.dashboard.refresh()
            let temperature: String
            if cpu.temperature > 0 {
                let window = Preferences.shared.temperatureAveragingWindow
                let avgStr = window > 1 ? "\(window)s avg" : "instant"
                if cpu.isThermalSpike {
                    temperature = String(format: "CPU temperature: %.0f °C (%@, burst: %.0f °C)", cpu.temperature, avgStr, cpu.instantTemperature)
                } else {
                    temperature = String(format: "CPU temperature: %.0f °C (%@)", cpu.temperature, avgStr)
                }
            } else {
                temperature = "CPU temperature: unavailable"
            }
            let swapSummary: String
            if memory.swapUsedBytes >= 1_073_741_824 {
                swapSummary = String(format: " (%.1f GB RAM | %.1f GB Swap)", memory.ramUsedGB, memory.swapUsedGB)
            } else {
                swapSummary = String(format: " (%.1f GB RAM | %.0f MB Swap)", memory.ramUsedGB, memory.swapUsedMB)
            }
            let accessibilitySummary = [
                self.currentIP.isEmpty ? "" : "IP: \(self.currentIP)",
                String(format: "CPU: %.0f%%", cpu.usagePercent),
                String(format: "Memory: %.1f / %.1f GB%@", memory.usedGB, memory.totalGB, swapSummary),
                temperature
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            self.menuBarView.setAccessibilityLabel(accessibilitySummary)
            self.updateMenuBarWidth()
        }
        systemMonitor.start()
        
        processMonitor.onUpdate = { [weak self] snapshot in
            self?.dashboard.updateTopProcesses(snapshot)
        }
        
        // Trigger an initial fetch
        ipFetcher.fetch()
        
        // Setup repeating fetch for IP (every 60 seconds as safety net)
        let ipTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.ipFetcher.fetch() }
        RunLoop.main.add(ipTimer, forMode: .common)
    }
    
    @objc func preferencesChanged() {
        startNetworkMonitor() // Restart timer if interval changed
        menuBarView.applyPreferences()
        updateMenuBarWidth()

        // If the Settings window is not currently on screen, drop the cached
        // controller so the next openSettings() rebuilds it from the (possibly
        // reset) preferences. Avoids showing stale toggle/dropdown state after
        // "Reset to Defaults" closed the window.
        if settingsController?.window?.isVisible != true {
            settingsController = nil
        }
    }
    
    private func updateMenuBarWidth() {
        let optimalLength = menuBarView.calculateOptimalWidth()
        statusItem.length = optimalLength
    }
    
    private func startNetworkMonitor() {
        let prefs = Preferences.shared
        guard !monitorStarted || monitorInterface != prefs.lockedInterface else { return }
        monitorStarted = true
        monitorInterface = prefs.lockedInterface
        networkMonitor.start()
    }
    
    @objc func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        dashboard.isMenuOpen = true
        dashboard.needsDisplay = true
        processMonitor.start()
    }

    func menuDidClose(_ menu: NSMenu) {
        dashboard.isMenuOpen = false
        processMonitor.stop()
    }

    @objc func refreshIP() {
        ipFetcher.fetch(force: true)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

