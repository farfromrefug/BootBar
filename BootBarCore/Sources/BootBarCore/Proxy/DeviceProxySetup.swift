import CryptoKit
import Foundation

/// What was done on a device to make its traffic visible, so the panel can show a checklist.
public struct DeviceProxyState: Equatable, Sendable {
    public var certificateInstalled = false
    public var proxyConfigured = false
    /// What the user still has to do by hand, when something could not be automated.
    public var note: String?

    public init(certificateInstalled: Bool = false, proxyConfigured: Bool = false, note: String? = nil) {
        self.certificateInstalled = certificateInstalled
        self.proxyConfigured = proxyConfigured
        self.note = note
    }
}

public enum DeviceProxySetupError: Error, CustomStringConvertible {
    case unsupported(String)

    public var description: String {
        switch self {
        case .unsupported(let reason): reason
        }
    }
}

/// The steps that make a device send its traffic through BootBar: trusting the BootBar certificate and pointing the
/// device at the proxy. Simulators follow the macOS proxy (see `SystemProxy`); Android needs its own setting.
public struct DeviceProxySetup: Sendable {
    private let runner: any ShellRunner
    private let sdk: AndroidSDK?
    private let authority: CertificateAuthority
    private let statePath: String
    /// The small VPN app that points an Android device at the proxy; without it the global proxy setting is used.
    private let helperAPK: String?
    public static let helperPackage = "com.bootbar.helper"

    public init(runner: any ShellRunner = ProcessShellRunner(), sdk: AndroidSDK?, authority: CertificateAuthority,
                helperAPK: String? = nil,
                statePath: String = NSHomeDirectory() + "/Library/Application Support/BootBar/Proxy/installed-certificates.json") {
        self.helperAPK = helperAPK
        self.runner = runner
        self.sdk = sdk
        self.authority = authority
        self.statePath = statePath
    }

    // MARK: Certificate

    /// Identifies this root, so a regenerated one counts as not installed.
    public func fingerprint() throws -> String {
        let pem = try authority.certificatePEM()
        let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64) else { throw DeviceProxySetupError.unsupported("unreadable certificate") }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public func isCertificateInstalled(on device: Device) -> Bool {
        guard let fingerprint = try? fingerprint() else { return false }
        return loadState()[device.id] == fingerprint
    }

    /// Makes the device trust BootBar's certificate. Returns a note when part of it has to be finished by hand.
    @discardableResult
    public func installCertificate(on device: Device) async throws -> String? {
        let note: String?
        switch (device.platform, device.isPhysical) {
        case (.ios, false):
            _ = try await runner.run("/usr/bin/xcrun", ["simctl", "keychain", device.id, "add-root-cert", authority.certificatePath])
            note = nil
        case (.android, _):
            note = try await installAndroidCertificate(device)
        case (.ios, true):
            throw DeviceProxySetupError.unsupported("An iPhone or iPad needs the certificate installed by hand: AirDrop \(authority.certificatePath) to it, install the profile, then trust it in Settings → General → About → Certificate Trust Settings.")
        }
        if note == nil { markInstalled(device) }
        return note
    }

    private func markInstalled(_ device: Device) {
        guard let fingerprint = try? fingerprint() else { return }
        var state = loadState()
        state[device.id] = fingerprint
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    private func loadState() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: statePath) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    // MARK: Android

    private func adb(_ device: Device, _ arguments: [String]) async throws -> String {
        guard let sdk, let serial = device.serial else { throw DeviceProxySetupError.unsupported("Android SDK not found — set path in Settings") }
        return try await runner.run(sdk.adbPath, ["-s", serial] + arguments)
    }

    private func installAndroidCertificate(_ device: Device) async throws -> String? {
        let hash = try await subjectHash()
        let remote = "/data/local/tmp/\(hash).0"
        // a rootable image (an emulator without Play Store) can trust the certificate for every app
        if let rooted = try? await installAsSystemCertificate(device, hash: hash, remote: remote), rooted { return nil }

        _ = try await adb(device, ["push", authority.certificatePath, "/sdcard/Download/BootBar-CA.crt"])
        _ = try? await adb(device, ["shell", "am", "start", "-a", "android.settings.SECURITY_SETTINGS"])
        return "This device cannot be rooted (a Google Play image), so BootBar-CA.crt can only go in the user store: install it in Settings → Security → Encryption & credentials → Install a certificate → CA certificate. Browsers will be decrypted, but most apps ignore the user store and fail with \"Trust anchor for certification path not found\". To decrypt every app, use an emulator with an AOSP or Google APIs image (not Google Play): Set Up then trusts the certificate system-wide. For your own app, add <debug-overrides><trust-anchors><certificates src=\"user\"/></trust-anchors></debug-overrides> to its network security config. Stop Routing gives the other apps their network back."
    }

    private func subjectHash() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-inform", "PEM", "-subject_hash_old", "-noout", "-in", authority.certificatePath]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let hash = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !hash.isEmpty else { throw DeviceProxySetupError.unsupported("could not hash the certificate") }
        return hash
    }

    /// Trusts the certificate system-wide by overlaying the CA directories with a copy that includes it
    /// (the approach HTTP Toolkit uses). Needs `adb root`; the overlay lasts until the device restarts.
    private func installAsSystemCertificate(_ device: Device, hash: String, remote: String) async throws -> Bool {
        guard let sdk, let serial = device.serial else { return false }
        let rootResult = (try? await runner.run(sdk.adbPath, ["-s", serial, "root"])) ?? ""
        guard !rootResult.contains("cannot run as root") else { return false }
        try await Task.sleep(for: .seconds(1))   // adbd restarts as root
        _ = try await adb(device, ["push", authority.certificatePath, remote])
        let script = """
        set -e
        mkdir -p -m 700 /data/local/tmp/bb-ca
        cp /system/etc/security/cacerts/* /data/local/tmp/bb-ca/
        mount -t tmpfs tmpfs /system/etc/security/cacerts
        cp /data/local/tmp/bb-ca/* /system/etc/security/cacerts/
        cp \(remote) /system/etc/security/cacerts/\(hash).0
        chown root:root /system/etc/security/cacerts/*
        chmod 644 /system/etc/security/cacerts/*
        chcon u:object_r:system_file:s0 /system/etc/security/cacerts/*
        if [ -d /apex/com.android.conscrypt/cacerts ]; then
          for pid in 1 $(pidof zygote zygote64); do
            nsenter --mount=/proc/$pid/ns/mnt -- /bin/mount --bind /system/etc/security/cacerts /apex/com.android.conscrypt/cacerts || true
          done
        fi
        """
        _ = try await adb(device, ["shell", script])
        return true
    }

    public func enableAndroidProxy(on device: Device, port: Int) async throws {
        _ = try await adb(device, ["reverse", "tcp:\(port)", "tcp:\(port)"])
        if let helperAPK {
            try await installHelperIfNeeded(device, apk: helperAPK)
            // lets the VPN start without the system's confirmation dialog
            _ = try? await adb(device, ["shell", "appops", "set", Self.helperPackage, "ACTIVATE_VPN", "allow"])
            _ = try await adb(device, helperCommand("start", port: port))
        } else {
            _ = try await adb(device, ["shell", "settings", "put", "global", "http_proxy", "127.0.0.1:\(port)"])
        }
    }

    public func disableAndroidProxy(on device: Device, port: Int) async throws {
        if helperAPK != nil { _ = try? await adb(device, helperCommand("stop", port: port)) }
        _ = try await adb(device, ["shell", "settings", "put", "global", "http_proxy", ":0"])
        _ = try? await adb(device, ["reverse", "--remove", "tcp:\(port)"])
    }

    public func isAndroidProxyEnabled(on device: Device, port: Int) async -> Bool {
        let value = (try? await adb(device, ["shell", "settings", "get", "global", "http_proxy"])) ?? ""
        if value.trimmingCharacters(in: .whitespacesAndNewlines) == "127.0.0.1:\(port)" { return true }
        guard helperAPK != nil else { return false }
        let connectivity = (try? await adb(device, ["shell", "dumpsys", "connectivity"])) ?? ""
        return connectivity.contains("CONNECTED extra: VPN:\(Self.helperPackage)")
    }

    /// Arguments that make the helper app start or stop its VPN.
    public static func helperArguments(_ command: String, port: Int) -> [String] {
        ["shell", "am", "start", "-n", "\(helperPackage)/.MainActivity", "--es", "command", command,
         "--es", "host", "127.0.0.1", "--ei", "port", String(port), "--ez", "quiet", "true"]
    }

    private func helperCommand(_ command: String, port: Int) -> [String] { Self.helperArguments(command, port: port) }

    private func installHelperIfNeeded(_ device: Device, apk: String) async throws {
        let installed = (try? await adb(device, ["shell", "pm", "path", Self.helperPackage])) ?? ""
        if installed.contains("package:") { return }
        _ = try await adb(device, ["install", "-r", "-g", apk])
    }
}
