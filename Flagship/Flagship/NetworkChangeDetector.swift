import Cocoa
import SystemConfiguration
import Network

/// Detects network changes (especially VPN connect/disconnect) using multiple
/// complementary methods to ensure reliability across all VPN apps:
///
/// 1. **Darwin notification** (`com.apple.system.config.network_change`) —
///    The most reliable OS-level notification for any network config change.
/// 2. **NWPathMonitor** — Detects path/interface changes (works for some VPNs).
/// 3. **Interface polling** — Periodically checks if the set of active network
///    interfaces has changed (catches VPNs that slip past the above two).
///
class NetworkChangeDetector {
    
    /// Called on the main thread whenever a network change is detected.
    var onNetworkChange: (() -> Void)?
    
    private var pathMonitor: NWPathMonitor?
    private var interfacePollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastInterfaceSet: Set<String> = []
    
    // Debounce: coalesce rapid network state events into a single notification
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.8
    
    // SCDynamicStore for network change detection
    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?
    
    func start() {
        setupDarwinNotification()
        setupPathMonitor()
        setupInterfacePolling()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.fireChangeEvent()
            }
        
        // Capture initial interface snapshot
        lastInterfaceSet = currentInterfaces()
    }
    
    func stop() {
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        wakeObserver = nil
        // Remove Darwin notification
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        dynamicStore = nil
        
        pathMonitor?.cancel()
        pathMonitor = nil
        
        interfacePollTimer?.invalidate()
        interfacePollTimer = nil
        
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }
    
    // MARK: - Method 1: SCDynamicStore (Darwin network change notifications)
    
    private func setupDarwinNotification() {
        // We use SCDynamicStore to watch for any network configuration changes.
        // This is the most reliable way to detect VPN connect/disconnect on macOS.
        
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        
        let callback: SCDynamicStoreCallBack = { (store, changedKeys, info) in
            guard let info = info else { return }
            let detector = Unmanaged<NetworkChangeDetector>.fromOpaque(info).takeUnretainedValue()
            detector.fireChangeEvent()
        }
        
        guard let store = SCDynamicStoreCreate(nil, "Flagship" as CFString, callback, &context) else {
            return
        }
        
        dynamicStore = store
        
        // Watch for changes to:
        // - Global IPv4/IPv6 state (VPN routing changes)
        // - Network service states (interface up/down)
        // - VPN configuration changes
        let watchedKeys: [CFString] = [
            "State:/Network/Global/IPv4" as CFString,
            "State:/Network/Global/IPv6" as CFString,
        ]
        
        let watchedPatterns: [CFString] = [
            "State:/Network/Service/.*/IPv4" as CFString,
            "State:/Network/Service/.*/IPv6" as CFString,
            "State:/Network/Interface/.*/Link" as CFString,
            "Setup:/Network/Service/.*/Interface" as CFString,
        ]
        
        SCDynamicStoreSetNotificationKeys(store, watchedKeys as CFArray, watchedPatterns as CFArray)
        
        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
    
    // MARK: - Method 2: NWPathMonitor
    
    private func setupPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.fireChangeEvent()
        }
        monitor.start(queue: DispatchQueue(label: "flagship.pathmonitor"))
        pathMonitor = monitor
    }
    
    // MARK: - Method 3: Interface polling
    
    private func setupInterfacePolling() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkInterfaceChanges() }
        RunLoop.main.add(timer, forMode: .common)
        interfacePollTimer = timer
    }
    
    private func checkInterfaceChanges() {
        let current = currentInterfaces()
        if current != lastInterfaceSet {
            lastInterfaceSet = current
            fireChangeEvent()
        }
    }
    
    /// Get the set of currently active (UP, non-loopback) network interface names
    private func currentInterfaces() -> Set<String> {
        var result = Set<String>()
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return result }
        
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            
            if isUp && !isLoopback {
                let name = String(cString: ptr.pointee.ifa_name)
                result.insert(name)
            if let addr = ptr.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) || addr.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result.insert(name + ":" + String(cString: host))
                }
            }
            }
        }
        
        return result
    }
    
    // MARK: - Debounced event firing
    
    private func fireChangeEvent() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Update interface snapshot
                self.lastInterfaceSet = self.currentInterfaces()
                self.onNetworkChange?()
            }
            self.debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
        }
    }
}
