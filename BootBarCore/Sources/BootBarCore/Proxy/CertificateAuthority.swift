import Foundation
import Security

public enum CertificateError: Error, CustomStringConvertible {
    case openssl(String)
    case identity(String)

    public var description: String {
        switch self {
        case .openssl(let message): "openssl failed: \(message)"
        case .identity(let message): "Could not create a certificate: \(message)"
        }
    }
}

/// The root certificate BootBar signs intercepted HTTPS connections with, and the per-host certificates under it.
///
/// Certificates are made with the `openssl` that ships with macOS: Security has no API to create or sign
/// them. A host certificate takes a few milliseconds, so they are made on demand and kept for the session.
public final class CertificateAuthority: @unchecked Sendable {
    public let directory: String
    private let lock = NSLock()
    private var identities: [String: SecIdentity] = [:]
    private let openssl: String
    private static let p12Password = "bootbar"

    public var certificatePath: String { directory + "/ca.pem" }
    private var keyPath: String { directory + "/ca.key" }
    private var leafKeyPath: String { directory + "/leaf.key" }

    public static var defaultDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/BootBar/Proxy/CA"
    }

    public init(directory: String = CertificateAuthority.defaultDirectory, openssl: String = "/usr/bin/openssl") throws {
        self.directory = directory
        self.openssl = openssl
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: certificatePath) || !FileManager.default.fileExists(atPath: keyPath) {
            try createRoot()
        }
        if !FileManager.default.fileExists(atPath: leafKeyPath) {
            _ = try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", leafKeyPath])
        }
    }

    public func certificatePEM() throws -> String {
        try String(contentsOfFile: certificatePath, encoding: .utf8)
    }

    public func certificate() throws -> SecCertificate {
        let pem = try certificatePEM()
        let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64), let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw CertificateError.identity("the root certificate is unreadable")
        }
        return certificate
    }

    /// The leaf certificate (with its key) that presents itself as `host`, followed by the root in the chain.
    public func identity(for host: String) throws -> SecIdentity {
        if let cached = lock.withLock({ identities[host] }) { return cached }
        let created = try makeIdentity(for: host)
        lock.withLock { identities[host] = created }
        return created
    }

    // MARK: Creation

    private func createRoot() throws {
        _ = try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", keyPath])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
        let name = "Deckhand Proxy CA (\(ProcessInfo.processInfo.hostName.prefix(30)))"
        let config = """
        [req]
        distinguished_name=dn
        x509_extensions=v3_ca
        prompt=no
        [dn]
        CN=\(name)
        O=BootBar
        [v3_ca]
        basicConstraints=critical,CA:TRUE,pathlen:0
        keyUsage=critical,keyCertSign,cRLSign
        subjectKeyIdentifier=hash
        """
        let configPath = directory + "/ca.cnf"
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: configPath) }
        _ = try run(["req", "-x509", "-new", "-key", keyPath, "-sha256", "-days", "3650", "-config", configPath,
                     "-out", certificatePath])
    }

    private func makeIdentity(for host: String) throws -> SecIdentity {
        let work = directory + "/work-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        let isIP = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
        let names = isIP ? "IP:\(host)" : "DNS:\(host)"
        let extensions = """
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature
        extendedKeyUsage=serverAuth
        subjectAltName=\(names)
        authorityKeyIdentifier=keyid
        subjectKeyIdentifier=hash
        """
        try extensions.write(toFile: work + "/leaf.cnf", atomically: true, encoding: .utf8)
        let subject = "/CN=" + String(host.prefix(60)).replacingOccurrences(of: "/", with: "_")
        let serial = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        // one year: Apple's TLS stack refuses leaf certificates that live much longer
        _ = try run(["req", "-new", "-key", leafKeyPath, "-subj", subject, "-out", work + "/leaf.csr"])
        _ = try run(["x509", "-req", "-in", work + "/leaf.csr", "-CA", certificatePath, "-CAkey", keyPath,
                     "-set_serial", "0x" + serial, "-sha256", "-days", "365", "-extfile", work + "/leaf.cnf",
                     "-out", work + "/leaf.pem"])
        _ = try run(["pkcs12", "-export", "-inkey", leafKeyPath, "-in", work + "/leaf.pem", "-certfile", certificatePath,
                     "-name", "BootBar", "-passout", "pass:" + Self.p12Password, "-out", work + "/leaf.p12"])

        let data = try Data(contentsOf: URL(fileURLWithPath: work + "/leaf.p12"))
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: Self.p12Password,
                                                      kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw CertificateError.identity("importing the certificate for \(host) failed (\(status))")
        }
        return identity as! SecIdentity   // swiftlint:disable:this force_cast
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = arguments
        // one pipe for both streams: nothing here needs them apart, and no helper thread has to compete for a worker
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CertificateError.openssl(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
