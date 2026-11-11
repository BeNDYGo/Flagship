import Foundation

class Preferences {
    static let shared = Preferences()
    
    // Notification name for when settings change
    static let changedNotification = Notification.Name("FlagshipPreferencesChanged")
    
    private let defaults = UserDefaults.standard
    
    static let ipProvidersChangedNotification = Notification.Name("FlagshipIPProvidersChanged")

    var enabledIPProviders: Set<String> {
        get {
            guard let saved = defaults.stringArray(forKey: "enabledIPProviders") else {
                return Set(IPFlagFetcher.providers.map { $0.name })
            }
            return Set(saved)
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: "enabledIPProviders")
            NotificationCenter.default.post(name: Self.ipProvidersChangedNotification, object: nil)
        }
    }

    // Feature Toggles
    var colorMetrics: Bool {
        get { defaults.bool(forKey: "colorMetrics") }
        set { defaults.set(newValue, forKey: "colorMetrics"); notify() }
    }

    var showCPU: Bool {
        get { defaults.object(forKey: "showCPU") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showCPU"); notify() }
    }

    var showMemory: Bool {
        get { defaults.object(forKey: "showMemory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showMemory"); notify() }
    }

    /// Whether to add Swap to RAM usage in the status bar menu bar text.
    var addSwapToMenuBarMemory: Bool {
        get { defaults.object(forKey: "addSwapToMenuBarMemory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "addSwapToMenuBarMemory"); notify() }
    }

    var showTemperature: Bool {
        get { defaults.object(forKey: "showTemperature") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showTemperature"); notify() }
    }

    /// Rolling time window for CPU temperature smoothing in seconds (1 = Instantaneous, 10, 15 = default, 30).
    var temperatureAveragingWindow: Int {
        get { defaults.object(forKey: "temperatureAveragingWindow") as? Int ?? 15 }
        set { defaults.set(newValue, forKey: "temperatureAveragingWindow"); notify() }
    }

    /// Window for process energy tracking in seconds (1800 = 30m, 3600 = 1h default, 7200 = 2h, 10800 = 3h, 18000 = 5h, 36000 = 10h).
    var energyAveragingWindow: Int {
        get {
            let val = defaults.object(forKey: "energyAveragingWindow") as? Int ?? 3600
            if val < 1800 { return 3600 }
            return val
        }
        set { defaults.set(newValue, forKey: "energyAveragingWindow"); notify() }
    }

    /// When true, the energy list is counted from the moment the Mac was last unplugged (window setting is ignored).
    var energySinceUnplug: Bool {
        get { defaults.object(forKey: "energySinceUnplug") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "energySinceUnplug"); notify() }
    }

    /// Whether to display a burst indicator (↑°C) when instant CPU temperature spikes significantly above rolling average.
    var highlightThermalSpikes: Bool {
        get { defaults.object(forKey: "highlightThermalSpikes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "highlightThermalSpikes"); notify() }
    }

    /// Whether the CPU / Memory / Temperature / Network tiles in the dropdown are collapsed.
    var liveActivityCollapsed: Bool {
        get { defaults.bool(forKey: "liveActivityCollapsed") }
        set { defaults.set(newValue, forKey: "liveActivityCollapsed") }
    }

    var showFlag: Bool {
        get { defaults.object(forKey: "showFlag") as? Bool ?? true }
        set { 
            defaults.set(newValue, forKey: "showFlag") 
            notify()
        }
    }
    
    var showArrows: Bool {
        get { defaults.object(forKey: "showArrows") as? Bool ?? true }
        set { 
            defaults.set(newValue, forKey: "showArrows")
            notify()
        }
    }
    
    var showIPInsteadOfFlag: Bool {
        get { defaults.bool(forKey: "showIPInsteadOfFlag") } // Defaults to false
        set { 
            defaults.set(newValue, forKey: "showIPInsteadOfFlag")
            notify()
        }
    }
    
    // Speed Display Mode: 0 = Both, 1 = Upload Only, 2 = Download Only
    var displayMode: Int {
        get { defaults.object(forKey: "displayMode") as? Int ?? 0 }
        set {
            defaults.set(newValue, forKey: "displayMode")
            notify()
        }
    }
    
    // Lock monitoring to a specific network interface (nil = all interfaces)
    var lockedInterface: String? {
        get { defaults.string(forKey: "lockedInterface") }
        set {
            defaults.set(newValue, forKey: "lockedInterface")
            notify()
        }
    }
    
    // We handle Launch At Login via SMAppService directly in AppDelegate/Settings,
    // but we can store the theoretical state here if needed.
    
    private init() {}
    
    func resetToDefaults() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        notify()
        NotificationCenter.default.post(name: Self.ipProvidersChangedNotification, object: nil)
    }
    
    private func notify() {
        NotificationCenter.default.post(name: Preferences.changedNotification, object: nil)
    }
}
