import Foundation

final class NetworkMonitor {
    var onSpeedUpdate: ((String, String) -> Void)?
    var onRatesUpdate: ((Double, Double) -> Void)?
    private let queue = DispatchQueue(label: "flagship.networkmonitor")
    // Sampling state belongs to queue; generation is only accessed on main.
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var previous: [String: InterfaceCounters] = [:]
    private var lastTime: UInt64 = 0

    func start() {
        generation += 1
        let generation = self.generation
        let locked = Preferences.shared.lockedInterface
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.previous = NetworkInterfaceReader.snapshot(locked: locked)
            self.lastTime = DispatchTime.now().uptimeNanoseconds
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick(locked: locked, generation: generation) }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        generation += 1
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func tick(locked: String?, generation: Int) {
        let current = NetworkInterfaceReader.snapshot(locked: locked)
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - lastTime) / 1_000_000_000
        let rates = Self.rates(current: current, previous: previous, elapsed: elapsed)
        let download = rates.download
        let upload = rates.upload
        previous = current
        lastTime = now
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.generation == generation else { return }
            self.onSpeedUpdate?(Self.formatSpeed(upload), Self.formatSpeed(download))
            self.onRatesUpdate?(upload, download)
        }
    }

    static func rates(current: [String: InterfaceCounters], previous: [String: InterfaceCounters],
                      elapsed: Double) -> (upload: Double, download: Double) {
        var upload = 0.0
        var download = 0.0
        for (name, counters) in current {
            guard let old = previous[name], old.index == counters.index else { continue }
            upload += bytesPerSecond(current: counters.output, previous: old.output, elapsed: elapsed)
            download += bytesPerSecond(current: counters.input, previous: old.input, elapsed: elapsed)
        }
        return (upload, download)
    }

    static func bytesPerSecond(current: UInt64, previous: UInt64, elapsed: Double) -> Double {
        // A reset or removed interface starts a new baseline, not a traffic spike.
        guard elapsed > 0, current >= previous else { return 0 }
        return Double(current - previous) / elapsed
    }

    static func formatSpeed(_ bytes: Double) -> String {
        let value = max(0, bytes)
        if value < 1000 { return String(format: "%.0f B/s", value) }
        if value < 1_000_000 { return String(format: "%.1f KB/s", value / 1000) }
        if value < 1_000_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        return String(format: "%.1f GB/s", value / 1_000_000_000)
    }

    deinit { timer?.cancel() }
}
