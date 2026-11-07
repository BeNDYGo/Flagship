import Foundation

struct SystemHistorySample {
    let time: TimeInterval
    let cpu: Double
    let memoryGB: Double
    let memoryPercent: Double
    let totalMemoryGB: Double
    let temperature: Double?
    let instantTemperature: Double?
    let isThermalSpike: Bool
}

struct NetworkHistorySample {
    let time: TimeInterval
    let upload: Double
    let download: Double
}

/// Main-thread-only, bounded in-memory history. Never writes usage data to disk.
final class MetricsHistory {
    let duration: TimeInterval = 300
    private(set) var system: [SystemHistorySample] = []
    private(set) var network: [NetworkHistorySample] = []

    func append(cpu: CPUStats, memory: MemoryStats, at time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        system.append(SystemHistorySample(time: time, cpu: cpu.usagePercent,
            memoryGB: memory.usedGB, memoryPercent: memory.usedPercent,
            totalMemoryGB: memory.totalGB,
            temperature: cpu.temperature > 0 ? cpu.temperature : nil,
            instantTemperature: cpu.instantTemperature > 0 ? cpu.instantTemperature : nil,
            isThermalSpike: cpu.isThermalSpike))
        prune(at: time)
    }

    func append(upload: Double, download: Double, at time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        network.append(NetworkHistorySample(time: time, upload: upload, download: download))
        prune(at: time)
    }

    private func prune(at time: TimeInterval) {
        system.removeAll { $0.time < time - duration }
        network.removeAll { $0.time < time - duration }
        if system.count > 600 { system.removeFirst(system.count - 600) }
        if network.count > 600 { network.removeFirst(network.count - 600) }
    }
}
