import Cocoa
import Darwin

public enum ProcessCategory: Int, CaseIterable {
    case cpu = 0
    case memory = 1
    case energy = 2

    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .energy: return "Energy"
        }
    }
}

public struct ProcessDisplayItem {
    public let pid: pid_t
    public let name: String
    public let icon: NSImage?
    public let helperCount: Int

    /// Fraction for the gauge bar (0.0 ... 1.0)
    public let fraction: Double

    /// Formatted primary value string (e.g. "12.5%", "2.1 GB", "3.4 W")
    public let formattedValue: String

    public let normalizedCpuPercent: Double
    public let memoryBytes: UInt64
    public let energyScore: Double
    public let isWatts: Bool

    /// Energy tab only: battery drain attributed to this item, in % per hour (drives gauge color)
    public var energyRatePerHour: Double = 0.0
}

public struct TopProcessesSnapshot {
    public let cpu: [ProcessDisplayItem]
    public let memory: [ProcessDisplayItem]
    public let energy: [ProcessDisplayItem]

    /// Minutes since the Mac was unplugged; non-nil only when "since unplug" mode drives the energy window.
    public var energySinceUnplugMinutes: Int? = nil

    public static let empty = TopProcessesSnapshot(cpu: [], memory: [], energy: [])
}

final class ProcessMonitor {
    var onUpdate: ((TopProcessesSnapshot) -> Void)?

    private let queue = DispatchQueue(label: "flagship.process-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var warmUpTimer: DispatchSourceTimer?
    private let ownPid = getpid()
    private let logicalCores: Double = max(1.0, Double(ProcessInfo.processInfo.activeProcessorCount))
    private let totalRamBytes: Double = max(1.0, Double(ProcessInfo.processInfo.physicalMemory))

    private var timebase = mach_timebase_info_data_t()
    private var prevCpuSamples = [pid_t: (totalTicks: UInt64, time: TimeInterval)]()
    private var prevEnergyByPid = [pid_t: UInt64]()

    private struct MinuteBucket: Codable {
        var minuteIndex: Int64
        var joulesByApp: [String: Double]
        var batteryDrainPercent: Double = 0.0
    }
    private var energyBuckets: [MinuteBucket] = []

    private struct TrackedAppMeta {
        let name: String
        let appPath: String?
        let primaryPid: pid_t
    }
    private var trackedAppsMeta = [String: TrackedAppMeta]()

    private var isMenuOpen = false
    private var backgroundTimer: DispatchSourceTimer?

    private struct ResolvedMeta {
        let mainKey: String
        let displayName: String
        let appPath: String?
    }
    private var metaCache = [String: ResolvedMeta]()
    private var iconCache = [String: NSImage]()

    init() {
        mach_timebase_info(&timebase)
        loadPersistedState()
    }

    // MARK: - Persistence (energy buckets + unplug session)

    private struct PersistedState: Codable {
        var buckets: [MinuteBucket]
        var sessionStartMinute: Int64?
        var lastExternal: Bool?
        var batteryRefLevel: Double?
    }

    private var sessionStartMinute: Int64?
    private var lastExternal: Bool?
    private var lastSavedMinute: Int64 = 0

    private lazy var stateURL: URL? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Flagship", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("energy-state.json")
    }()

    private func loadPersistedState() {
        guard let url = stateURL,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        energyBuckets = state.buckets
        sessionStartMinute = state.sessionStartMinute
        lastExternal = state.lastExternal
        batteryRefLevel = state.batteryRefLevel
    }

    private func savePersistedState() {
        guard let url = stateURL else { return }
        let state = PersistedState(buckets: energyBuckets, sessionStartMinute: sessionStartMinute,
                                   lastExternal: lastExternal, batteryRefLevel: batteryRefLevel)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = self.sampleRawCandidates()
            self.scheduleBackgroundTimer()
        }
    }

    func menuWillOpen() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isMenuOpen = true
            self.stopBackgroundTimer()

            // 1. Immediately emit current snapshot from accumulated background history
            self.publishSample()

            // 2. Fast warm-up at 350ms to establish fresh CPU rate
            self.warmUpTimer?.cancel()
            let warmUp = DispatchSource.makeTimerSource(queue: self.queue)
            warmUp.schedule(deadline: .now() + .milliseconds(350))
            warmUp.setEventHandler { [weak self] in
                guard let self = self, self.isMenuOpen else { return }
                self.publishSample()
                self.warmUpTimer = nil
            }
            self.warmUpTimer = warmUp
            warmUp.resume()

            // 3. Repeating 1.0s foreground timer in sync with UI
            self.startForegroundTimer()
        }
    }

    func menuDidClose() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isMenuOpen = false
            self.stopForegroundTimer()
            self.warmUpTimer?.cancel()
            self.warmUpTimer = nil
            self.scheduleBackgroundTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isMenuOpen = false
            self.stopForegroundTimer()
            self.stopBackgroundTimer()
            self.warmUpTimer?.cancel()
            self.warmUpTimer = nil
            self.prevCpuSamples.removeAll(keepingCapacity: true)
            self.prevEnergyByPid.removeAll(keepingCapacity: true)
            self.savePersistedState()
        }
    }

    private func startForegroundTimer() {
        stopForegroundTimer()
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.publishSample()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopForegroundTimer() {
        timer?.cancel()
        timer = nil
    }

    private func scheduleBackgroundTimer() {
        stopBackgroundTimer()
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        // Background sample every 15 seconds with 1000ms leeway for battery efficiency
        timer.schedule(deadline: .now() + .seconds(15), repeating: .seconds(15), leeway: .milliseconds(1000))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isMenuOpen else { return }
            _ = self.sampleRawCandidates()
        }
        self.backgroundTimer = timer
        timer.resume()
    }

    private func stopBackgroundTimer() {
        backgroundTimer?.cancel()
        backgroundTimer = nil
    }

    private func publishSample() {
        let snapshot = sampleSnapshot()
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    private struct RawCandidate {
        let pid: pid_t
        let normalizedCpuPercent: Double
        let memoryBytes: UInt64
        let powerWatts: Double
        let energyScore: Double
        let hasEnergyNj: Bool
    }

    private func sampleRawCandidates() -> [RawCandidate] {
        // All processes (including root daemons): their energy is attributed to "macOS System"
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
        let now = Date.timeIntervalSinceReferenceDate

        updateBatteryDrain(now: now)

        var candidates: [RawCandidate] = []
        candidates.reserveCapacity(count)
        var activePids = Set<pid_t>()
        activePids.reserveCapacity(count)

        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 || pid == ownPid { continue }
            activePids.insert(pid)

            var taskInfo = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &taskInfo, size) > 0 else {
                // Not inspectable (typically root daemons): count energy only, as macOS System
                var ru = rusage_info_v6()
                let res = proc_pid_rusage(pid, RUSAGE_INFO_V6, withUnsafeMutablePointer(to: &ru) {
                    UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)
                })
                if res == 0 && ru.ri_energy_nj > 0 {
                    if let prev = prevEnergyByPid[pid], ru.ri_energy_nj >= prev {
                        addEnergy(Double(ru.ri_energy_nj - prev) / 1_000_000_000.0, key: "system:macos", now: now)
                    }
                    prevEnergyByPid[pid] = ru.ri_energy_nj
                }
                continue
            }

            let totalTicks = taskInfo.ptinfo.pti_total_user + taskInfo.ptinfo.pti_total_system

            // 1. CPU calculation: only accept deltas under 2.5s to avoid stale burst artifacts
            var rawCpuPercent = 0.0
            if let prev = prevCpuSamples[pid] {
                let wallNs = (now - prev.time) * 1_000_000_000.0
                if wallNs > 0 && wallNs < 2_500_000_000.0 && totalTicks >= prev.totalTicks {
                    let deltaTicks = totalTicks - prev.totalTicks
                    let deltaNs = Double(deltaTicks) * Double(timebase.numer) / Double(max(1, timebase.denom))
                    rawCpuPercent = (deltaNs / wallNs) * 100.0
                }
            }
            prevCpuSamples[pid] = (totalTicks, now)

            let normalizedCpuPercent = min(100.0, max(0.0, rawCpuPercent / logicalCores))

            // 2. Memory: Physical footprint via rusage_info_v6
            var rusage = rusage_info_v6()
            let rusageRes = proc_pid_rusage(pid, RUSAGE_INFO_V6, withUnsafeMutablePointer(to: &rusage) {
                UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)
            })

            let memoryBytes: UInt64
            if rusageRes == 0 && rusage.ri_phys_footprint > 0 {
                memoryBytes = rusage.ri_phys_footprint
            } else {
                memoryBytes = taskInfo.ptinfo.pti_resident_size
            }

            // 3. Energy: Track per-app deltas in time buckets
            var hasEnergyNj = false
            var deltaJoules = 0.0

            let meta = resolveMeta(for: pid)
            trackedAppsMeta[meta.mainKey] = TrackedAppMeta(name: meta.displayName, appPath: meta.appPath, primaryPid: pid)

            if rusageRes == 0 && rusage.ri_energy_nj > 0 {
                hasEnergyNj = true
                let currentEnergy = rusage.ri_energy_nj
                if let prev = prevEnergyByPid[pid] {
                    if currentEnergy >= prev {
                        deltaJoules = Double(currentEnergy - prev) / 1_000_000_000.0
                    }
                }
                prevEnergyByPid[pid] = currentEnergy
            } else {
                // Intel fallback: estimate proportional energy from CPU ticks and wakeups
                let wakeups = Double(rusage.ri_pkg_idle_wkups + rusage.ri_interrupt_wkups)
                if let prev = prevCpuSamples[pid], totalTicks >= prev.totalTicks {
                    let deltaTicks = totalTicks - prev.totalTicks
                    let deltaNs = Double(deltaTicks) * Double(timebase.numer) / Double(max(1, timebase.denom))
                    deltaJoules = (deltaNs / 1_000_000_000.0) * 15.0 + (wakeups * 0.001)
                }
            }

            if deltaJoules > 0.0 {
                // Processes of other users (root daemons) belong to macOS System
                let energyKey = taskInfo.pbsd.pbi_uid == getuid() ? meta.mainKey : "system:macos"
                addEnergy(deltaJoules, key: energyKey, now: now)
            }

            candidates.append(RawCandidate(
                pid: pid,
                normalizedCpuPercent: normalizedCpuPercent,
                memoryBytes: memoryBytes,
                powerWatts: 0.0,
                energyScore: deltaJoules,
                hasEnergyNj: hasEnergyNj
            ))
        }

        prevCpuSamples = prevCpuSamples.filter { activePids.contains($0.key) }
        prevEnergyByPid = prevEnergyByPid.filter { activePids.contains($0.key) }

        let minuteIndex = Int64(now / 60.0)
        let cutoffMinute = minuteIndex - 1440 // 24 hours retention
        energyBuckets.removeAll { $0.minuteIndex < cutoffMinute }

        if minuteIndex != lastSavedMinute {
            lastSavedMinute = minuteIndex
            savePersistedState()
        }

        return candidates
    }

    private func currentBucket(now: TimeInterval) -> Int {
        let minuteIndex = Int64(now / 60.0)
        if let lastIdx = energyBuckets.indices.last, energyBuckets[lastIdx].minuteIndex == minuteIndex {
            return lastIdx
        }
        energyBuckets.append(MinuteBucket(minuteIndex: minuteIndex, joulesByApp: [:]))
        return energyBuckets.count - 1
    }

    private func addEnergy(_ joules: Double, key: String, now: TimeInterval) {
        guard joules > 0 else { return }
        let idx = currentBucket(now: now)
        energyBuckets[idx].joulesByApp[key, default: 0.0] += joules
    }

    private var batteryRefLevel: Double?

    /// Battery level in percent (fractional, from raw capacity) and whether external power is connected.
    private func readBatteryLevel() -> (level: Double, external: Bool)? {
        let entry = IOServiceGetMatchingService(mach_port_t(0), IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let external = (dict["ExternalConnected"] as? Bool) ?? false
        if let cur = dict["AppleRawCurrentCapacity"] as? Double,
           let max = dict["AppleRawMaxCapacity"] as? Double, max > 0 {
            return (cur / max * 100.0, external)
        }
        if let cur = dict["CurrentCapacity"] as? Double { return (cur, external) }
        return nil
    }

    /// Accumulates real battery discharge (in %) into the current minute bucket.
    private func updateBatteryDrain(now: TimeInterval) {
        guard let (level, external) = readBatteryLevel() else { return }
        let nowMinute = Int64(now / 60.0)
        if let was = lastExternal {
            if was && !external { sessionStartMinute = nowMinute }
        } else if !external && sessionStartMinute == nil {
            sessionStartMinute = nowMinute
        }
        lastExternal = external
        guard let ref = batteryRefLevel else { batteryRefLevel = level; return }
        if external {
            batteryRefLevel = level
        } else if ref - level >= 0.2 {
            let idx = currentBucket(now: now)
            energyBuckets[idx].batteryDrainPercent += ref - level
            batteryRefLevel = level
        } else if level > ref + 0.2 {
            batteryRefLevel = level
        }
    }

    private func sampleSnapshot() -> TopProcessesSnapshot {
        let candidates = sampleRawCandidates()
        guard !candidates.isEmpty else { return .empty }

        struct AggregatedProcess {
            var primaryPid: pid_t
            var name: String
            var appPath: String?
            var helperCount: Int
            var maxCandidateCpu: Double
            var normalizedCpuPercent: Double
            var memoryBytes: UInt64
            var powerWatts: Double
            var energyScore: Double
            var hasEnergyNj: Bool
        }

        var aggregated: [String: AggregatedProcess] = [:]
        aggregated.reserveCapacity(candidates.count)

        for candidate in candidates {
            let meta = resolveMeta(for: candidate.pid)
            if var existing = aggregated[meta.mainKey] {
                existing.helperCount += 1
                if candidate.normalizedCpuPercent > existing.maxCandidateCpu {
                    existing.maxCandidateCpu = candidate.normalizedCpuPercent
                    existing.primaryPid = candidate.pid
                }
                existing.normalizedCpuPercent += candidate.normalizedCpuPercent
                existing.memoryBytes += candidate.memoryBytes
                existing.powerWatts += candidate.powerWatts
                existing.energyScore += candidate.energyScore
                aggregated[meta.mainKey] = existing
            } else {
                aggregated[meta.mainKey] = AggregatedProcess(
                    primaryPid: candidate.pid,
                    name: meta.displayName,
                    appPath: meta.appPath,
                    helperCount: 1,
                    maxCandidateCpu: candidate.normalizedCpuPercent,
                    normalizedCpuPercent: candidate.normalizedCpuPercent,
                    memoryBytes: candidate.memoryBytes,
                    powerWatts: candidate.powerWatts,
                    energyScore: candidate.energyScore,
                    hasEnergyNj: candidate.hasEnergyNj
                )
            }
        }

        let allAggregated = Array(aggregated.values)

        // Top 5 CPU
        let topCpu = allAggregated
            .sorted { $0.normalizedCpuPercent > $1.normalizedCpuPercent }
            .prefix(5)
            .map { item -> ProcessDisplayItem in
                let fraction = min(1.0, max(0.01, item.normalizedCpuPercent / 100.0))
                let text = String(format: "%.1f%%", item.normalizedCpuPercent)
                let name: String
                if item.appPath == "system:macos" || item.name == "macOS System" {
                    name = "macOS System"
                } else if item.helperCount > 1 {
                    name = "\(item.name) (\(item.helperCount))"
                } else {
                    name = item.name
                }
                let icon = self.cachedIcon(for: item.appPath)
                return ProcessDisplayItem(
                    pid: item.primaryPid,
                    name: name,
                    icon: icon,
                    helperCount: item.helperCount,
                    fraction: fraction,
                    formattedValue: text,
                    normalizedCpuPercent: item.normalizedCpuPercent,
                    memoryBytes: item.memoryBytes,
                    energyScore: item.energyScore,
                    isWatts: item.hasEnergyNj
                )
            }

        // Top 5 RAM
        let topRam = allAggregated
            .sorted { $0.memoryBytes > $1.memoryBytes }
            .prefix(5)
            .map { item -> ProcessDisplayItem in
                let fraction = min(1.0, max(0.01, Double(item.memoryBytes) / self.totalRamBytes))
                let text: String
                let gb = Double(item.memoryBytes) / 1_073_741_824.0
                if gb >= 1.0 {
                    text = String(format: "%.1f GB", gb)
                } else {
                    let mb = Double(item.memoryBytes) / 1_048_576.0
                    text = String(format: "%.0f MB", max(1.0, mb))
                }
                let name: String
                if item.appPath == "system:macos" || item.name == "macOS System" {
                    name = "macOS System"
                } else if item.helperCount > 1 {
                    name = "\(item.name) (\(item.helperCount))"
                } else {
                    name = item.name
                }
                let icon = self.cachedIcon(for: item.appPath)
                return ProcessDisplayItem(
                    pid: item.primaryPid,
                    name: name,
                    icon: icon,
                    helperCount: item.helperCount,
                    fraction: fraction,
                    formattedValue: text,
                    normalizedCpuPercent: item.normalizedCpuPercent,
                    memoryBytes: item.memoryBytes,
                    energyScore: item.energyScore,
                    isWatts: item.hasEnergyNj
                )
            }

        // Top 5 Energy: accumulated share (% of total energy) over the selected window (30m ... 10h)
        let windowSeconds = Preferences.shared.energyAveragingWindow
        let windowMinutes = max(1, Int64(ceil(Double(windowSeconds) / 60.0)))
        let currentMinute = Int64(Date.timeIntervalSinceReferenceDate / 60.0)
        let sinceUnplug = Preferences.shared.energySinceUnplug
        let startMinute: Int64
        if sinceUnplug, let session = sessionStartMinute {
            startMinute = session
        } else {
            startMinute = currentMinute - windowMinutes
        }
        let effectiveWindowMinutes = max(1, currentMinute - startMinute)

        var appJoulesMap: [String: Double] = [:]
        var totalWindowJoules: Double = 0.0
        var windowDrainPercent: Double = 0.0
        var firstMinuteInWindow: Int64 = currentMinute

        for bucket in energyBuckets where bucket.minuteIndex >= startMinute {
            firstMinuteInWindow = min(firstMinuteInWindow, bucket.minuteIndex)
            windowDrainPercent += bucket.batteryDrainPercent
            for (appKey, joules) in bucket.joulesByApp {
                appJoulesMap[appKey, default: 0.0] += joules
                totalWindowJoules += joules
            }
        }

        let sortedEnergyApps = appJoulesMap.sorted { $0.value > $1.value }
        let topEnergy: [ProcessDisplayItem]

        let batteryJoulesPerPercent = self.batteryJoulesPerPercent
        if !sortedEnergyApps.isEmpty && totalWindowJoules > 0.0001 {
            // Measured per-process energy covers only a fraction of real consumption (CPU side),
            // so scale it to the actual battery discharge observed in the window.
            // Without observed discharge (e.g. on AC) fall back to the raw joule estimate.
            // Effective observed duration (the app may have run for less than the window), at least 5 min
            let observedHours = Double(max(5, min(effectiveWindowMinutes, currentMinute - firstMinuteInWindow + 1))) / 60.0
            let scale = windowDrainPercent > 0 ? windowDrainPercent / totalWindowJoules : 1.0 / batteryJoulesPerPercent
            topEnergy = sortedEnergyApps.prefix(5).map { (appKey, joules) in
                let batteryPoints = joules * scale
                // Gauge = share of total battery drain in the window (not relative to the leader)
                let fraction = min(1.0, max(0.02, joules / max(0.0001, totalWindowJoules)))
                let text: String
                if batteryPoints >= 10.0 {
                    text = String(format: "%.0f%%", batteryPoints)
                } else if batteryPoints >= 0.1 {
                    text = String(format: "%.1f%%", batteryPoints)
                } else {
                    text = "< 0.1%"
                }

                let isSystem = (appKey == "system:macos")
                let liveItem = allAggregated.first { self.resolveMeta(for: $0.primaryPid).mainKey == appKey }
                let meta = self.trackedAppsMeta[appKey]

                let baseName: String
                if isSystem {
                    baseName = "macOS System"
                } else {
                    let rawName = liveItem?.name ?? meta?.name ?? (appKey.starts(with: "pid:") ? "Process" : appKey)
                    let helperCount = liveItem?.helperCount ?? 1
                    baseName = helperCount > 1 ? "\(rawName) (\(helperCount))" : rawName
                }

                let appPath = isSystem ? "system:macos" : (liveItem?.appPath ?? meta?.appPath)
                let icon = self.cachedIcon(for: appPath)
                let pid = liveItem?.primaryPid ?? meta?.primaryPid ?? 0
                let helperCount = isSystem ? 1 : (liveItem?.helperCount ?? 1)

                return ProcessDisplayItem(
                    pid: pid,
                    name: baseName,
                    icon: icon,
                    helperCount: helperCount,
                    fraction: fraction,
                    formattedValue: text,
                    normalizedCpuPercent: liveItem?.normalizedCpuPercent ?? 0.0,
                    memoryBytes: liveItem?.memoryBytes ?? 0,
                    energyScore: joules,
                    isWatts: false,
                    energyRatePerHour: batteryPoints / observedHours
                )
            }
        } else {
            // Warm-up / initial launch: show active apps with 0% until deltas accumulate
            topEnergy = allAggregated
                .sorted { $0.normalizedCpuPercent > $1.normalizedCpuPercent }
                .prefix(5)
                .map { item in
                    let name = (item.appPath == "system:macos" || item.name == "macOS System") ? "macOS System" : item.name
                    return ProcessDisplayItem(
                        pid: item.primaryPid,
                        name: name,
                        icon: self.cachedIcon(for: item.appPath),
                        helperCount: item.helperCount,
                        fraction: 0.02,
                        formattedValue: "0%",
                        normalizedCpuPercent: item.normalizedCpuPercent,
                        memoryBytes: item.memoryBytes,
                        energyScore: 0.0,
                        isWatts: false
                    )
                }
        }

        var result = TopProcessesSnapshot(
            cpu: Array(topCpu),
            memory: Array(topRam),
            energy: Array(topEnergy)
        )
        if sinceUnplug, sessionStartMinute != nil {
            result.energySinceUnplugMinutes = Int(effectiveWindowMinutes)
        }
        return result
    }

    private func resolveMeta(for pid: pid_t) -> ResolvedMeta {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let bundleId = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? app.bundleIdentifier ?? "App \(pid)"
            let appPath = app.bundleURL.flatMap { findRootAppBundle(in: $0.path) }

            // Internal system daemons without app bundle in user applications
            let fullPath = app.bundleURL?.path ?? ""
            if isSystemProcess(path: fullPath, bundleId: bundleId) {
                return ResolvedMeta(mainKey: "system:macos", displayName: "macOS System", appPath: "system:macos")
            }

            let mainKey = appPath ?? (!bundleId.isEmpty ? "bundle:\(bundleId)" : "pid:\(pid)")
            return ResolvedMeta(mainKey: mainKey, displayName: name, appPath: appPath)
        }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            let path = String(cString: pathBuffer)

            if isSystemProcess(path: path, bundleId: "") {
                return ResolvedMeta(mainKey: "system:macos", displayName: "macOS System", appPath: "system:macos")
            }

            if let rootApp = findRootAppBundle(in: path) {
                if let cached = metaCache[rootApp] {
                    return cached
                }
                let url = URL(fileURLWithPath: rootApp)
                let name = url.deletingPathExtension().lastPathComponent
                let meta = ResolvedMeta(mainKey: rootApp, displayName: name, appPath: rootApp)
                if metaCache.count < 150 {
                    metaCache[rootApp] = meta
                }
                return meta
            }

            if let cached = metaCache[path] {
                return cached
            }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let meta = ResolvedMeta(mainKey: path, displayName: name, appPath: nil)
            if metaCache.count < 150 {
                metaCache[path] = meta
            }
            return meta
        }

        return ResolvedMeta(mainKey: "pid:\(pid)", displayName: "PID \(pid)", appPath: nil)
    }

    private lazy var batteryJoulesPerPercent: Double = {
        detectBatteryJoulesPerPercent()
    }()

    private func detectBatteryJoulesPerPercent() -> Double {
        let entry = IOServiceGetMatchingService(mach_port_t(0), IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return 1878.0 }
        defer { IOObjectRelease(entry) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return 1878.0
        }

        let voltage = (dict["Voltage"] as? Double) ?? 11500.0
        let batteryData = dict["BatteryData"] as? [String: Any]
        let rawMaxCap = (batteryData?["AppleRawMaxCapacity"] as? Double) ?? (dict["AppleRawMaxCapacity"] as? Double) ?? 4500.0

        let totalJoules = (rawMaxCap * voltage / 1_000_000.0) * 3600.0
        if totalJoules > 30_000 {
            return totalJoules / 100.0
        }
        return 1878.0
    }

    private func isSystemProcess(path: String, bundleId: String) -> Bool {
        // Any process inside /Applications or user directories or package managers is user software
        if path.contains("/Applications/") || path.contains("/Users/") || path.contains("/opt/homebrew/") || path.contains("/usr/local/") {
            return false
        }
        // Apple system daemons, core services, and private frameworks
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/Library/Apple/") {
            return true
        }
        if bundleId.hasPrefix("com.apple.") && !path.contains(".app") {
            return true
        }
        return false
    }

    private func findRootAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app") else { return nil }
        return String(path[..<range.upperBound])
    }

    private func cachedIcon(for appPath: String?) -> NSImage? {
        guard let appPath = appPath else {
            return defaultCliIcon()
        }
        if appPath == "system:macos" {
            if let icon = iconCache["system:macos"] {
                return icon
            }
            if #available(macOS 11.0, *) {
                if let apple = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "macOS System") {
                    iconCache["system:macos"] = apple
                    return apple
                }
            }
            let icon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
            iconCache["system:macos"] = icon
            return icon
        }
        if let icon = iconCache[appPath] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        if iconCache.count < 100 {
            iconCache[appPath] = icon
        }
        return icon
    }

    private func defaultCliIcon() -> NSImage? {
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        }
        return nil
    }
}
