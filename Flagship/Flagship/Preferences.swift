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

    var showTemperature: Bool {
        get { defaults.object(forKey: "showTemperature") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showTemperature"); notify() }
    }

    /// Rolling time window for CPU temperature smoothing in seconds (1 = Instantaneous, 10, 15 = default, 30).
    var temperatureAveragingWindow: Int {
        get { defaults.object(forKey: "temperatureAveragingWindow") as? Int ?? 15 }
        set { defaults.set(newValue, forKey: "temperatureAveragingWindow"); notify() }
    }

    /// Whether to display a burst indicator (↑°C) when instant CPU temperature spikes significantly above rolling average.
    var highlightThermalSpikes: Bool {
        get { defaults.object(forKey: "highlightThermalSpikes") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "highlightThermalSpikes"); notify() }
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
