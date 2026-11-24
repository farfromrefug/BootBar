import Foundation
import Security

// SecureTransport is deprecated but is the one TLS API that can serve and speak TLS over a plain blocking socket
// that already carried a CONNECT; Network.framework cannot upgrade an established connection.

private func sslRead(_ connection: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let channel = Unmanaged<SocketChannel>.fromOpaque(connection).takeUnretainedValue()
    let wanted = length.pointee
    var total = 0
    while total < wanted {
        let count = Darwin.read(channel.descriptor, data + total, wanted - total)
        if count > 0 {
            total += count
        } else if count == 0 {
            length.pointee = total
            return errSSLClosedGraceful
        } else if errno == EINTR {
            continue
        } else {
            length.pointee = total
            return errno == ECONNRESET ? errSSLClosedAbort : OSStatus(errSecIO)
        }
    }
    length.pointee = total
    return noErr
}

private func sslWrite(_ connection: SSLConnectionRef, _ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let channel = Unmanaged<SocketChannel>.fromOpaque(connection).takeUnretainedValue()
    let wanted = length.pointee
    var total = 0
    while total < wanted {
        let count = Darwin.write(channel.descriptor, data + total, wanted - total)
        if count > 0 {
            total += count
        } else if count < 0, errno == EINTR {
            continue
        } else {
            length.pointee = total
            return OSStatus(errSecIO)
        }
    }
    length.pointee = total
    return noErr
}

/// A TLS session on a socket, as a server (towards the app being inspected) or a client (towards the real server).
public final class TLSChannel: ByteChannel, @unchecked Sendable {
    private let socket: SocketChannel
    private let context: SSLContext
    private let lock = NSLock()
    private var closed = false

    /// The server name the client asked for, when it sent one.
    public private(set) var requestedName: String?
    /// The protocol the handshake agreed on, if any.
    public private(set) var negotiatedProtocol: String?

    private init(socket: SocketChannel, side: SSLProtocolSide) throws {
        guard let context = SSLCreateContext(nil, side, .streamType) else { throw ChannelError("could not create a TLS context") }
        self.socket = socket
        self.context = context
        var status = SSLSetIOFuncs(context, sslRead, sslWrite)
        status = status == noErr ? SSLSetConnection(context, Unmanaged.passUnretained(socket).toOpaque()) : status
        status = status == noErr ? SSLSetProtocolVersionMin(context, .tlsProtocol12) : status
        status = status == noErr ? SSLSetALPNProtocols(context, ["http/1.1"] as CFArray) : status
        guard status == noErr else { throw ChannelError("TLS setup failed (\(status))") }
    }

    /// Answers the client's handshake with a certificate chosen by `identity` from the name it asked for
    /// (or `fallbackName` when it sent none).
    public static func accept(_ socket: SocketChannel, fallbackName: String,
                              identity: (String) throws -> SecIdentity, root: SecCertificate) throws -> TLSChannel {
        let channel = try TLSChannel(socket: socket, side: .serverSide)
        do { return try channel.acceptHandshake(fallbackName: fallbackName, identity: identity, root: root) } catch {
            channel.close()   // a failed handshake must not leave the peer waiting
            throw error
        }
    }

    private func acceptHandshake(fallbackName: String, identity: (String) throws -> SecIdentity,
                                 root: SecCertificate) throws -> TLSChannel {
        let channel = self
        var status = SSLSetSessionOption(channel.context, .breakOnClientHello, true)
        guard status == noErr else { throw ChannelError("TLS setup failed (\(status))") }
        status = SSLHandshake(channel.context)
        if status == errSSLClientHelloReceived {
            var length = 0
            SSLCopyRequestedPeerNameLength(channel.context, &length)
            var name = [CChar](repeating: 0, count: length + 1)
            if length > 0, SSLCopyRequestedPeerName(channel.context, &name, &length) == noErr {
                channel.requestedName = String(cString: name)
            }
            let host = channel.requestedName ?? fallbackName
            let certificates = [try identity(host), root] as CFArray
            status = SSLSetCertificate(channel.context, certificates)
            if status == noErr { status = SSLHandshake(channel.context) }
        }
        guard status == noErr else { throw ChannelError(Self.describe(status)) }
        channel.negotiatedProtocol = channel.alpn()
        return channel
    }

    /// Starts a handshake with the real server and checks its certificate with the system's trust store
    /// (or against `anchors` when given), unless `verify` is false.
    public static func connect(_ socket: SocketChannel, host: String, verify: Bool,
                               anchors: [SecCertificate]? = nil) throws -> TLSChannel {
        let channel = try TLSChannel(socket: socket, side: .clientSide)
        do { return try channel.connectHandshake(host: host, verify: verify, anchors: anchors) } catch {
            channel.close()
            throw error
        }
    }

    private func connectHandshake(host: String, verify: Bool, anchors: [SecCertificate]?) throws -> TLSChannel {
        let channel = self
        var status = SSLSetPeerDomainName(channel.context, host, host.utf8.count)
        if status == noErr { status = SSLSetSessionOption(channel.context, .breakOnServerAuth, true) }
        guard status == noErr else { throw ChannelError("TLS setup failed (\(status))") }
        status = SSLHandshake(channel.context)
        if status == errSSLPeerAuthCompleted {
            if verify { try channel.verifyPeer(host: host, anchors: anchors) }
            status = SSLHandshake(channel.context)
        }
        guard status == noErr else { throw ChannelError(Self.describe(status)) }
        channel.negotiatedProtocol = channel.alpn()
        return channel
    }

    private func verifyPeer(host: String, anchors: [SecCertificate]?) throws {
        var trust: SecTrust?
        guard SSLCopyPeerTrust(context, &trust) == noErr, let trust else { throw ChannelError("no server certificate") }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        if let anchors {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            let reason = (error as Error?)?.localizedDescription ?? "not trusted"
            throw ChannelError("certificate of \(host) is not trusted: \(reason)")
        }
    }

    private func alpn() -> String? {
        var protocols: Unmanaged<CFArray>?
        guard SSLCopyALPNProtocols(context, &protocols) == noErr, let protocols else { return nil }
        return (protocols.takeRetainedValue() as? [String])?.first
    }

    public func read(max: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        var processed = 0
        let status = SSLRead(context, &buffer, max, &processed)
        switch status {
        case noErr, errSSLWouldBlock:
            return Data(buffer.prefix(processed))
        case errSSLClosedGraceful, errSSLClosedNoNotify, errSSLClosedAbort:
            return processed > 0 ? Data(buffer.prefix(processed)) : Data()
        default:
            if lock.withLock({ closed }) { return Data() }
            throw ChannelError(Self.describe(status))
        }
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                var processed = 0
                let status = SSLWrite(context, raw.baseAddress! + offset, raw.count - offset, &processed)
                if status != noErr && status != errSSLWouldBlock { throw ChannelError(Self.describe(status)) }
                offset += processed
            }
        }
    }

    public var isUsable: Bool { !lock.withLock { closed } && socket.isUsable }

    public func close() {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        SSLClose(context)
        socket.close()
    }

    static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSSLClosedAbort, errSSLClosedNoNotify, errSSLClosedGraceful:
            "the connection was closed during the TLS handshake (the client probably does not trust the Deckhand certificate)"
        case errSSLPeerBadCert, errSSLPeerUnknownCA, errSSLPeerCertUnknown, errSSLPeerCertExpired, errSSLPeerCertRevoked,
             errSSLPeerUnsupportedCert, -9808:
            "the client rejected the certificate (install the Deckhand root certificate on the device)"
        default:
            (SecCopyErrorMessageString(status, nil) as String?) ?? "TLS error \(status)"
        }
    }
}
