import Foundation

public enum DeviceCtlParser {
    private struct Root: Decodable {
        struct Result: Decodable { let devices: [Entry] }
        let result: Result
    }

    private struct Entry: Decodable {
        struct Connection: Decodable { let pairingState: String? }
        struct Hardware: Decodable {
            let reality: String?
            let udid: String?
            let marketingName: String?
            let platform: String?
        }
        struct State: Decodable { let name: String? }
        struct Version: Decodable { let stringValue: String? }
        struct Software: Decodable { let osVersionNumber: Version? }
        struct Properties: Decodable {
            let connection: Connection?
            let hardware: Hardware?
            let software: Software?
            let state: State?
        }
        let identifier: String
        let properties: Properties?
    }

    /// Physical iPhones and iPads from `devicectl list devices`. Simulators are skipped.
    public static func parseDevices(json: String) throws -> [Device] {
        try JSONDecoder().decode(Root.self, from: Data(json.utf8)).result.devices.compactMap { entry in
            guard let hardware = entry.properties?.hardware, hardware.reality == "physical",
                  hardware.platform == "iOS" || hardware.platform == "iPadOS" else { return nil }
            let paired = entry.properties?.connection?.pairingState == "paired"
            let name = entry.properties?.state?.name ?? hardware.marketingName ?? "iOS device"
            let version = entry.properties?.software?.osVersionNumber?.stringValue
            return Device(id: hardware.udid ?? entry.identifier, name: name, platform: .ios,
                          osVersion: version.map { "iOS \($0)" } ?? "iOS", state: paired ? .running : .unavailable,
                          isPhysical: true,
                          statusNote: paired ? nil : "Not paired — trust this computer on the device")
        }
        .sorted { $0.name < $1.name }
    }

    private struct AppsRoot: Decodable {
        struct Result: Decodable {
            struct App: Decodable {
                let bundleIdentifier: String
                let name: String?
                let defaultApp: Bool?
                let hidden: Bool?
            }
            let apps: [App]
        }
        let result: Result
    }

    public static func parseApps(json: String) throws -> [InstalledApp] {
        try JSONDecoder().decode(AppsRoot.self, from: Data(json.utf8)).result.apps
            .map { InstalledApp(id: $0.bundleIdentifier, name: $0.name ?? $0.bundleIdentifier,
                                isSystem: ($0.defaultApp ?? false) || ($0.hidden ?? false)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public struct PhysicalDeviceService: Sendable {
    private let runner: any ShellRunner

    public init(runner: any ShellRunner) {
        self.runner = runner
    }

    public func listAndroid(sdk: AndroidSDK) async throws -> [Device] {
        let entries = AvdParser.parsePhysicalDevices(try await runner.run(sdk.adbPath, ["devices", "-l"]))
        return await withTaskGroup(of: (Int, Device).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask { (index, await device(for: entry, sdk: sdk)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
                .sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func listIOS() async throws -> [Device] {
        try DeviceCtlParser.parseDevices(json: try await runner.run(
            "/usr/bin/xcrun",
            ["devicectl", "list", "devices", "--timeout", "15", "-j", "-", "--omit-deprecated-fields-in-json"]))
    }

    private func device(for entry: AvdParser.PhysicalAndroidDevice, sdk: AndroidSDK) async -> Device {
        let name = entry.model ?? entry.serial
        switch entry.state {
        case "device":
            let release = try? await runner.run(sdk.adbPath, ["-s", entry.serial, "shell", "getprop", "ro.build.version.release"])
            let version = release?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return Device(id: entry.serial, name: name, platform: .android,
                          osVersion: version.map { "Android \($0)" } ?? "Android", state: .running,
                          serial: entry.serial, isPhysical: true)
        case "unauthorized":
            return Device(id: entry.serial, name: name, platform: .android, osVersion: "Android", state: .unavailable,
                          serial: entry.serial, isPhysical: true,
                          statusNote: "Unauthorized — accept the USB debugging prompt on the device")
        default:
            return Device(id: entry.serial, name: name, platform: .android, osVersion: "Android", state: .unavailable,
                          serial: entry.serial, isPhysical: true, statusNote: "Offline — reconnect the device")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
