import Foundation

struct InterfaceCounters: Equatable {
    let index: UInt32
    let input: UInt64
    let output: UInt64
}

enum NetworkInterfaceReader {
    /// Auto counts the transport layer once: physical network counters already
    /// include VPN packets. A manually selected tunnel counts only that tunnel.
    static func selected(_ entries: [String: InterfaceCounters], locked: String?) -> [String: InterfaceCounters] {
        if let locked = locked {
            return entries.filter { $0.key == locked }
        }
        return entries.filter { $0.key.hasPrefix("en") || $0.key.hasPrefix("pdp_ip") }
    }

    static func snapshot(locked: String?) -> [String: InterfaceCounters] {
        selected(allCounters(), locked: locked)
    }

    static func activeInterfaces() -> [(displayName: String, rawName: String?)] {
        var result: [(String, String?)] = [("Auto (network + VPN, no duplicates)", nil)]
        for name in allCounters().keys.sorted() {
            result.append((name.hasPrefix("utun") ? "VPN Tunnel (\(name))" : "Network (\(name))", name))
        }
        return result
    }

    private static func allCounters() -> [String: InterfaceCounters] {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return [:] }
        defer { freeifaddrs(address) }
        var result: [String: InterfaceCounters] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = ptr.pointee
            guard item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let namePtr = item.ifa_name,
                  let data = item.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: namePtr)
            guard name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("pdp_ip") else { continue }
            result[name] = InterfaceCounters(index: if_nametoindex(namePtr),
                input: UInt64(data.pointee.ifi_ibytes), output: UInt64(data.pointee.ifi_obytes))
        }
        return result
    }
}
