import Darwin
import Foundation
import Security

/// A blocking, bidirectional byte stream: a socket or a TLS session on one.
public protocol ByteChannel: AnyObject, Sendable {
    /// Up to `max` bytes; empty at end of stream.
    func read(max: Int) throws -> Data
    func write(_ data: Data) throws
    /// Ends the connection in both directions and wakes up any blocked reader.
    func close()
    /// False once the peer has gone away, so a pooled connection is not reused after the server closed it.
    var isUsable: Bool { get }
}

public struct ChannelError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A connected TCP socket.
public final class SocketChannel: ByteChannel, @unchecked Sendable {
    public let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    /// Slows this connection down; set for the clients being inspected. What the client sends counts as upload,
    /// what it receives as download.
    var conditions: ConditionsBox?

    public init(descriptor: Int32) {
        self.descriptor = descriptor
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to `host:port`, trying every address the name resolves to.
    public static func connect(host: String, port: Int, timeout: TimeInterval = 15) throws -> SocketChannel {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var results: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &results)
        guard status == 0, let first = results else {
            throw ChannelError("Could not resolve \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(results) }
        var lastError = "no address"
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if descriptor >= 0 {
                var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
                if Darwin.connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    var none = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
                    return SocketChannel(descriptor: descriptor)
                }
                lastError = String(cString: strerror(errno))
                Darwin.close(descriptor)
            }
            current = info.pointee.ai_next
        }
        throw ChannelError("Could not connect to \(host):\(port): \(lastError)")
    }

    public func read(max: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let count = Darwin.read(descriptor, &buffer, max)
            if count > 0 {
                // offline is decided per request, where it can be recorded; writes then fail so open tunnels end
                if let limits = conditions?.value {
                    Thread.sleep(forTimeInterval: NetworkConditions.delay(bytes: count, kbps: limits.upKbps))
                }
                return Data(buffer.prefix(count))
            }
            if count == 0 { return Data() }
            if errno == EINTR { continue }
            if lock.withLock({ closed }) { return Data() }
            throw ChannelError(String(cString: strerror(errno)))
        }
    }

    public func write(_ data: Data) throws {
        guard let conditions else { return try writeNow(data) }
        // in pieces, so a big response takes as long as the connection would need
        var offset = data.startIndex
        while offset < data.endIndex {
            let limits = conditions.value
            if limits.offline { throw ChannelError("offline") }
            let end = limits.downKbps > 0 ? min(offset + 2048, data.endIndex) : data.endIndex
            try writeNow(data[offset..<end])
            Thread.sleep(forTimeInterval: NetworkConditions.delay(bytes: end - offset, kbps: limits.downKbps))
            offset = end
        }
    }

    private func writeNow(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress! + sent, raw.count - sent)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw ChannelError(count == 0 ? "connection closed" : String(cString: strerror(errno)))
                }
            }
        }
    }

    /// The next byte without consuming it, or nil at end of stream. Blocks until one arrives.
    public func peekByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = recv(descriptor, &byte, 1, MSG_PEEK)
            if count == 1 { return byte }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            return nil
        }
    }

    public var isUsable: Bool {
        if lock.withLock({ closed }) { return false }
        var byte: UInt8 = 0
        let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count == 0 { return false }                     // the peer closed it
        if count > 0 { return false }                      // data nobody asked for: the exchange is out of step
        return errno == EAGAIN || errno == EWOULDBLOCK     // idle, as a healthy keep-alive connection is
    }

    public func close() {
        let shouldClose = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard shouldClose else { return }
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    deinit { close() }
}

/// Buffers reads from a channel so HTTP can be parsed line by line and byte-exact.
public final class ByteReader: @unchecked Sendable {
    public let channel: any ByteChannel
    private var buffer = Data()

    public init(_ channel: any ByteChannel) {
        self.channel = channel
    }

    /// Bytes already received but not consumed yet.
    public var buffered: Int { buffer.count }

    /// Everything up to and including `terminator`, or nil at end of stream before it arrived.
    public func read(through terminator: Data, limit: Int = 128 * 1024) throws -> Data? {
        var searchFrom = buffer.startIndex
        while true {
            if let range = buffer.range(of: terminator, in: searchFrom..<buffer.endIndex) {
                let result = buffer[buffer.startIndex..<range.upperBound]
                buffer = Data(buffer[range.upperBound...])
                return Data(result)
            }
            guard buffer.count < limit else { throw ChannelError("header section too large") }
            searchFrom = max(buffer.startIndex, buffer.endIndex - terminator.count + 1)
            let chunk = try channel.read(max: 16 * 1024)
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    /// One line including its line break, or nil at end of stream.
    public func readLine() throws -> Data? {
        try read(through: Data([0x0a]), limit: 64 * 1024)
    }

    /// Up to `max` bytes, from the buffer first. Empty at end of stream.
    public func readSome(max: Int) throws -> Data {
        if !buffer.isEmpty {
            let count = min(max, buffer.count)
            let result = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            return result
        }
        return try channel.read(max: max)
    }

    /// Exactly `count` bytes, or fewer when the stream ends.
    public func read(exactly count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let chunk = try readSome(max: min(count - result.count, 64 * 1024))
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        return result
    }
}
