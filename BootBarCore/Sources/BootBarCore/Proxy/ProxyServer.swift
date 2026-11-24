import Darwin
import Foundation
import Security

public struct ProxyOptions: Sendable {
    public var port = 8899
    /// Decrypt HTTPS (with the BootBar certificate). When false every CONNECT is tunnelled untouched.
    public var interceptHTTPS = true
    /// Hosts that are tunnelled untouched even when interception is on: `example.com` and `*.example.com`.
    public var bypassHosts: [String] = []
    /// Check the certificates of the real servers. Turn off for servers with a private CA.
    public var verifyUpstream = true
    /// Largest body kept for display, per request and per response.
    public var bodyLimit = 10 * 1024 * 1024
    /// Replaces the system trust store when checking servers (used by tests).
    public var upstreamAnchors: [SecCertificate]?
    public var maxConnections = 400

    public init() {}

    func bypasses(_ host: String) -> Bool {
        let host = host.lowercased()
        return bypassHosts.contains { pattern in
            let pattern = pattern.lowercased().trimmingCharacters(in: .whitespaces)
            if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
            return host == pattern
        }
    }
}

public enum ProxyError: Error, CustomStringConvertible {
    case bind(String)

    public var description: String {
        switch self {
        case .bind(let message): message
        }
    }
}

/// An HTTP and HTTPS man-in-the-middle proxy that reports every exchange as an `HTTPFlow`.
///
/// One thread serves each client connection with blocking sockets. HTTPS is decrypted by answering CONNECT,
/// presenting a certificate for the requested host made by the `CertificateAuthority`, and speaking TLS to the
/// real server separately. Both sides are forced to HTTP/1.1.
public final class ProxyServer: @unchecked Sendable {
    public let options: ProxyOptions
    private let authority: CertificateAuthority
    private let attribution: any ClientAttributing
    private let onFlow: @Sendable (HTTPFlow) -> Void
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var boundPort = 0
    private var nextFlowId = 1
    private var connections: [ObjectIdentifier: any ByteChannel] = [:]
    private var running = false

    public var port: Int { lock.withLock { boundPort } }

    public init(authority: CertificateAuthority, attribution: any ClientAttributing = LsofAttribution(),
                options: ProxyOptions = ProxyOptions(), onFlow: @escaping @Sendable (HTTPFlow) -> Void) {
        self.authority = authority
        self.attribution = attribution
        self.options = options
        self.onFlow = onFlow
    }

    // MARK: Lifecycle

    public func start() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProxyError.bind("could not create a socket") }
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(options.port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)   // loopback only
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 128) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw ProxyError.bind("port \(options.port) is not available: \(reason)")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        lock.withLock {
            listener = descriptor
            boundPort = Int(UInt16(bigEndian: actual.sin_port))
            running = true
        }
        let thread = Thread { [weak self] in self?.acceptLoop(descriptor) }
        thread.name = "bootbar.proxy.accept"
        thread.start()
    }

    public func stop() {
        let (descriptor, open) = lock.withLock { () -> (Int32, [any ByteChannel]) in
            running = false
            defer {
                listener = -1
                connections = [:]
            }
            return (listener, Array(connections.values))
        }
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        open.forEach { $0.close() }
    }

    private func acceptLoop(_ descriptor: Int32) {
        while lock.withLock({ running }) {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            guard lock.withLock({ connections.count }) < options.maxConnections else {
                Darwin.close(client)
                continue
            }
            let channel = SocketChannel(descriptor: client)
            let thread = Thread { [self] in serve(channel) }
            thread.name = "bootbar.proxy.client"
            thread.start()
        }
    }

    fileprivate func track(_ channel: any ByteChannel) {
        lock.withLock { connections[ObjectIdentifier(channel)] = channel }
    }

    fileprivate func untrack(_ channel: any ByteChannel) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    fileprivate func makeFlowId() -> Int {
        lock.withLock {
            defer { nextFlowId += 1 }
            return nextFlowId
        }
    }

    // MARK: A client connection

    private func serve(_ socket: SocketChannel) {
        track(socket)
        defer {
            socket.close()
            untrack(socket)
        }
        let client = peerPort(of: socket.descriptor).map { attribution.client(forLocalPort: $0) } ?? .unknown
        let session = ProxySession(server: self, socket: socket, client: client)
        session.run()
    }

    private func peerPort(of descriptor: Int32) -> Int? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
        }
        return result == 0 ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    fileprivate func publish(_ flow: HTTPFlow) { onFlow(flow) }
    fileprivate var authorityRef: CertificateAuthority { authority }
}

/// Everything about one client connection: its requests, its pooled upstream connections, its tunnels.
private final class ProxySession {
    let server: ProxyServer
    let socket: SocketChannel
    let client: ClientInfo
    var upstreams: [String: UpstreamConnection] = [:]
    var options: ProxyOptions { server.options }

    struct UpstreamConnection {
        let channel: any ByteChannel
        let reader: ByteReader
    }

    init(server: ProxyServer, socket: SocketChannel, client: ClientInfo) {
        self.server = server
        self.socket = socket
        self.client = client
    }

    func run() {
        defer { upstreams.values.forEach { server.untrack($0.channel); $0.channel.close() } }
        let reader = ByteReader(socket)
        do {
            while let data = try reader.read(through: HTTPProtocol.crlfcrlf) {
                let head = try HTTPProtocol.parseRequestHead(data)
                if head.method == "CONNECT" {
                    handleConnect(head, reader: reader)
                    return
                }
                let keepAlive = exchange(head, reader: reader, client: socket, scheme: "http", fixedAuthority: nil)
                if !keepAlive { return }
            }
        } catch {
            // a client that sent garbage or went away: nothing to show
        }
    }

    // MARK: CONNECT

    private func handleConnect(_ head: HTTPRequestHead, reader: ByteReader) {
        let (host, port) = HTTPProtocol.splitAuthority(head.target, defaultPort: 443)
        var flow = HTTPFlow(id: server.makeFlowId(), client: client, scheme: "https", host: host, port: port,
                            method: "CONNECT", path: "")
        flow.requestHeaders = head.headers
        flow.bodyLimit = options.bodyLimit

        guard options.interceptHTTPS, !options.bypasses(host) else {
            tunnel(host: host, port: port, flow: &flow, reason: options.interceptHTTPS ? "excluded from interception" : nil)
            return
        }
        do {
            try socket.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        } catch { return }
        // only a TLS handshake (0x16) can be decrypted; any other protocol inside CONNECT is tunnelled as is
        guard let first = socket.peekByte() else { return }
        guard first == 0x16 else {
            tunnel(host: host, port: port, flow: &flow, reason: "not TLS", alreadyAccepted: true)
            return
        }
        let tls: TLSChannel
        do {
            let root = try server.authorityRef.certificate()
            tls = try TLSChannel.accept(socket, fallbackName: host, identity: { try server.authorityRef.identity(for: $0) },
                                        root: root)
        } catch {
            flow.state = .failed
            flow.finishedAt = Date()
            flow.error = "TLS handshake with the client failed: \(error)"
            flow.isTunnel = true
            server.publish(flow)
            return
        }
        server.track(tls)
        defer { server.untrack(tls) }
        let tlsReader = ByteReader(tls)
        do {
            while let data = try tlsReader.read(through: HTTPProtocol.crlfcrlf) {
                let request = try HTTPProtocol.parseRequestHead(data)
                if !exchange(request, reader: tlsReader, client: tls, scheme: "https", fixedAuthority: (host, port)) { return }
            }
        } catch {
            // the app closed the connection or sent something that is not HTTP
        }
    }

    /// Relays bytes untouched in both directions, as a flow that only shows the connection.
    private func tunnel(host: String, port: Int, flow: inout HTTPFlow, reason: String?, alreadyAccepted: Bool = false) {
        flow.isTunnel = true
        flow.path = reason.map { "(\($0))" } ?? ""
        let upstream: SocketChannel
        do {
            upstream = try SocketChannel.connect(host: host, port: port)
        } catch {
            if !alreadyAccepted { try? socket.write(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8)) }
            flow.state = .failed
            flow.error = "\(error)"
            flow.finishedAt = Date()
            server.publish(flow)
            return
        }
        server.track(upstream)
        defer {
            server.untrack(upstream)
            upstream.close()
        }
        if !alreadyAccepted {
            guard (try? socket.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))) != nil else { return }
        }
        flow.state = .receiving
        flow.status = 200
        flow.reason = "Connection Established"
        server.publish(flow)
        relayBidirectionally(socket, upstream)
        flow.state = .complete
        flow.finishedAt = Date()
        server.publish(flow)
    }

    // MARK: One request and its response

    /// Returns whether the client connection may carry another request.
    private func exchange(_ head: HTTPRequestHead, reader: ByteReader, client channel: any ByteChannel, scheme: String,
                          fixedAuthority: (String, Int)?) -> Bool {
        var request = head
        let defaultPort = scheme == "https" ? 443 : 80
        let host: String
        let port: Int
        var path = request.target
        if let (fixedHost, fixedPort) = fixedAuthority {
            (host, port) = (fixedHost, fixedPort)
        } else if let url = URL(string: request.target), let urlHost = url.host, request.target.hasPrefix("http") {
            host = urlHost
            port = url.port ?? defaultPort
            path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
            if let raw = request.target.range(of: "://") {
                // keep the query exactly as sent
                let afterScheme = request.target[raw.upperBound...]
                if let slash = afterScheme.firstIndex(of: "/") { path = String(afterScheme[slash...]) }
            }
        } else if let authority = request.headers.value(for: "Host") {
            (host, port) = HTTPProtocol.splitAuthority(authority, defaultPort: defaultPort)
        } else {
            respond(channel, status: 400, text: "BootBar proxy: the request names no host")
            return false
        }

        var flow = HTTPFlow(id: server.makeFlowId(), client: client, scheme: scheme, host: host, port: port,
                            method: request.method, path: path, httpVersion: request.version)
        flow.requestHeaders = request.headers
        flow.bodyLimit = options.bodyLimit
        server.publish(flow)

        // forward in origin form, minus the headers that only concern the proxy
        request.target = path
        request.headers.removeAll { ["proxy-connection", "proxy-authorization"].contains($0.name.lowercased()) }
        let isUpgrade = request.headers.hasToken("upgrade", in: "Connection")

        let upstream: UpstreamConnection
        do {
            upstream = try upstreamConnection(scheme: scheme, host: host, port: port)
        } catch {
            fail(&flow, "\(error)", client: channel, respondWith: 502)
            return false
        }

        var responseStarted = false
        do {
            try upstream.channel.write(HTTPProtocol.serialize(request))
            let requestFraming = HTTPProtocol.framing(forRequest: request)
            let requestCapture = BodyCapture(limit: options.bodyLimit)
            let expectsContinue = request.headers.value(for: "Expect")?.lowercased().contains("100-continue") == true

            var bodySent = false
            if !expectsContinue {
                try BodyRelay.relay(requestFraming, from: reader, to: upstream.channel, capture: requestCapture)
                bodySent = true
                flow.requestSentAt = Date()
            }
            flow.requestBody = requestCapture.data
            flow.requestBodySize = requestCapture.total
            server.publish(flow)

            // interim responses (100 Continue, 103 Early Hints) go to the client untouched
            var response: HTTPResponseHead
            while true {
                guard let data = try upstream.reader.read(through: HTTPProtocol.crlfcrlf) else {
                    throw ChannelError("the server closed the connection without answering")
                }
                response = try HTTPProtocol.parseResponseHead(data)
                guard (100...199).contains(response.status), response.status != 101 else { break }
                try channel.write(data)
                responseStarted = true
                if expectsContinue, !bodySent, response.status == 100 {
                    try BodyRelay.relay(requestFraming, from: reader, to: upstream.channel, capture: requestCapture)
                    bodySent = true
                    flow.requestSentAt = Date()
                    flow.requestBody = requestCapture.data
                    flow.requestBodySize = requestCapture.total
                }
            }
            if expectsContinue, !bodySent { flow.requestSentAt = Date() }   // the server answered without wanting the body

            flow.status = response.status
            flow.reason = response.reason
            flow.responseHeaders = response.headers
            flow.firstByteAt = Date()
            flow.state = .receiving
            server.publish(flow)

            try channel.write(HTTPProtocol.serialize(response))
            responseStarted = true

            if response.status == 101 && isUpgrade {
                flow.isWebSocket = response.headers.value(for: "Upgrade")?.lowercased() == "websocket"
                flow.state = .complete
                flow.finishedAt = Date()
                server.publish(flow)
                relayBidirectionally(channel, upstream.channel, clientReader: reader, upstreamReader: upstream.reader)
                dropUpstream(scheme: scheme, host: host, port: port)
                return false
            }

            let framing = HTTPProtocol.framing(forResponse: response, requestMethod: request.method)
            let responseCapture = BodyCapture(limit: options.bodyLimit)
            try BodyRelay.relay(framing, from: upstream.reader, to: channel, capture: responseCapture)
            flow.responseBody = responseCapture.data
            flow.responseBodySize = responseCapture.total
            flow.state = .complete
            flow.finishedAt = Date()
            server.publish(flow)

            let upstreamReusable = HTTPProtocol.keepsAlive(version: response.version, headers: response.headers) && framing != .untilClose
            if !upstreamReusable { dropUpstream(scheme: scheme, host: host, port: port) }
            return upstreamReusable && HTTPProtocol.keepsAlive(version: request.version, headers: request.headers)
        } catch {
            dropUpstream(scheme: scheme, host: host, port: port)
            fail(&flow, "\(error)", client: channel, respondWith: responseStarted ? nil : 502)
            return false
        }
    }

    private func fail(_ flow: inout HTTPFlow, _ message: String, client channel: any ByteChannel, respondWith status: Int?) {
        flow.state = .failed
        flow.error = message
        flow.finishedAt = Date()
        server.publish(flow)
        if let status { respond(channel, status: status, text: "BootBar proxy: \(message)") }
    }

    private func respond(_ channel: any ByteChannel, status: Int, text: String) {
        let reason = status == 502 ? "Bad Gateway" : "Bad Request"
        let body = Data(text.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
        try? channel.write(Data(head.utf8) + body)
    }

    // MARK: Upstream

    private func upstreamConnection(scheme: String, host: String, port: Int) throws -> UpstreamConnection {
        let key = "\(scheme)://\(host):\(port)"
        if let pooled = upstreams[key] {
            if pooled.channel.isUsable { return pooled }
            dropUpstream(scheme: scheme, host: host, port: port)
        }
        let socket = try SocketChannel.connect(host: host, port: port)
        let channel: any ByteChannel = scheme == "https"
            ? try TLSChannel.connect(socket, host: host, verify: options.verifyUpstream, anchors: options.upstreamAnchors)
            : socket
        server.track(channel)
        let connection = UpstreamConnection(channel: channel, reader: ByteReader(channel))
        upstreams[key] = connection
        return connection
    }

    private func dropUpstream(scheme: String, host: String, port: Int) {
        if let connection = upstreams.removeValue(forKey: "\(scheme)://\(host):\(port)") {
            server.untrack(connection.channel)
            connection.channel.close()
        }
    }
}

/// Copies bytes both ways until either side closes. Anything a reader already buffered goes first.
private func relayBidirectionally(_ first: any ByteChannel, _ second: any ByteChannel,
                                  clientReader: ByteReader? = nil, upstreamReader: ByteReader? = nil) {
    func pump(from source: any ByteChannel, reader: ByteReader?, to destination: any ByteChannel) {
        do {
            while true {
                let chunk = try reader?.readSome(max: 32 * 1024) ?? source.read(max: 32 * 1024)
                if chunk.isEmpty { break }
                try destination.write(chunk)
            }
        } catch {}
        // closing both ends wakes the thread pumping the other direction
        source.close()
        destination.close()
    }
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        pump(from: second, reader: upstreamReader, to: first)
        done.signal()
    }
    thread.start()
    pump(from: first, reader: clientReader, to: second)
    done.wait()
}
