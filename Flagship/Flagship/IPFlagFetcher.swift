import Foundation
import Darwin

/// State and callbacks are serialized on main. Every batch has an identity,
/// so superseded network responses can never overwrite a newer flag.
final class IPFlagFetcher {
    static let unknownFlag = "🏳️"
    var onUpdate: ((String, String) -> Void)?
    private var lastConfirmedIP: String?
    private var generation = 0
    private var batch = 0
    private var tasks: [URLSessionDataTask] = []
    private var followups: [DispatchWorkItem] = []
    private var verifyingUntil: Date = .distantPast
    private var blockedUntil: [String: Date] = [:]
    private var session: URLSession
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        session = URLSession(configuration: configuration)
    }

    struct IPProvider {
        let name: String
        let url: String
        let parse: ([String: Any]) -> (ip: String, country: String)?
    }

    static let providers: [IPProvider] = [
        // ip-api.com — fast, reliable, uses HTTP (avoids some VPN TLS issues)
        IPProvider(name: "ip-api.com", url: "http://ip-api.com/json/?fields=query,countryCode") { json in
            guard let ip = json["query"] as? String,
                  let code = json["countryCode"] as? String else { return nil }
            return (ip, code)
        },
        // ipapi.co — HTTPS
        IPProvider(name: "ipapi.co", url: "https://ipapi.co/json/") { json in
            guard let ip = json["ip"] as? String,
                  let code = json["country_code"] as? String else { return nil }
            return (ip, code)
        },
        // api.country.is — HTTPS (the original)
        IPProvider(name: "country.is", url: "https://api.country.is/") { json in
            guard let ip = json["ip"] as? String,
                  let code = json["country"] as? String else { return nil }
            return (ip, code)
        },
        // ipinfo.io — HTTPS
        IPProvider(name: "ipinfo.io", url: "https://ipinfo.io/json") { json in
            guard let ip = json["ip"] as? String,
                  let code = json["country"] as? String else { return nil }
            return (ip, code)
        },
        // ipwho.is — HTTPS
        IPProvider(name: "ipwho.is", url: "https://ipwho.is/") { json in
            guard let ip = json["ip"] as? String,
                  let code = json["country_code"] as? String else { return nil }
            return (ip, code)
        },
    ]

    /// Periodic checks never interrupt a network-change verification sequence.
    func fetch(force: Bool = false) {
        guard force || (tasks.isEmpty && Date() >= verifyingUntil) else { return }
        begin()
        performBatch(generation: generation, previousIP: nil, retriesLeft: 0)
    }

    /// No artificial delay before initial requests or error/same-IP retries.
    /// Independent checks at 1s and 3s catch routing that settles after the first response.
    func fetchWithRetry(maxRetries: Int = 2) {
        let previousIP = lastConfirmedIP
        begin()
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration)
        let generation = self.generation
        verifyingUntil = Date().addingTimeInterval(3)
        performBatch(generation: generation, previousIP: previousIP, retriesLeft: maxRetries)
        for delay in [1.0, 3.0] {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.generation == generation else { return }
                self.onUpdate?(Self.unknownFlag, "Checking country…")
                self.performBatch(generation: generation, previousIP: nil, retriesLeft: 0)
            }
            followups.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func begin() {
        generation += 1
        batch += 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        followups.forEach { $0.cancel() }
        followups.removeAll()
        onUpdate?(Self.unknownFlag, "Checking country…")
    }

    private func performBatch(generation: Int, previousIP: String?, retriesLeft: Int) {
        guard self.generation == generation else { return }
        batch += 1
        let batch = self.batch
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        let selected = Preferences.shared.enabledIPProviders
        let available = Self.providers.filter { selected.contains($0.name) && (blockedUntil[$0.url] ?? .distantPast) <= Date() }
        guard !available.isEmpty else {
            onUpdate?(Self.unknownFlag, "Country unavailable")
            return
        }
        var remaining = available.count
        var won = false
        for provider in available {
            var request = URLRequest(url: URL(string: provider.url)!)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("Flagship/1.2", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == generation, self.batch == batch else { return }
                    let http = response as? HTTPURLResponse
                    if http?.statusCode == 429 {
                        let seconds = Self.retryDelay(http?.value(forHTTPHeaderField: "Retry-After"))
                        self.blockedUntil[provider.url] = Date().addingTimeInterval(max(1, seconds))
                    } else if http?.value(forHTTPHeaderField: "X-Rl") == "0" {
                        let seconds = http?.value(forHTTPHeaderField: "X-Ttl").flatMap(Double.init) ?? 60
                        self.blockedUntil[provider.url] = Date().addingTimeInterval(max(1, seconds))
                    }
                    remaining -= 1
                    guard !won else {
                        if remaining == 0 { self.tasks.removeAll() }
                        return
                    }
                    if error == nil, let http = http, (200..<300).contains(http.statusCode),
                       let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let result = provider.parse(json), let flag = Self.flag(country: result.country),
                       Self.isIPAddress(result.ip) {
                        won = true
                        self.lastConfirmedIP = result.ip
                        if remaining == 0 { self.tasks.removeAll() }
                        if result.ip == previousIP, retriesLeft > 0 {
                            self.performBatch(generation: generation, previousIP: previousIP, retriesLeft: retriesLeft - 1)
                        } else {
                            self.onUpdate?(flag, result.ip)
                        }
                    } else if remaining == 0 {
                        self.tasks.removeAll()
                        if retriesLeft > 0 {
                            self.performBatch(generation: generation, previousIP: previousIP, retriesLeft: retriesLeft - 1)
                        } else {
                            self.onUpdate?(Self.unknownFlag, "Country unavailable")
                        }
                    }
                }
            }
            tasks.append(task)
            task.resume()
        }
    }

    /// Tests every provider independently without changing the active lookup or its cooldowns.
    func testProviders(onResult: @escaping (String, String) -> Void) {
        for provider in Self.providers {
            var request = URLRequest(url: URL(string: provider.url)!)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("Flagship/1.2", forHTTPHeaderField: "User-Agent")
            session.dataTask(with: request) { data, response, error in
                var resultText = "Unavailable"
                if error == nil, let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode), let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = provider.parse(json), let flag = Self.flag(country: result.country),
                   Self.isIPAddress(result.ip) {
                    resultText = "\(flag)  \(result.country.uppercased())  ·  \(result.ip)"
                }
                let text = resultText
                DispatchQueue.main.async { onResult(provider.name, text) }
            }.resume()
        }
    }

    static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval {
        guard let header = header else { return 3600 }
        if let seconds = Double(header) { return max(1, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: header).map { max(1, $0.timeIntervalSince(now)) } ?? 3600
    }

    static func flag(country: String) -> String? {
        let country = country.uppercased()
        guard country.utf8.count == 2, country != "ZZ", Locale.Region.isoRegions.contains(where: { $0.identifier == country }),
              country.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(country.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }

    private static func isIPAddress(_ ip: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return ip.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }

    deinit {
        tasks.forEach { $0.cancel() }
        followups.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }
}
