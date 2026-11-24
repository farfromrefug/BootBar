import Darwin
import Foundation
import Security
import Testing
@testable import BootBarCore

// MARK: Test upstream server

private final class UpstreamServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequestHead, Data) -> (status: Int, headers: [HTTPHeader], body: Data)
    private var listener: Int32 = -1
    private(set) var port = 0
    private let handler: Handler
    private let tls: CertificateAuthority?
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int { lock.withLock { requests } }

    init(tls: CertificateAuthority? = nil, handler: @escaping Handler) {
        self.tls = tls
        self.handler = handler
    }

    func start() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw ChannelError("test server bind failed") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        let descriptor = listener
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread { [self] in serve(SocketChannel(descriptor: client)) }
            }
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func serve(_ socket: SocketChannel) {
        var channel: any ByteChannel = socket
        if let tls {
            guard let root = try? tls.certificate(),
                  let secure = try? TLSChannel.accept(socket, fallbackName: "localhost", identity: { try tls.identity(for: $0) }, root: root)
            else { return }
            channel = secure
        }
        defer { channel.close() }
        let reader = ByteReader(channel)
        while let data = try? reader.read(through: HTTPProtocol.crlfcrlf), let head = try? HTTPProtocol.parseRequestHead(data) {
            let capture = BodyCapture(limit: 1_000_000)
            guard (try? BodyRelay.relay(HTTPProtocol.framing(forRequest: head), from: reader, to: nil, capture: capture)) != nil else { return }
            lock.withLock { requests += 1 }
            let response = handler(head, capture.data)
            var text = "HTTP/1.1 \(response.status) OK\r\n"
            for header in response.headers { text += "\(header.name): \(header.value)\r\n" }
            if response.headers.value(for: "Content-Length") == nil, response.headers.value(for: "Transfer-Encoding") == nil {
                text += "Content-Length: \(response.body.count)\r\n"
            }
            text += "\r\n"
            do { try channel.write(Data(text.utf8) + response.body) } catch { return }
        }
    }
}

// MARK: Helpers

private final class FlowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [Int: HTTPFlow] = [:]

    func record(_ flow: HTTPFlow) { lock.withLock { latest[flow.id] = flow } }
    var flows: [HTTPFlow] { lock.withLock { latest.values.sorted { $0.id < $1.id } } }

    func waitForFlows(_ count: Int, where condition: (HTTPFlow) -> Bool = { $0.state == .complete || $0.state == .failed }) async -> [HTTPFlow] {
        for _ in 0..<100 {
            let current = flows
            if current.count >= count, current.prefix(count).allSatisfy(condition) { return current }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return flows
    }
}

private struct NoAttribution: ClientAttributing {
    func client(forLocalPort port: Int) -> ClientInfo { ClientInfo(app: "TestApp", pid: 1) }
}

private func makeAuthority() throws -> CertificateAuthority {
    try CertificateAuthority(directory: NSTemporaryDirectory() + "bb-proxy-ca-\(UUID().uuidString)")
}

private func session(proxyPort: Int, delegate: URLSessionDelegate? = nil) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [
        "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort
    ]
    configuration.timeoutIntervalForRequest = 10
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

/// Runs the system curl through the proxy: the exact client a developer would point at it.
private func curl(proxyPort: Int, url: String, caFile: String? = nil) async throws -> (exit: Int32, body: String, code: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var arguments = ["-sS", "-m", "10", "-x", "http://127.0.0.1:\(proxyPort)", "-w", "\n%{http_code}", "--noproxy", ""]
    if let caFile { arguments += ["--cacert", caFile] }
    process.arguments = arguments + [url]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    let parts = text.components(separatedBy: "\n")
    return (process.terminationStatus, parts.dropLast().joined(separator: "\n"), parts.last ?? "")
}

private func startProxy(_ authority: CertificateAuthority, options: ProxyOptions = ProxyOptions(),
                         recorder: FlowRecorder) throws -> ProxyServer {
    var options = options
    options.port = 0
    let proxy = ProxyServer(authority: authority, attribution: NoAttribution(), options: options) { recorder.record($0) }
    try proxy.start()
    return proxy
}

private let jsonHandler: UpstreamServer.Handler = { head, body in
    let payload = #"{"path":"\#(head.target)","method":"\#(head.method)","received":\#(body.count)}"#
    return (200, [HTTPHeader("Content-Type", "application/json"), HTTPHeader("X-Test", "yes")], Data(payload.utf8))
}

// MARK: Tests

@Test func plainHTTPIsForwardedAndRecorded() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }

    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(upstream.port)/items?page=2")!)
    request.httpMethod = "POST"
    request.httpBody = Data("hello".utf8)
    request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await session(proxyPort: proxy.port).data(for: request)

    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Test") == "yes")
    #expect(String(decoding: data, as: UTF8.self) == #"{"path":"/items?page=2","method":"POST","received":5}"#)

    let flows = await recorder.waitForFlows(1)
    let flow = try #require(flows.first)
    #expect(flow.state == .complete)
    #expect(flow.method == "POST")
    #expect(flow.scheme == "http")
    #expect(flow.host == "127.0.0.1" && flow.port == upstream.port)
    #expect(flow.path == "/items?page=2")
    #expect(flow.status == 200)
    #expect(flow.requestBody == Data("hello".utf8))
    #expect(flow.responseMimeType == "application/json")
    #expect(String(decoding: flow.responseBody, as: UTF8.self).contains("\"received\":5"))
    #expect(flow.requestHeaders.value(for: "Content-Type") == "text/plain")
    #expect(flow.client.app == "TestApp")
    #expect(flow.duration != nil)
}

@Test func httpsIsDecryptedWithTheBootBarCertificateAndRecorded() async throws {
    let authority = try makeAuthority()
    let upstreamAuthority = try makeAuthority()
    defer {
        try? FileManager.default.removeItem(atPath: authority.directory)
        try? FileManager.default.removeItem(atPath: upstreamAuthority.directory)
    }
    let upstream = UpstreamServer(tls: upstreamAuthority, handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.verifyUpstream = false   // the test server is signed by a private CA
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }

    let result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/secure", caFile: authority.certificatePath)
    #expect(result.exit == 0)
    #expect(result.code == "200")
    #expect(result.body.contains("\"path\":\"/secure\""))

    let flows = await recorder.waitForFlows(1) { $0.state == .complete && !$0.isTunnel }
    let decrypted = try #require(flows.first { $0.method == "GET" })
    #expect(decrypted.scheme == "https")
    #expect(decrypted.host == "localhost")
    #expect(decrypted.path == "/secure")
    #expect(decrypted.status == 200)
    #expect(decrypted.urlString == "https://localhost:\(upstream.port)/secure")
}

@Test func theProxyChecksTheRealServersCertificate() async throws {
    let authority = try makeAuthority()
    let upstreamAuthority = try makeAuthority()
    defer {
        try? FileManager.default.removeItem(atPath: authority.directory)
        try? FileManager.default.removeItem(atPath: upstreamAuthority.directory)
    }
    let upstream = UpstreamServer(tls: upstreamAuthority, handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)   // verifyUpstream stays on
    defer { proxy.stop() }

    let result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/", caFile: authority.certificatePath)
    #expect(result.code == "502")   // the proxy refused the untrusted server
    #expect(result.body.contains("not trusted"))
    let flows = await recorder.waitForFlows(1) { $0.state == .failed }
    #expect(flows.first { $0.state == .failed }?.error?.contains("not trusted") == true)
}

@Test func anAppThatDoesNotTrustTheCertificateProducesAFailedConnectionFlow() async throws {
    let authority = try makeAuthority()
    let upstreamAuthority = try makeAuthority()
    defer {
        try? FileManager.default.removeItem(atPath: authority.directory)
        try? FileManager.default.removeItem(atPath: upstreamAuthority.directory)
    }
    let upstream = UpstreamServer(tls: upstreamAuthority, handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.verifyUpstream = false
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }

    // the default trust store does not know the BootBar root
    let result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/")
    #expect(result.exit != 0)
    let flows = await recorder.waitForFlows(1) { $0.state == .failed }
    let failed = try #require(flows.first)
    #expect(failed.method == "CONNECT")
    #expect(failed.error?.contains("TLS handshake") == true)
}

@Test func keepAliveConnectionsCarryManyRequestsAndEachIsRecorded() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let upstream = UpstreamServer(handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    let client = session(proxyPort: proxy.port)
    for index in 1...3 {
        _ = try await client.data(from: URL(string: "http://127.0.0.1:\(upstream.port)/n\(index)")!)
    }
    let flows = await recorder.waitForFlows(3)
    #expect(flows.map(\.path) == ["/n1", "/n2", "/n3"])
    #expect(upstream.requestCount == 3)
}

@Test func anUnreachableServerBecomesABadGatewayAndAFailedFlow() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    let (data, response) = try await session(proxyPort: proxy.port).data(from: URL(string: "http://127.0.0.1:1/")!)
    #expect((response as? HTTPURLResponse)?.statusCode == 502)
    #expect(String(decoding: data, as: UTF8.self).contains("BootBar proxy"))
    let flows = await recorder.waitForFlows(1)
    #expect(flows.first?.state == .failed)
}

@Test func excludedHostsAreTunnelledWithoutDecryption() async throws {
    let authority = try makeAuthority()
    let upstreamAuthority = try makeAuthority()
    defer {
        try? FileManager.default.removeItem(atPath: authority.directory)
        try? FileManager.default.removeItem(atPath: upstreamAuthority.directory)
    }
    let upstream = UpstreamServer(tls: upstreamAuthority, handler: jsonHandler)
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.bypassHosts = ["localhost"]
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }

    // the app talks to the real server directly, so it trusts the real server's CA
    let result = try await curl(proxyPort: proxy.port, url: "https://localhost:\(upstream.port)/direct", caFile: upstreamAuthority.certificatePath)
    #expect(result.code == "200")
    #expect(result.body.contains("/direct"))
    let flows = await recorder.waitForFlows(1) { $0.isTunnel && $0.state == .complete || $0.state == .failed }
    let tunnel = try #require(flows.first)
    #expect(tunnel.isTunnel)
    #expect(tunnel.method == "CONNECT")
    #expect(tunnel.path.contains("excluded"))
}

@Test func bodiesAreCappedForDisplayButStillRelayedWhole() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let big = Data(repeating: 0x41, count: 300_000)
    let upstream = UpstreamServer { _, _ in (200, [HTTPHeader("Content-Type", "application/octet-stream")], big) }
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    var options = ProxyOptions()
    options.bodyLimit = 1000
    let proxy = try startProxy(authority, options: options, recorder: recorder)
    defer { proxy.stop() }
    let (data, _) = try await session(proxyPort: proxy.port).data(from: URL(string: "http://127.0.0.1:\(upstream.port)/big")!)
    #expect(data.count == 300_000)
    let flow = try #require(await recorder.waitForFlows(1).first)
    #expect(flow.responseBody.count == 1000)
    #expect(flow.responseBodySize == 300_000)
    #expect(flow.isResponseBodyTruncated)
}

@Test func chunkedResponsesAreDecodedForDisplayAndRelayedIntact() async throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let chunked = Data("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
    let upstream = UpstreamServer { _, _ in (200, [HTTPHeader("Transfer-Encoding", "chunked"), HTTPHeader("Content-Type", "text/plain")], chunked) }
    try upstream.start()
    defer { upstream.stop() }
    let recorder = FlowRecorder()
    let proxy = try startProxy(authority, recorder: recorder)
    defer { proxy.stop() }
    let (data, _) = try await session(proxyPort: proxy.port).data(from: URL(string: "http://127.0.0.1:\(upstream.port)/stream")!)
    #expect(String(decoding: data, as: UTF8.self) == "hello world")
    let flow = try #require(await recorder.waitForFlows(1).first)
    #expect(String(decoding: flow.responseBody, as: UTF8.self) == "hello world")
}
