import Foundation

public struct HTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [HTTPHeader]
}

public struct HTTPResponseHead: Equatable, Sendable {
    public var version: String
    public var status: Int
    public var reason: String
    public var headers: [HTTPHeader]
}

public enum HTTPParseError: Error, Equatable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let reason): "malformed HTTP message: \(reason)"
        }
    }
}

public enum BodyFraming: Equatable, Sendable {
    case none
    case length(Int)
    case chunked
    case untilClose
}

public enum HTTPProtocol {
    static let crlfcrlf = Data("\r\n\r\n".utf8)

    /// Splits a head into its start line and headers. Accepts bare LF line ends, as some clients send.
    static func lines(of head: Data) -> [String] {
        String(decoding: head, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func parseHeaders(_ lines: ArraySlice<String>) throws -> [HTTPHeader] {
        var headers: [HTTPHeader] = []
        for line in lines where !line.isEmpty {
            if line.first == " " || line.first == "\t", let last = headers.popLast() {
                // an obsolete folded continuation line
                headers.append(HTTPHeader(last.name, last.value + " " + line.trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformed("header without a colon: \(line.prefix(60))") }
            headers.append(HTTPHeader(String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                                      String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        return headers
    }

    public static func parseRequestHead(_ data: Data) throws -> HTTPRequestHead {
        let lines = lines(of: data)
        guard let start = lines.first else { throw HTTPParseError.malformed("empty request") }
        let parts = start.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { throw HTTPParseError.malformed("request line: \(start.prefix(80))") }
        return HTTPRequestHead(method: parts[0].uppercased(), target: parts[1], version: parts.count == 3 ? parts[2] : "HTTP/1.0",
                               headers: try parseHeaders(lines.dropFirst()))
    }

    public static func parseResponseHead(_ data: Data) throws -> HTTPResponseHead {
        let lines = lines(of: data)
        guard let start = lines.first else { throw HTTPParseError.malformed("empty response") }
        let parts = start.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw HTTPParseError.malformed("status line: \(start.prefix(80))")
        }
        return HTTPResponseHead(version: parts[0], status: status, reason: parts.count == 3 ? parts[2] : "",
                                headers: try parseHeaders(lines.dropFirst()))
    }

    public static func serialize(_ head: HTTPRequestHead) -> Data {
        var text = "\(head.method) \(head.target) \(head.version)\r\n"
        for header in head.headers { text += "\(header.name): \(header.value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    public static func serialize(_ head: HTTPResponseHead) -> Data {
        var text = "\(head.version) \(head.status) \(head.reason)\r\n"
        for header in head.headers { text += "\(header.name): \(header.value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    public static func framing(forRequest head: HTTPRequestHead) -> BodyFraming {
        if head.headers.hasToken("chunked", in: "Transfer-Encoding") { return .chunked }
        if let length = head.headers.value(for: "Content-Length").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), length > 0 {
            return .length(length)
        }
        return .none
    }

    public static func framing(forResponse head: HTTPResponseHead, requestMethod: String) -> BodyFraming {
        if requestMethod == "HEAD" || (100...199).contains(head.status) || head.status == 204 || head.status == 304 { return .none }
        if requestMethod == "CONNECT", (200...299).contains(head.status) { return .none }
        if head.headers.hasToken("chunked", in: "Transfer-Encoding") { return .chunked }
        if let length = head.headers.value(for: "Content-Length").flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            return length > 0 ? .length(length) : .none
        }
        return .untilClose
    }

    /// Whether the connection can carry another request after this exchange.
    public static func keepsAlive(version: String, headers: [HTTPHeader]) -> Bool {
        if headers.hasToken("close", in: "Connection") { return false }
        if version == "HTTP/1.0" { return headers.hasToken("keep-alive", in: "Connection") }
        return true
    }

    /// Splits a `host`, `host:port` or `[::1]:port` authority.
    public static func splitAuthority(_ authority: String, defaultPort: Int) -> (host: String, port: Int) {
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            let host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        if let colon = authority.lastIndex(of: ":"), authority.filter({ $0 == ":" }).count == 1 {
            return (String(authority[..<colon]), Int(authority[authority.index(after: colon)...]) ?? defaultPort)
        }
        return (authority, defaultPort)
    }
}

/// Collects the body that passes through, up to a limit, while still counting every byte.
public final class BodyCapture: @unchecked Sendable {
    public private(set) var data = Data()
    public private(set) var total = 0
    private let limit: Int

    public init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        total += chunk.count
        if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
    }
}

public enum BodyRelay {
    /// Copies a message body from `reader` to `writer` unchanged and records the decoded content in `capture`.
    /// `writer` is nil when the body is only read (a response the client will never see).
    public static func relay(_ framing: BodyFraming, from reader: ByteReader, to writer: (any ByteChannel)?,
                             capture: BodyCapture) throws {
        switch framing {
        case .none:
            return
        case .length(let length):
            var remaining = length
            while remaining > 0 {
                let chunk = try reader.readSome(max: min(remaining, 64 * 1024))
                if chunk.isEmpty { throw ChannelError("connection closed before the body ended") }
                try writer?.write(chunk)
                capture.append(chunk)
                remaining -= chunk.count
            }
        case .untilClose:
            while true {
                let chunk = try reader.readSome(max: 64 * 1024)
                if chunk.isEmpty { return }
                try writer?.write(chunk)
                capture.append(chunk)
            }
        case .chunked:
            while true {
                guard let sizeLine = try reader.readLine() else { throw ChannelError("connection closed inside a chunked body") }
                try writer?.write(sizeLine)
                let sizeText = String(decoding: sizeLine, as: UTF8.self)
                    .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                guard let size = Int(sizeText, radix: 16) else { throw HTTPParseError.malformed("chunk size \(sizeText.prefix(20))") }
                if size == 0 {
                    // trailers, then the blank line that ends the message
                    while let line = try reader.readLine() {
                        try writer?.write(line)
                        if line == Data("\r\n".utf8) || line == Data("\n".utf8) { break }
                    }
                    return
                }
                let chunk = try reader.read(exactly: size)
                guard chunk.count == size else { throw ChannelError("connection closed inside a chunk") }
                try writer?.write(chunk)
                capture.append(chunk)
                if let end = try reader.readLine() { try writer?.write(end) }
            }
        }
    }
}
