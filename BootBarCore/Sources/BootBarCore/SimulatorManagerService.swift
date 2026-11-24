import Foundation

public struct SimulatorManagerService: Sendable {
    private let runner: any ShellRunner
    private let xcrun = "/usr/bin/xcrun"

    public init(runner: any ShellRunner) {
        self.runner = runner
    }

    public func deviceTypes() async throws -> [SimulatorDeviceType] {
        try SimctlParser.parseDeviceTypes(json: try await runner.run(xcrun, ["simctl", "list", "devicetypes", "--json"]))
    }

    public func runtimes() async throws -> [SimulatorRuntime] {
        try SimctlParser.parseRuntimes(json: try await runner.run(xcrun, ["simctl", "list", "runtimes", "--json"]))
    }

    /// Returns the new simulator's UDID.
    @discardableResult
    public func create(name: String, deviceType: SimulatorDeviceType, runtime: SimulatorRuntime) async throws -> String {
        try await runner.run(xcrun, ["simctl", "create", name, deviceType.id, runtime.id])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func rename(_ udid: String, to name: String) async throws {
        try await runner.run(xcrun, ["simctl", "rename", udid, name])
    }

    @discardableResult
    public func clone(_ udid: String, name: String) async throws -> String {
        try await runner.run(xcrun, ["simctl", "clone", udid, name])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func delete(_ udid: String) async throws {
        try await runner.run(xcrun, ["simctl", "delete", udid])
    }

    public func deleteUnavailable() async throws {
        try await runner.run(xcrun, ["simctl", "delete", "unavailable"])
    }
}
