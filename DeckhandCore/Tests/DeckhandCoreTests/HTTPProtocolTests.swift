import Compression
import Foundation
import Testing
@testable import DeckhandCore

@Test func parsesRequestAndResponseHeads() throws {
    let request = try HTTPProtocol.parseRequestHead(Data("POST /a?b=1 HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\nX-Folded: one\r\n  two\r\n\r\n".utf8))
    #expect(request.method == "POST" && request.target == "/a?b=1" && request.version == "HTTP/1.1")
    #expect(request.headers.value(for: "host") == "example.com")
    #expect(request.headers.value(for: "X-Folded") == "one two")
    let response = try HTTPProtocol.parseResponseHead(Data("HTTP/1.1 404 Not Found\nContent-Type: text/plain\n\n".utf8))
    #expect(response.status == 404 && response.reason == "Not Found")
    #expect(throws: HTTPParseError.self) { try HTTPProtocol.parseResponseHead(Data("nonsense\r\n\r\n".utf8)) }
    #expect(throws: HTTPParseError.self) { try HTTPProtocol.parseRequestHead(Data("GET /\r\nbad header\r\n\r\n".utf8)) }
}

@Test func serializingKeepsHeaderOrderAndCase() throws {
    let head = HTTPRequestHead(method: "GET", target: "/", version: "HTTP/1.1",
                               headers: [HTTPHeader("Host", "a"), HTTPHeader("X-Custom", "1"), HTTPHeader("accept", "*/*")])
    #expect(String(decoding: HTTPProtocol.serialize(head), as: UTF8.self) == "GET / HTTP/1.1\r\nHost: a\r\nX-Custom: 1\r\naccept: */*\r\n\r\n")
}

@Test func bodyFramingFollowsTheRules() throws {
    func response(_ status: Int, _ headers: [HTTPHeader]) -> HTTPResponseHead {
        HTTPResponseHead(version: "HTTP/1.1", status: status, reason: "", headers: headers)
    }
    #expect(HTTPProtocol.framing(forResponse: response(200, [HTTPHeader("Content-Length", "10")]), requestMethod: "GET") == .length(10))
    #expect(HTTPProtocol.framing(forResponse: response(200, [HTTPHeader("Transfer-Encoding", "gzip, chunked")]), requestMethod: "GET") == .chunked)
    #expect(HTTPProtocol.framing(forResponse: response(200, []), requestMethod: "GET") == .untilClose)
    #expect(HTTPProtocol.framing(forResponse: response(200, [HTTPHeader("Content-Length", "10")]), requestMethod: "HEAD") == .none)
    #expect(HTTPProtocol.framing(forResponse: response(304, []), requestMethod: "GET") == .none)
    #expect(HTTPProtocol.framing(forResponse: response(204, []), requestMethod: "GET") == .none)
    let post = HTTPRequestHead(method: "POST", target: "/", version: "HTTP/1.1", headers: [HTTPHeader("Content-Length", "3")])
    #expect(HTTPProtocol.framing(forRequest: post) == .length(3))
    #expect(HTTPProtocol.framing(forRequest: HTTPRequestHead(method: "GET", target: "/", version: "HTTP/1.1", headers: [])) == .none)
}

@Test func keepAliveDependsOnVersionAndConnectionHeader() {
    #expect(HTTPProtocol.keepsAlive(version: "HTTP/1.1", headers: []))
    #expect(!HTTPProtocol.keepsAlive(version: "HTTP/1.1", headers: [HTTPHeader("Connection", "close")]))
    #expect(!HTTPProtocol.keepsAlive(version: "HTTP/1.0", headers: []))
    #expect(HTTPProtocol.keepsAlive(version: "HTTP/1.0", headers: [HTTPHeader("Connection", "Keep-Alive")]))
}

@Test func authoritiesSplitIntoHostAndPort() {
    #expect(HTTPProtocol.splitAuthority("example.com", defaultPort: 443) == ("example.com", 443))
    #expect(HTTPProtocol.splitAuthority("example.com:8443", defaultPort: 443) == ("example.com", 8443))
    #expect(HTTPProtocol.splitAuthority("[::1]:8080", defaultPort: 80) == ("::1", 8080))
    #expect(HTTPProtocol.splitAuthority("::1", defaultPort: 80) == ("::1", 80))
}

private final class Sink: ByteChannel, @unchecked Sendable {
    var written = Data()
    var isUsable: Bool { true }
    func read(max: Int) throws -> Data { Data() }
    func write(_ data: Data) throws { written.append(data) }
    func close() {}
}

private final class Source: ByteChannel, @unchecked Sendable {
    var data: Data
    init(_ data: Data) { self.data = data }
    var isUsable: Bool { true }
    func read(max: Int) throws -> Data {
        let chunk = data.prefix(max)
        data.removeFirst(chunk.count)
        return Data(chunk)
    }
    func write(_ data: Data) throws {}
    func close() {}
}

@Test func chunkedBodiesAreForwardedVerbatimAndCapturedDecoded() throws {
    let wire = Data("4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\nTrailer: x\r\n\r\nNEXT".utf8)
    let reader = ByteReader(Source(wire))
    let sink = Sink()
    let capture = BodyCapture(limit: 100)
    try BodyRelay.relay(.chunked, from: reader, to: sink, capture: capture)
    #expect(String(decoding: capture.data, as: UTF8.self) == "Wikipedia")
    #expect(String(decoding: sink.written, as: UTF8.self) == "4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\nTrailer: x\r\n\r\n")
    #expect(String(decoding: try reader.read(exactly: 4), as: UTF8.self) == "NEXT")   // the next message is untouched
}

@Test func lengthBodiesStopAtTheirLengthAndTruncatedOnesFail() throws {
    let reader = ByteReader(Source(Data("1234567890".utf8)))
    let capture = BodyCapture(limit: 4)
    try BodyRelay.relay(.length(6), from: reader, to: nil, capture: capture)
    #expect(capture.total == 6 && capture.data.count == 4)
    #expect(throws: ChannelError.self) {
        try BodyRelay.relay(.length(100), from: reader, to: nil, capture: BodyCapture(limit: 10))
    }
}

private func gzip(_ text: String) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    guard (try? process.run()) != nil else { return nil }
    input.fileHandleForWriting.write(Data(text.utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}

@Test func gzipBodiesAreDecoded() throws {
    let compressed = try #require(gzip("hello hello hello hello gzip"))
    #expect(String(decoding: try #require(BodyDecoder.decode(compressed, encoding: "gzip")), as: UTF8.self) == "hello hello hello hello gzip")
    #expect(BodyDecoder.decode(Data("plain".utf8), encoding: nil) == Data("plain".utf8))
    #expect(BodyDecoder.decode(Data("plain".utf8), encoding: "identity") == Data("plain".utf8))
    #expect(BodyDecoder.decode(Data("not gzip at all, really".utf8), encoding: "gzip") == nil)
    #expect(BodyDecoder.decode(Data([1, 2, 3]), encoding: "zstd") == nil)
}

@Test func attributionNamesAppsFromTheirPath() {
    let sim = "/Users/me/Library/Developer/CoreSimulator/Devices/1EB213BB-A1D3-4AF1-A605-811C95037A68/data/Containers/Bundle/Application/X/My App.app/My App"
    let app = LsofAttribution.describe(pid: 5, executable: sim)
    #expect(app.app == "My App")
    #expect(app.deviceId == "1EB213BB-A1D3-4AF1-A605-811C95037A68")
    let extensionPath = "/x/Devices/1EB213BB-A1D3-4AF1-A605-811C95037A68/Applications/Main.app/PlugIns/Share.appex/Share"
    #expect(LsofAttribution.describe(pid: 5, executable: "/Applications/Safari.app/Contents/MacOS/Safari").app == "Safari")
    #expect(LsofAttribution.describe(pid: 5, executable: "/opt/homebrew/bin/curl").app == "curl")
    #expect(LsofAttribution.describe(pid: 5, executable: "/sdk/platform-tools/adb").app == "Android (adb)")
    #expect(LsofAttribution.describe(pid: 5, executable: "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64").app == "Android emulator")
    _ = extensionPath
}

@Test func flowsDescribeThemselves() {
    var flow = HTTPFlow(id: 1, scheme: "https", host: "api.example.com", port: 8443, method: "GET", path: "/v1/items?x=1")
    #expect(flow.urlString == "https://api.example.com:8443/v1/items?x=1")
    #expect(flow.pathOnly == "/v1/items" && flow.query == "x=1")
    flow.responseHeaders = [HTTPHeader("Content-Type", "application/json; charset=utf-8")]
    #expect(flow.responseMimeType == "application/json" && flow.kind == "json")
    flow.responseHeaders = [HTTPHeader("Content-Type", "image/png")]
    #expect(flow.kind == "png")
    #expect(HTTPFlow(id: 2, scheme: "http", host: "a", port: 80, method: "GET", path: "/").urlString == "http://a/")
    #expect(HTTPFlow(id: 3, scheme: "http", host: "::1", port: 80, method: "GET", path: "/").urlString == "http://[::1]/")
}
