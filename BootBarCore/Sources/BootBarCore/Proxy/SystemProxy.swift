import Foundation

/// The macOS proxy settings, which iOS simulators follow. Turned on while capturing and put back afterwards.
public struct SystemProxy: Sendable {
    public struct ServiceSettings: Codable, Equatable, Sendable {
        public struct Endpoint: Codable, Equatable, Sendable {
            public var enabled: Bool
            public var host: String
            public var port: Int
        }
        public var service: String
        public var web: Endpoint
        public var secureWeb: Endpoint
    }

    private let runner: any ShellRunner
    private let backupPath: String
    private let networksetup = "/usr/sbin/networksetup"

    public init(runner: any ShellRunner = ProcessShellRunner(),
                backupPath: String = NSHomeDirectory() + "/Library/Application Support/BootBar/Proxy/system-proxy-backup.json") {
        self.runner = runner
        self.backupPath = backupPath
    }

    /// Network services that are switched on (Wi-Fi, Ethernet, …).
    public func services() async throws -> [String] {
        let output = try await runner.run(networksetup, ["-listallnetworkservices"])
        return output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") && !$0.isEmpty }
    }

    func settings(of service: String) async throws -> ServiceSettings {
        async let web = endpoint(["-getwebproxy", service])
        async let secure = endpoint(["-getsecurewebproxy", service])
        return ServiceSettings(service: service, web: try await web, secureWeb: try await secure)
    }

    private func endpoint(_ arguments: [String]) async throws -> ServiceSettings.Endpoint {
        Self.parseEndpoint(try await runner.run(networksetup, arguments))
    }

    static func parseEndpoint(_ output: String) -> ServiceSettings.Endpoint {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return ServiceSettings.Endpoint(enabled: values["Enabled"] == "Yes", host: values["Server"] ?? "",
                                        port: Int(values["Port"] ?? "") ?? 0)
    }

    /// True while a backup from a run that has not restored yet exists.
    public var hasPendingBackup: Bool { FileManager.default.fileExists(atPath: backupPath) }

    /// Points the web and secure web proxy of every active service at `127.0.0.1:port`, remembering what was there.
    public func enable(port: Int) async throws {
        let services = try await services()
        // never overwrite a backup that was not restored: it holds the user's real settings, not ours
        var backup = hasPendingBackup ? loadBackup() : []
        for service in services {
            let current = try await settings(of: service)
            if !backup.contains(where: { $0.service == service }) { backup.append(current) }
        }
        try saveBackup(backup)
        for service in services {
            _ = try await runner.run(networksetup, ["-setwebproxy", service, "127.0.0.1", String(port)])
            _ = try await runner.run(networksetup, ["-setsecurewebproxy", service, "127.0.0.1", String(port)])
        }
    }

    /// Puts the settings from before `enable` back.
    public func restore() async throws {
        let backup = loadBackup()
        for settings in backup {
            for (setter, state, endpoint) in [("-setwebproxy", "-setwebproxystate", settings.web),
                                               ("-setsecurewebproxy", "-setsecurewebproxystate", settings.secureWeb)] {
                if endpoint.enabled, !endpoint.host.isEmpty {
                    _ = try? await runner.run(networksetup, [setter, settings.service, endpoint.host, String(endpoint.port)])
                } else {
                    _ = try? await runner.run(networksetup, [state, settings.service, "off"])
                }
            }
        }
        try? FileManager.default.removeItem(atPath: backupPath)
    }

    /// Synchronous restore for when the app is quitting and no run loop is left to await anything.
    public func restoreNow() {
        let backup = loadBackup()
        for settings in backup {
            for (setter, state, endpoint) in [("-setwebproxy", "-setwebproxystate", settings.web),
                                               ("-setsecurewebproxy", "-setsecurewebproxystate", settings.secureWeb)] {
                let arguments = endpoint.enabled && !endpoint.host.isEmpty
                    ? [setter, settings.service, endpoint.host, String(endpoint.port)]
                    : [state, settings.service, "off"]
                let process = Process()
                process.executableURL = URL(fileURLWithPath: networksetup)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
        try? FileManager.default.removeItem(atPath: backupPath)
    }

    private func loadBackup() -> [ServiceSettings] {
        guard let data = FileManager.default.contents(atPath: backupPath) else { return [] }
        return (try? JSONDecoder().decode([ServiceSettings].self, from: data)) ?? []
    }

    private func saveBackup(_ backup: [ServiceSettings]) throws {
        try FileManager.default.createDirectory(atPath: (backupPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(backup).write(to: URL(fileURLWithPath: backupPath), options: .atomic)
    }
}
