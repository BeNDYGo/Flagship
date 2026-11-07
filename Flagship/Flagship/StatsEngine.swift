// CPU, RAM and SMC sensor selection adapted from openhoangnc/mac-stats.
import Foundation
import MachO
import IOKit

public struct CPUStats {
    public var usagePercent: Double = 0.0
    public var userPercent: Double = 0.0
    public var systemPercent: Double = 0.0
    public var idlePercent: Double = 0.0
    public var coreCount: Int = 0
    /// Time-averaged temperature over the rolling window (e.g. 15s). 0 when unavailable.
    public var temperature: Double = 0.0
    /// Instantaneous mean across CPU sensors for the current second. 0 when unavailable.
    public var instantTemperature: Double = 0.0
    /// Highest temperature observed in the recent rolling window.
    public var peakTemperature: Double = 0.0
    /// Hottest individual CPU sensor — the reading thermal throttling acts on. 0 when no sensor is readable.
    public var maxTemperature: Double = 0.0
    /// True when the current instantaneous temperature represents a sudden thermal burst.
    public var isThermalSpike: Bool = false
}

public struct MemoryStats {
    public var usedBytes: UInt64 = 0
    public var totalBytes: UInt64 = 0
    public var activeBytes: UInt64 = 0
    public var wiredBytes: UInt64 = 0
    public var compressedBytes: UInt64 = 0
    public var freeBytes: UInt64 = 0

    public var usedGB: Double {
        return Double(usedBytes) / 1_073_741_824.0
    }
    
    public var totalGB: Double {
        return Double(totalBytes) / 1_073_741_824.0
    }
    
    public var usedPercent: Double {
        return totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes)) * 100.0 : 0.0
    }
}

public class StatsEngine {
    // Cached immutable system values (queried once)
    private let hostPort: mach_port_t = mach_host_self()
    private let totalPhysicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    private let cachedPageSize: UInt64
    
    // CPU delta tracking
    private var prevCpuInfo: processor_info_array_t?
    private var prevCpuInfoCount: mach_msg_type_number_t = 0
    
    /// An active CPU temperature key and which statistics it feeds.
    private struct TempSensor {
        let key: String
        let inAverage: Bool
        let inMax: Bool
    }

    // Active temperature keys cached after startup scan
    private var tempSensors: [TempSensor] = []
    
    // Rolling history of recent instantaneous temperature samples for time-averaging
    private var recentTemps: [(time: TimeInterval, temp: Double)] = []

    public init() {
        var pageSize: vm_size_t = 4096
        host_page_size(hostPort, &pageSize)
        cachedPageSize = UInt64(pageSize)
        
        self.tempSensors = scanTempSensors()
    }

    private static func isValidCPUTemp(_ val: Double) -> Bool {
        return val > 15.0 && val < 110.0
    }

    private func scanTempSensors() -> [TempSensor] {
        let smc = SMC.shared
        func isActive(_ key: String) -> Bool {
            guard let val = smc.getValue(key) else { return false }
            return Self.isValidCPUTemp(val)
        }
        // Keys with no a/b/x/z siblings are a single plain reading.
        func plain(_ keys: [String]) -> [TempSensor] {
            return keys.map { TempSensor(key: $0, inAverage: true, inMax: true) }
        }

        // Apple Silicon per-core / cluster sensors.
        let appleSiliconKeys = [
            // Base/General M1/M2/M3/M4/M5 CPU keys
            "Tc0a", "Tc0b", "Tc0x", "Tc0z",
            "Tc1a", "Tc1b", "Tc1x", "Tc1z",
            "Tc2a", "Tc2b", "Tc2x", "Tc2z",
            "Tc3a", "Tc3b", "Tc3x", "Tc3z",
            "Tc4a", "Tc4b", "Tc4x", "Tc4z",
            "Tc5a", "Tc5b", "Tc5x", "Tc5z",
            "Tc6a", "Tc6b", "Tc6x", "Tc6z",
            "Tc7a", "Tc7b", "Tc7x", "Tc7z",
            "Tc8a", "Tc8b", "Tc8x", "Tc8z",
            "Tc9a", "Tc9b", "Tc9x", "Tc9z",
            "Tcaa", "Tcab", "Tcax", "Tcaz",
            
            // M3/M4/M5 Efficiency cores
            "Te05", "Te0L", "Te0P", "Te0S", "Te09", "Te0H", "Te0a", "Te0b", "Te0x", "Te0z",
            "Te3a", "Te3b", "Te3x", "Te3z",
            
            // M3/M4 Performance cores
            "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
            
            // M1/M2 Pro/Max/Ultra and general Tp keys
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b", "Tp0e", "Tp0T", "Tp0V", "Tp0Y",
            "Tp1h", "Tp1t", "Tp1p", "Tp1l",
            "Tp2a", "Tp2b", "Tp2x", "Tp2z",
            "Tp3a", "Tp3b", "Tp3x", "Tp3z",
            "Tp4a", "Tp4b", "Tp4x", "Tp4z",
            "Tp5a", "Tp5b", "Tp5x", "Tp5z",
            "Tp7a", "Tp7b", "Tp7x", "Tp7z",
            "Tp8a", "Tp8b", "Tp8x", "Tp8z",
            "Tp9a", "Tp9b", "Tp9x", "Tp9z"
        ]
        
        // Keys sharing a stem in an a/b/x/z set (Tp2a, Tp2b, Tp2x, Tp2z) are
        // not four sensors but four views of one. Measured on an M1 against the
        // named HID sensors (pACC/eACC MTR) and the PMU die sensors:
        //   a — live reading (tracks the HID sensor)
        //   x — recent peak (2–6°C above `a`, holds after load drops)
        //   b, z — `a` and `x` plus a fixed per-sensor offset (9–16°C on P-cores,
        //          constant across load), so not a measurement; excluded.
        // The average uses `a`, the max uses `x`. A stem without both `a` and `x`
        // (e.g. M1 Pro's standalone Tp0b) is a plain reading.
        let appleSiliconActive = Set(appleSiliconKeys.filter(isActive))
        if !appleSiliconActive.isEmpty {
            var sensors: [TempSensor] = []
            for key in appleSiliconKeys where appleSiliconActive.contains(key) {
                let stem = String(key.dropLast())
                let isSet = appleSiliconActive.contains(stem + "a") && appleSiliconActive.contains(stem + "x")
                switch (isSet, key.last) {
                case (true, "a"): sensors.append(TempSensor(key: key, inAverage: true, inMax: false))
                case (true, "x"): sensors.append(TempSensor(key: key, inAverage: false, inMax: true))
                case (true, _): break
                default: sensors += plain([key])
                }
            }
            return sensors
        }

        // --- Intel Macs ---
        // Prefer the per-core die sensors (mirrors the Apple Silicon path
        // above). Both upper- and lower-case suffixes appear depending on the
        // model; only one set is ever active.
        let intelCoreKeys = [
            "TC0C", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C", "TC8C", "TC9C",
            "TC0c", "TC1c", "TC2c", "TC3c", "TC4c", "TC5c", "TC6c", "TC7c", "TC8c", "TC9c"
        ]
        let intelCoreActive = intelCoreKeys.filter(isActive)
        if !intelCoreActive.isEmpty { return plain(intelCoreActive) }

        // Fall back to a single summary sensor, in order of preference:
        // on-die diode, package, proximity, then heatsink.
        let intelFallbackKeys = ["TC0D", "TC0E", "TC0F", "TCAD", "TC0P", "TC0H"]
        if let key = intelFallbackKeys.first(where: isActive) {
            return plain([key])
        }
        return []
    }

    deinit {
        mach_port_deallocate(mach_task_self_, hostPort)
        if let prevCpuInfo = prevCpuInfo {
            let prevSize = MemoryLayout<integer_t>.size * Int(prevCpuInfoCount)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevSize))
        }
    }

    // MARK: - CPU Sampling
    public func fetchCPUStats() -> CPUStats {
        var stats = CPUStats()
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        
        let result = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &cpuInfoCount)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return stats
        }
        
        stats.coreCount = Int(numCPUs)
        
        if let prevCpuInfo = prevCpuInfo, prevCpuInfoCount == cpuInfoCount {
            var totalUser: UInt64 = 0
            var totalSystem: UInt64 = 0
            var totalIdle: UInt64 = 0
            var totalNice: UInt64 = 0
            var totalTicks: UInt64 = 0
            
            for i in 0..<Int(numCPUs) {
                let offset = Int(CPU_STATE_MAX) * i
                
                let userDelta = UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_USER)]) &- UInt32(bitPattern: prevCpuInfo[offset + Int(CPU_STATE_USER)]))
                let systemDelta = UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_SYSTEM)]) &- UInt32(bitPattern: prevCpuInfo[offset + Int(CPU_STATE_SYSTEM)]))
                let idleDelta = UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_IDLE)]) &- UInt32(bitPattern: prevCpuInfo[offset + Int(CPU_STATE_IDLE)]))
                let niceDelta = UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_NICE)]) &- UInt32(bitPattern: prevCpuInfo[offset + Int(CPU_STATE_NICE)]))
                
                totalUser += userDelta
                totalSystem += systemDelta
                totalIdle += idleDelta
                totalNice += niceDelta
                totalTicks += (userDelta + systemDelta + idleDelta + niceDelta)
            }
            
            if totalTicks > 0 {
                let totalActive = totalUser + totalSystem + totalNice
                stats.usagePercent = (Double(totalActive) / Double(totalTicks)) * 100.0
                stats.userPercent = (Double(totalUser) / Double(totalTicks)) * 100.0
                stats.systemPercent = (Double(totalSystem) / Double(totalTicks)) * 100.0
                stats.idlePercent = (Double(totalIdle) / Double(totalTicks)) * 100.0
            }
            
        }
        if let prevCpuInfo = prevCpuInfo {
            let prevSize = MemoryLayout<integer_t>.size * Int(prevCpuInfoCount)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevSize))
        }
        
        self.prevCpuInfo = cpuInfo
        self.prevCpuInfoCount = cpuInfoCount
        
        // Calculate CPU average and hottest-sensor temperature
        if !tempSensors.isEmpty {
            var sum: Double = 0.0
            var count = 0
            var hottest: Double = 0.0
            let smc = SMC.shared
            for sensor in tempSensors {
                guard let val = smc.getValue(sensor.key), Self.isValidCPUTemp(val) else { continue }
                if sensor.inAverage {
                    sum += val
                    count += 1
                }
                if sensor.inMax {
                    hottest = max(hottest, val)
                }
            }
            if count > 0 {
                let instant = sum / Double(count)
                stats.instantTemperature = instant
                stats.maxTemperature = hottest

                let now = Date.timeIntervalSinceReferenceDate
                let windowSec = Double(Preferences.shared.temperatureAveragingWindow)

                if windowSec <= 1 {
                    recentTemps = [(now, instant)]
                    stats.temperature = instant
                    stats.peakTemperature = instant
                    stats.isThermalSpike = false
                } else {
                    recentTemps.append((now, instant))
                    recentTemps.removeAll { $0.time < now - windowSec }
                    if recentTemps.count > 120 {
                        recentTemps.removeFirst(recentTemps.count - 120)
                    }
                    let sumRecent = recentTemps.reduce(0.0) { $0 + $1.temp }
                    let avg = sumRecent / Double(recentTemps.count)
                    stats.temperature = avg
                    stats.peakTemperature = recentTemps.map(\.temp).max() ?? instant

                    // A burst occurs when instantaneous temperature is hot (>= 78°C)
                    // and significantly exceeds the rolling average, or reaches a critical peak (>= 92°C).
                    let delta = instant - avg
                    stats.isThermalSpike = (instant >= 78.0 && delta >= 7.0) || instant >= 92.0
                }
            }
        }
        
        return stats
    }

    // MARK: - Memory Sampling
    public func fetchMemoryStats() -> MemoryStats {
        var stats = MemoryStats()
        stats.totalBytes = totalPhysicalMemory
        
        var stats64 = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        
        let kerr = withUnsafeMutablePointer(to: &stats64) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard kerr == KERN_SUCCESS else {
            return stats
        }
        
        let page = cachedPageSize
        let active = UInt64(stats64.active_count) * page
        let wired = UInt64(stats64.wire_count) * page
        let compressed = UInt64(stats64.compressor_page_count) * page
        let free = UInt64(stats64.free_count) * page
        
        stats.activeBytes = active
        stats.wiredBytes = wired
        stats.compressedBytes = compressed
        stats.freeBytes = free
        stats.usedBytes = active + wired + compressed
        
        return stats
    }

}
