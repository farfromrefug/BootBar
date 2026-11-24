import Foundation

private struct SimctlDeviceList: Decodable {
    let devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
}

public enum SimctlParser {
    public static func parseDevices(json: String) throws -> [Device] {
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: Data(json.utf8))
        return list.devices
            .filter { $0.key.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS") }
            .flatMap { runtime, devices in
                devices.filter(\.isAvailable).map { device(from: $0, runtime: runtime) }
            }
            .sorted { $0.name < $1.name }
    }

    public static func hasBootedDevices(json: String) throws -> Bool {
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: Data(json.utf8))
        return list.devices.values.contains { !$0.isEmpty }
    }

    private static func device(from raw: SimctlDevice, runtime: String) -> Device {
        Device(id: raw.udid, name: raw.name, platform: .ios,
               osVersion: osVersion(fromRuntime: runtime), state: state(from: raw.state))
    }

    private static func osVersion(fromRuntime runtime: String) -> String {
        let raw = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        let parts = raw.split(separator: "-")
        guard let name = parts.first else { return raw }
        return "\(name) " + parts.dropFirst().joined(separator: ".")
    }

    private static func state(from raw: String) -> DeviceState {
        switch raw {
        case "Booted": .running
        case "Booting": .booting
        default: .stopped
        }
    }
}

public struct SimulatorDeviceType: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SimulatorRuntime: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let supportedDeviceTypeIds: Set<String>

    public init(id: String, name: String, supportedDeviceTypeIds: Set<String>) {
        self.id = id
        self.name = name
        self.supportedDeviceTypeIds = supportedDeviceTypeIds
    }
}

private struct SimctlDeviceTypeList: Decodable {
    struct Entry: Decodable {
        let identifier: String
        let name: String
        let productFamily: String
    }
    let devicetypes: [Entry]
}

private struct SimctlRuntimeList: Decodable {
    struct Entry: Decodable {
        struct SupportedType: Decodable { let identifier: String }
        let identifier: String
        let name: String
        let isAvailable: Bool
        let supportedDeviceTypes: [SupportedType]
    }
    let runtimes: [Entry]
}

extension SimctlParser {
    private static let creatableFamilies: Set<String> = ["iPhone", "iPad"]

    public static func parseDeviceTypes(json: String) throws -> [SimulatorDeviceType] {
        try JSONDecoder().decode(SimctlDeviceTypeList.self, from: Data(json.utf8)).devicetypes
            .filter { creatableFamilies.contains($0.productFamily) }
            .map { SimulatorDeviceType(id: $0.identifier, name: $0.name) }
    }

    public static func parseRuntimes(json: String) throws -> [SimulatorRuntime] {
        try JSONDecoder().decode(SimctlRuntimeList.self, from: Data(json.utf8)).runtimes
            .filter { $0.isAvailable && $0.identifier.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS") }
            .map { SimulatorRuntime(id: $0.identifier, name: $0.name,
                                    supportedDeviceTypeIds: Set($0.supportedDeviceTypes.map(\.identifier))) }
            .sorted { $0.name.compare($1.name, options: .numeric) == .orderedDescending }
    }

    public struct AppExecutable: Equatable, Sendable {
        public let bundleId: String
        public let displayName: String
        public let executable: String
        public let isSystem: Bool
    }

    /// Installed apps with the executable name that appears as the process in logs.
    public static func parseAppExecutables(_ output: String) -> [AppExecutable] {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil)
                as? [String: [String: Any]] else { return [] }
        return plist.compactMap { identifier, info in
            guard let executable = info["CFBundleExecutable"] as? String else { return nil }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? identifier
            return AppExecutable(bundleId: identifier, displayName: name, executable: executable,
                                 isSystem: (info["ApplicationType"] as? String) == "System")
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Where the Files app keeps "On My iPhone": its file provider group container plus `File Provider Storage`.
    public static func fileProviderStorage(listApps output: String) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil)
                as? [String: [String: Any]] else { return nil }
        for info in plist.values {
            guard let groups = info["GroupContainers"] as? [String: String],
                  let container = groups["group.com.apple.FileProvider.LocalStorage"],
                  let url = URL(string: container) else { continue }
            return url.path + "/File Provider Storage"
        }
        return nil
    }

    /// `simctl listapps` prints an OpenStep property list keyed by bundle identifier.
    public static func parseApps(_ output: String) -> [InstalledApp] {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil)
                as? [String: [String: Any]] else { return [] }
        return plist.map { identifier, info in
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? identifier
            return InstalledApp(id: identifier, name: name, isSystem: (info["ApplicationType"] as? String) == "System")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
