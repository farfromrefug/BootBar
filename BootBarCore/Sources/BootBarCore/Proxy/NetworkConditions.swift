import Foundation

/// A slow or missing network, applied to what passes through the proxy. The presets follow the ones of Apple's
/// Network Link Conditioner.
public struct NetworkConditions: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    /// Added once to every request and every new connection, in milliseconds.
    public var latencyMs: Int
    /// Kilobits per second the device can download and upload; 0 is no limit.
    public var downKbps: Int
    public var upKbps: Int
    /// Every connection fails.
    public var offline: Bool

    public var id: String { name }

    public init(name: String, latencyMs: Int = 0, downKbps: Int = 0, upKbps: Int = 0, offline: Bool = false) {
        self.name = name
        self.latencyMs = latencyMs
        self.downKbps = downKbps
        self.upKbps = upKbps
        self.offline = offline
    }

    public var isLimited: Bool { offline || latencyMs > 0 || downKbps > 0 || upKbps > 0 }

    public static let online = NetworkConditions(name: "No Limit")
    public static let offlineProfile = NetworkConditions(name: "Offline", offline: true)

    public static let presets: [NetworkConditions] = [
        .online,
        NetworkConditions(name: "Wi-Fi", latencyMs: 1, downKbps: 40_000, upKbps: 33_000),
        NetworkConditions(name: "LTE", latencyMs: 50, downKbps: 50_000, upKbps: 10_000),
        NetworkConditions(name: "3G", latencyMs: 100, downKbps: 780, upKbps: 330),
        NetworkConditions(name: "Edge", latencyMs: 400, downKbps: 240, upKbps: 200),
        NetworkConditions(name: "Very Bad Network", latencyMs: 500, downKbps: 1_000, upKbps: 1_000),
        .offlineProfile,
    ]

    /// A short description for menus: `3G · 780 kbps down, 330 up, 100 ms`.
    public var summary: String {
        if offline { return "No connection" }
        guard isLimited else { return "No limit" }
        var parts: [String] = []
        if downKbps > 0 || upKbps > 0 {
            parts.append("\(Self.rate(downKbps)) down, \(Self.rate(upKbps)) up")
        }
        if latencyMs > 0 { parts.append("\(latencyMs) ms") }
        return parts.joined(separator: ", ")
    }

    private static func rate(_ kbps: Int) -> String {
        kbps == 0 ? "unlimited" : kbps >= 1000 ? String(format: "%g Mbps", Double(kbps) / 1000) : "\(kbps) kbps"
    }

    /// How long `bytes` take at `kbps`; none without a limit.
    static func delay(bytes: Int, kbps: Int) -> TimeInterval {
        guard kbps > 0 else { return 0 }
        return Double(bytes) * 8 / (Double(kbps) * 1000)
    }
}

/// The conditions the server applies, changeable while connections are open.
final class ConditionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = NetworkConditions.online

    var value: NetworkConditions {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
