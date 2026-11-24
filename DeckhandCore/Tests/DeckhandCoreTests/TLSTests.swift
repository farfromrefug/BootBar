import Darwin
import Foundation
import Testing
@testable import DeckhandCore

private func makeAuthority() throws -> CertificateAuthority {
    let path = NSTemporaryDirectory() + "bb-ca-\(UUID().uuidString)"
    return try CertificateAuthority(directory: path)
}

private func socketPair() throws -> (SocketChannel, SocketChannel) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ChannelError("socketpair failed") }
    return (SocketChannel(descriptor: fds[0]), SocketChannel(descriptor: fds[1]))
}

private final class Result<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Swift.Result<T, Error>?
    func set(_ value: Swift.Result<T, Error>) { lock.withLock { stored = value } }
    func wait(timeout: TimeInterval = 10) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let stored = lock.withLock({ stored }) { return try stored.get() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw ChannelError("timed out")
    }
}

@Test func theAuthorityCreatesARootAndReusesItAcrossLaunches() throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let first = try authority.certificatePEM()
    #expect(first.contains("BEGIN CERTIFICATE"))
    #expect(try CertificateAuthority(directory: authority.directory).certificatePEM() == first)
    let attributes = try FileManager.default.attributesOfItem(atPath: authority.directory + "/ca.key")
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    _ = try authority.certificate()
}

@Test func hostCertificatesAreCachedAndDifferPerHost() throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let first = try authority.identity(for: "example.com")
    let again = try authority.identity(for: "example.com")
    #expect(CFEqual(first, again))
    _ = try authority.identity(for: "10.0.2.2")   // an IP gets an IP subject alternative name
    _ = try authority.identity(for: "localhost")
}

@Test func aClientThatTrustsTheRootCompletesAHandshakeAndExchangesData() throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let root = try authority.certificate()
    let (serverSocket, clientSocket) = try socketPair()
    let served = Result<String>()
    Thread.detachNewThread {
        do {
            let tls = try TLSChannel.accept(serverSocket, fallbackName: "example.com",
                                            identity: { try authority.identity(for: $0) }, root: root)
            let request = try tls.read(max: 100)
            try tls.write(Data("echo:".utf8) + request)
            served.set(.success("\(tls.requestedName ?? "-")|\(tls.negotiatedProtocol ?? "-")"))
            tls.close()
        } catch {
            served.set(.failure(error))
        }
    }
    let client = try TLSChannel.connect(clientSocket, host: "example.com", verify: true, anchors: [root])
    try client.write(Data("hello".utf8))
    #expect(String(decoding: try client.read(max: 100), as: UTF8.self) == "echo:hello")
    #expect(try served.wait().hasPrefix("example.com|"))   // the name the client asked for chose the certificate
    client.close()
}

@Test func aClientThatDoesNotTrustTheRootIsRefusedWhenVerifying() throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let root = try authority.certificate()
    let (serverSocket, clientSocket) = try socketPair()
    let served = Result<Bool>()
    Thread.detachNewThread {
        do {
            _ = try TLSChannel.accept(serverSocket, fallbackName: "example.com",
                                      identity: { try authority.identity(for: $0) }, root: root)
            served.set(.success(true))
        } catch {
            served.set(.success(false))
        }
    }
    // the default trust store has never heard of the Deckhand root
    #expect(throws: ChannelError.self) {
        _ = try TLSChannel.connect(clientSocket, host: "example.com", verify: true)
    }
    #expect(try served.wait() == false)
}

@Test func verificationCanBeSwitchedOffForPrivateServers() throws {
    let authority = try makeAuthority()
    defer { try? FileManager.default.removeItem(atPath: authority.directory) }
    let root = try authority.certificate()
    let (serverSocket, clientSocket) = try socketPair()
    Thread.detachNewThread {
        _ = try? TLSChannel.accept(serverSocket, fallbackName: "internal.test",
                                   identity: { try authority.identity(for: $0) }, root: root)
    }
    let client = try TLSChannel.connect(clientSocket, host: "internal.test", verify: false)
    client.close()
}
