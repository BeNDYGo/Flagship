import Foundation

/// Owns all SMC and Mach sampling on one serial background queue.
final class SystemMonitor {
    var onUpdate: ((CPUStats, MemoryStats) -> Void)?
    private let queue = DispatchQueue(label: "flagship.system", qos: .utility)
    private var timer: DispatchSourceTimer?
    private lazy var engine = StatsEngine()

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let cpu = self.engine.fetchCPUStats()
            let memory = self.engine.fetchMemoryStats()
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(cpu, memory)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }
}
