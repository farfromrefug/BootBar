import Darwin
import Foundation

/// The Mac's addresses on the local network, which is where a phone sends its proxied traffic.
public enum LocalNetwork {
    /// IPv4 addresses of the active interfaces other than loopback, Wi-Fi and Ethernet first.
    public static func ipv4Addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: entry.ifa_name)
            // bridges and tunnels (utun, bridge100 of the simulators…) are not where a phone connects
            guard name.hasPrefix("en") else { continue }
            found.append((name, String(cString: host)))
        }
        return found.sorted { $0.name < $1.name }.map(\.address)
    }
}
