import Foundation
import Observation

/// Creating, renaming, cloning and deleting virtual devices.
@MainActor
@Observable
public final class DeviceManagementViewModel {
    public private(set) var deviceTypes: [SimulatorDeviceType] = []
    public private(set) var runtimes: [SimulatorRuntime] = []
    public private(set) var deviceDefinitions: [AvdDeviceDefinition] = []
    public private(set) var systemImages: [SystemImage] = []
    public private(set) var isLoading = false
    public private(set) var isWorking = false
    public private(set) var error: String?

    private let runner: any ShellRunner
    private let locateSDK: @Sendable () -> AndroidSDK?

    public init(runner: any ShellRunner = ProcessShellRunner(), locateSDK: @escaping @Sendable () -> AndroidSDK?) {
        self.runner = runner
        self.locateSDK = locateSDK
    }

    public func dismissError() {
        error = nil
    }

    /// Fetches what the "new device" form offers. Called only when that form opens.
    public func loadOptions(for platform: Platform) async {
        isLoading = true
        error = nil
        do {
            switch platform {
            case .ios:
                let manager = SimulatorManagerService(runner: runner)
                async let types = manager.deviceTypes()
                async let runtimes = manager.runtimes()
                (deviceTypes, self.runtimes) = (try await types, try await runtimes)
            case .android:
                let manager = try avdManager()
                systemImages = manager.installedSystemImages()
                deviceDefinitions = try await manager.deviceDefinitions()
            }
        } catch {
            self.error = DeviceToolsViewModel.friendlyMessage(error)
        }
        isLoading = false
    }

    public func definitions(for image: SystemImage) -> [AvdDeviceDefinition] {
        deviceDefinitions.filter { $0.tag == image.formFactorTag }
    }

    public func deviceTypes(for runtime: SimulatorRuntime) -> [SimulatorDeviceType] {
        deviceTypes.filter { runtime.supportedDeviceTypeIds.contains($0.id) }
    }

    public func createSimulator(name: String, deviceType: SimulatorDeviceType, runtime: SimulatorRuntime) async -> Bool {
        await attempt { try await SimulatorManagerService(runner: runner).create(name: name, deviceType: deviceType, runtime: runtime) }
    }

    public func createEmulator(name: String, image: SystemImage, definition: AvdDeviceDefinition,
                               options: AvdHardwareOptions = AvdHardwareOptions()) async -> Bool {
        await attempt { try await avdManager().create(name: name, image: image, deviceId: definition.id, options: options) }
    }

    /// Hardware options stored for an existing emulator, or nil when its config cannot be read.
    public func hardwareOptions(of device: Device) -> AvdHardwareOptions? {
        try? avdManager().configuration(of: device.name)
    }

    public func updateHardware(of device: Device, to options: AvdHardwareOptions) async -> Bool {
        await attempt {
            try requireStopped(device)
            try avdManager().applyConfiguration(options, to: device.name)
        }
    }

    public func rename(_ device: Device, to name: String) async -> Bool {
        await attempt {
            try requireStopped(device)
            switch device.platform {
            case .ios: try await SimulatorManagerService(runner: runner).rename(device.id, to: name)
            case .android: try await avdManager().rename(device.name, to: name)
            }
        }
    }

    public func delete(_ device: Device) async -> Bool {
        await attempt {
            try requireStopped(device)
            switch device.platform {
            case .ios: try await SimulatorManagerService(runner: runner).delete(device.id)
            case .android: try await avdManager().delete(name: device.name)
            }
        }
    }

    public func clone(_ device: Device, name: String) async -> Bool {
        await attempt {
            try requireStopped(device)
            try await SimulatorManagerService(runner: runner).clone(device.id, name: name)
        }
    }

    public func deleteUnavailableSimulators() async -> Bool {
        await attempt { try await SimulatorManagerService(runner: runner).deleteUnavailable() }
    }

    private func attempt(_ work: () async throws -> some Any) async -> Bool {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            _ = try await work()
            return true
        } catch {
            self.error = DeviceToolsViewModel.friendlyMessage(error)
            return false
        }
    }

    private func requireStopped(_ device: Device) throws {
        guard device.state == .stopped else {
            throw ShellError(command: "device", exitCode: 1, stderr: "Stop \(device.name) first")
        }
    }

    private func avdManager() throws -> AvdManagerService {
        guard let sdk = locateSDK() else {
            throw ShellError(command: "android", exitCode: 1, stderr: "Android SDK not found — set path in Settings")
        }
        return AvdManagerService(runner: runner, sdk: sdk)
    }
}
