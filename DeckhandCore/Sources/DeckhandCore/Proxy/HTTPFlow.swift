import Foundation

public struct HTTPHeader: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

extension Array where Element == HTTPHeader {
    /// The first header with this name, ignoring case.
    public func value(for name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// True when a comma-separated header such as `Connection` lists `token`.
    public func hasToken(_ token: String, in name: String) -> Bool {
        contains { header in
            header.name.caseInsensitiveCompare(name) == .orderedSame
                && header.value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame }
        }
    }
}

/// Who made a request: the process behind the connection, when it could be worked out.
public struct ClientInfo: Equatable, Sendable {
    public var app: String?
    public var pid: Int?
    public var executable: String?
    /// The simulator the process belongs to.
    public var deviceId: String?
    /// The address of a phone or tablet on the network, for clients that are not on this Mac.
    public var remoteAddress: String?

    public init(app: String? = nil, pid: Int? = nil, executable: String? = nil, deviceId: String? = nil,
                remoteAddress: String? = nil) {
        self.remoteAddress = remoteAddress
        self.app = app
        self.pid = pid
        self.executable = executable
        self.deviceId = deviceId
    }

    public static let unknown = ClientInfo()
}

public struct HTTPFlow: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting      // request sent, no response yet
        case receiving    // response arriving
        case complete
        case failed
    }

    public let id: Int
    public var startedAt: Date
    public var client: ClientInfo
    public var scheme: String
    public var host: String
    public var port: Int
    public var method: String
    /// Path and query, as sent.
    public var path: String
    public var httpVersion: String
    public var requestHeaders: [HTTPHeader] = []
    public var requestBody = Data()
    public var requestBodySize = 0
    public var status: Int?
    public var reason: String?
    public var responseHeaders: [HTTPHeader] = []
    public var responseBody = Data()
    public var responseBodySize = 0
    public var state: State = .waiting
    public var error: String?
    /// A CONNECT that Deckhand did not open, or a WebSocket after its upgrade: only the connection is shown.
    public var isTunnel = false
    public var isWebSocket = false
    public var isHTTPS: Bool { scheme == "https" }
    public var requestSentAt: Date?
    public var firstByteAt: Date?
    public var finishedAt: Date?
    public var bodyLimit = 10 * 1024 * 1024

    public init(id: Int, startedAt: Date = Date(), client: ClientInfo = .unknown, scheme: String, host: String, port: Int,
                method: String, path: String, httpVersion: String = "HTTP/1.1") {
        self.id = id
        self.startedAt = startedAt
        self.client = client
        self.scheme = scheme
        self.host = host
        self.port = port
        self.method = method
        self.path = path
        self.httpVersion = httpVersion
    }

    public var isRequestBodyTruncated: Bool { requestBodySize > requestBody.count }
    public var isResponseBodyTruncated: Bool { responseBodySize > responseBody.count }

    public var urlString: String {
        let defaultPort = scheme == "https" ? 443 : 80
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(hostPart)\(port == defaultPort ? "" : ":\(port)")\(path.hasPrefix("/") || path == "*" ? path : "/" + path)"
    }

    public var url: URL? { URL(string: urlString) }

    /// The path without its query string.
    public var pathOnly: String { path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path }

    public var query: String? {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    public var requestContentType: String? { requestHeaders.value(for: "Content-Type") }
    public var responseContentType: String? { responseHeaders.value(for: "Content-Type") }

    /// `application/json` from `application/json; charset=utf-8`.
    public var responseMimeType: String? {
        responseContentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// A short label for the type column: json, html, image, …
    public var kind: String {
        guard let mime = responseMimeType else { return isTunnel ? "tunnel" : "" }
        if mime.contains("json") { return "json" }
        if mime.contains("html") { return "html" }
        if mime.contains("xml") { return "xml" }
        if mime.hasPrefix("image/") { return String(mime.dropFirst("image/".count)) }
        if mime.hasPrefix("text/") { return String(mime.dropFirst("text/".count)) }
        if mime.contains("javascript") { return "js" }
        if mime.contains("css") { return "css" }
        if mime.hasPrefix("video/") || mime.hasPrefix("audio/") { return String(mime.prefix(while: { $0 != "/" })) }
        return mime.split(separator: "/").last.map(String.init) ?? mime
    }

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// `HH:mm:ss.SSS`
    public var timeText: String {
        let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: startedAt)
        return String(format: "%02d:%02d:%02d.%03d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0,
                      (components.nanosecond ?? 0) / 1_000_000)
    }

    public var appName: String { client.app ?? "unknown" }

    public var statusText: String {
        if let status { return "\(status)" }
        return state == .failed ? "failed" : "…"
    }
}
