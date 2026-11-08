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
}

public struct TopProcessesSnapshot {
    public let cpu: [ProcessDisplayItem]
    public let memory: [ProcessDisplayItem]
    public let energy: [ProcessDisplayItem]

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
    private var prevEnergySamples = [pid_t: (energyNj: UInt64, time: TimeInterval)]()

    private struct ResolvedMeta {
        let mainKey: String
        let displayName: String
        let appPath: String?
    }
    private var metaCache = [String: ResolvedMeta]()
    private var iconCache = [String: NSImage]()

    init() {
        mach_timebase_info(&timebase)
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, self.timer == nil else { return }

            // 1. Baseline sample at t = 0 to establish tick reference
            _ = self.sampleRawCandidates()

            // 2. Fast warm-up at 350ms: calculates instantaneous rate so the UI shows data immediately
            let warmUp = DispatchSource.makeTimerSource(queue: self.queue)
            warmUp.schedule(deadline: .now() + .milliseconds(350))
            warmUp.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.publishSample()
                self.warmUpTimer = nil
            }
            self.warmUpTimer = warmUp
            warmUp.resume()

            // 3. Repeating timer at 1.0s in lockstep with SystemMonitor
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                self?.publishSample()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.warmUpTimer?.cancel()
            self.warmUpTimer = nil
            self.timer?.cancel()
            self.timer = nil
            // Clear tick history to prevent stale multi-minute averages on next open
            self.prevCpuSamples.removeAll(keepingCapacity: true)
            self.prevEnergySamples.removeAll(keepingCapacity: true)
        }
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
        var pids = [pid_t](repeating: 0, count: 2048)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)
        let now = Date.timeIntervalSinceReferenceDate

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
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &taskInfo, size) > 0 else { continue }

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

            // 3. Energy: Watts on Apple Silicon (normalized to score * 12.5) or fallback Activity Monitor score
            var powerWatts = 0.0
            var energyScore = 0.0
            var hasEnergyNj = false

            if rusageRes == 0 && rusage.ri_energy_nj > 0 {
                hasEnergyNj = true
                if let prevEnergy = prevEnergySamples[pid] {
                    let deltaSec = now - prevEnergy.time
                    if deltaSec > 0 && deltaSec < 2.5 && rusage.ri_energy_nj >= prevEnergy.energyNj {
                        let deltaJoules = Double(rusage.ri_energy_nj - prevEnergy.energyNj) / 1_000_000_000.0
                        powerWatts = deltaJoules / deltaSec
                    }
                }
                prevEnergySamples[pid] = (rusage.ri_energy_nj, now)
                energyScore = powerWatts * 12.5
            } else {
                let deltaSec = now - (prevCpuSamples[pid]?.time ?? now)
                let wakeups = Double(rusage.ri_pkg_idle_wkups + rusage.ri_interrupt_wkups)
                let wakeupsPerSec = (deltaSec > 0 && deltaSec < 2.5) ? (wakeups / deltaSec) : 0.0
                energyScore = normalizedCpuPercent * 2.0 + min(20.0, wakeupsPerSec * 0.05)
            }

            candidates.append(RawCandidate(
                pid: pid,
                normalizedCpuPercent: normalizedCpuPercent,
                memoryBytes: memoryBytes,
                powerWatts: powerWatts,
                energyScore: energyScore,
                hasEnergyNj: hasEnergyNj
            ))
        }

        prevCpuSamples = prevCpuSamples.filter { activePids.contains($0.key) }
        prevEnergySamples = prevEnergySamples.filter { activePids.contains($0.key) }

        return candidates
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
                let name = item.helperCount > 1 ? "\(item.name) (\(item.helperCount))" : item.name
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
                let name = item.helperCount > 1 ? "\(item.name) (\(item.helperCount))" : item.name
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

        // Top 5 Energy (sorted uniformly by normalized energyScore)
        let topEnergy = allAggregated
            .sorted { $0.energyScore > $1.energyScore }
            .prefix(5)
            .map { item -> ProcessDisplayItem in
                let fraction: Double
                let text: String
                if item.hasEnergyNj {
                    fraction = min(1.0, max(0.01, item.powerWatts / 10.0))
                    if item.powerWatts >= 1.0 {
                        text = String(format: "%.1f W", item.powerWatts)
                    } else {
                        text = String(format: "%.0f mW", max(1.0, item.powerWatts * 1000.0))
                    }
                } else {
                    fraction = min(1.0, max(0.01, item.energyScore / 50.0))
                    text = String(format: "%.1f", item.energyScore)
                }
                let name = item.helperCount > 1 ? "\(item.name) (\(item.helperCount))" : item.name
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

        return TopProcessesSnapshot(
            cpu: Array(topCpu),
            memory: Array(topRam),
            energy: Array(topEnergy)
        )
    }

    private func resolveMeta(for pid: pid_t) -> ResolvedMeta {
        if let app = NSRunningApplication(processIdentifier: pid) {
            let bundleId = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? app.bundleIdentifier ?? "App \(pid)"
            let appPath = app.bundleURL.flatMap { findRootAppBundle(in: $0.path) }
            let mainKey = appPath ?? (!bundleId.isEmpty ? "bundle:\(bundleId)" : "pid:\(pid)")
            return ResolvedMeta(mainKey: mainKey, displayName: name, appPath: appPath)
        }

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            let path = String(cString: pathBuffer)
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

    private func findRootAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app") else { return nil }
        return String(path[..<range.upperBound])
    }

    private func cachedIcon(for appPath: String?) -> NSImage? {
        guard let appPath = appPath else {
            return defaultCliIcon()
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
