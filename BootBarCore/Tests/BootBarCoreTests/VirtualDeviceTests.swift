import Foundation
import Testing
@testable import BootBarCore

private let definitionsFixture = """
Available devices definitions:
id: 0 or "wearos_small_round"
    Name: Wear OS Small Round
    OEM : Google
    Tag : android-wear
---------
id: 50 or "pixel_8"
    Name: Pixel 8
    OEM : Google
---------
id: 60 or "pixel_tablet"
    Name: Pixel Tablet
    OEM : Google
"""

@Test func parsesDeviceDefinitions() {
    let definitions = AvdManagerParser.parseDeviceDefinitions(definitionsFixture)
    #expect(definitions.map(\.id) == ["wearos_small_round", "pixel_8", "pixel_tablet"])
    #expect(definitions.map(\.name) == ["Wear OS Small Round", "Pixel 8", "Pixel Tablet"])
    #expect(definitions.map(\.tag) == ["android-wear", nil, nil])
}

@Test func systemImageBuildsPackageIdAndTitle() {
    let image = SystemImage(apiLevel: "36.1", variant: "google_apis_playstore", abi: "arm64-v8a")
    #expect(image.packageId == "system-images;android-36.1;google_apis_playstore;arm64-v8a")
    #expect(image.title == "API 36.1 · Google Play")
    #expect(image.formFactorTag == nil)
    #expect(SystemImage(apiLevel: "34", variant: "android-wear", abi: "arm64-v8a").formFactorTag == "android-wear")
}

private func makeService(java: String? = "/jdk", tree: [String: [String]] = [:],
                         executables: Set<String> = ["/sdk/cmdline-tools/latest/bin/avdmanager"]) -> (AvdManagerService, MockShellRunner) {
    let runner = MockShellRunner()
    runner.responses["/usr/libexec/java_home"] = java.map { .success($0 + "\n") } ?? .failure(
        ShellError(command: "java_home", exitCode: 1, stderr: ""))
    let service = AvdManagerService(
        runner: runner, sdk: AndroidSDK(root: "/sdk"),
        java: JavaLocator(runner: runner, environment: [:], isExecutable: { _ in false }),
        isExecutable: { executables.contains($0) },
        listDirectory: { tree[$0] ?? [] })
    return (service, runner)
}

@Test func listsInstalledImagesNewestFirst() {
    let (service, _) = makeService(tree: [
        "/sdk/system-images": ["android-34", "android-36.1"],
        "/sdk/system-images/android-34": ["google_apis"],
        "/sdk/system-images/android-36.1": ["google_apis_playstore"],
        "/sdk/system-images/android-34/google_apis": ["arm64-v8a"],
        "/sdk/system-images/android-36.1/google_apis_playstore": ["arm64-v8a"]
    ])
    #expect(service.installedSystemImages().map(\.packageId) == [
        "system-images;android-36.1;google_apis_playstore;arm64-v8a",
        "system-images;android-34;google_apis;arm64-v8a"
    ])
}

@Test func createRunsAvdManagerWithJavaHome() async throws {
    let (service, runner) = makeService()
    let image = SystemImage(apiLevel: "36.1", variant: "google_apis_playstore", abi: "arm64-v8a")
    try await service.create(name: "Test_1", image: image, deviceId: "pixel_8")
    #expect(runner.commands.last == "/usr/bin/env JAVA_HOME=/jdk /sdk/cmdline-tools/latest/bin/avdmanager create avd -n Test_1 -k system-images;android-36.1;google_apis_playstore;arm64-v8a -d pixel_8")
}

@Test func avdManagerRunsDirectlyWithoutJava() async throws {
    let (service, runner) = makeService(java: nil)
    try await service.delete(name: "Test_1")
    #expect(runner.commands.last == "/sdk/cmdline-tools/latest/bin/avdmanager delete avd -n Test_1")
}

@Test func renameUsesMove() async throws {
    let (service, runner) = makeService(java: nil)
    try await service.rename("A", to: "B")
    #expect(runner.commands.last == "/sdk/cmdline-tools/latest/bin/avdmanager move avd -n A -r B")
}

@Test func createRejectsBadNameWithoutRunning() async {
    let (service, runner) = makeService()
    let image = SystemImage(apiLevel: "35", variant: "google_apis", abi: "arm64-v8a")
    await #expect(throws: ShellError.self) {
        try await service.create(name: "bad name!", image: image, deviceId: "pixel_8")
    }
    #expect(runner.commands.isEmpty)
}

@Test func missingCommandLineToolsExplainsHowToFix() async {
    let (service, _) = makeService(executables: [])
    do {
        _ = try await service.deviceDefinitions()
        Issue.record("expected failure")
    } catch let error as ShellError {
        #expect(error.stderr.contains("command-line tools"))
    } catch {
        Issue.record("wrong error \(error)")
    }
}

@Test func findsVersionedCommandLineTools() async throws {
    let (service, runner) = makeService(
        java: nil, tree: ["/sdk/cmdline-tools": ["11.0", "19.0"]],
        executables: ["/sdk/cmdline-tools/19.0/bin/avdmanager"])
    try await service.delete(name: "A")
    #expect(runner.commands.last == "/sdk/cmdline-tools/19.0/bin/avdmanager delete avd -n A")
}

@Test func javaLocatorPrefersAndroidStudioRuntime() async {
    let runner = MockShellRunner()
    let studio = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    let locator = JavaLocator(runner: runner, environment: [:], isExecutable: { $0 == studio + "/bin/java" })
    #expect(await locator.locate() == studio)
    #expect(runner.commands.isEmpty)
}

private let deviceTypesJSON = """
{"devicetypes":[
{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16","name":"iPhone 16","productFamily":"iPhone"},
{"identifier":"com.apple.CoreSimulator.SimDeviceType.Apple-Watch","name":"Watch","productFamily":"Apple Watch"},
{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro","name":"iPad Pro","productFamily":"iPad"}]}
"""

private let runtimesJSON = """
{"runtimes":[
{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-6","name":"iOS 18.6","isAvailable":true,"supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16"}]},
{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","name":"iOS 27.0","isAvailable":true,"supportedDeviceTypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro"}]},
{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-17-0","name":"iOS 17.0","isAvailable":false,"supportedDeviceTypes":[]},
{"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-11-0","name":"watchOS 11.0","isAvailable":true,"supportedDeviceTypes":[]}]}
"""

@Test func parsesOnlyPhonesAndTablets() throws {
    #expect(try SimctlParser.parseDeviceTypes(json: deviceTypesJSON).map(\.name) == ["iPhone 16", "iPad Pro"])
}

@Test func parsesAvailableIOSRuntimesNewestFirst() throws {
    let runtimes = try SimctlParser.parseRuntimes(json: runtimesJSON)
    #expect(runtimes.map(\.name) == ["iOS 27.0", "iOS 18.6"])
}

@Test func simulatorManagerCommands() async throws {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl create My com.apple.CoreSimulator.SimDeviceType.iPhone-16 com.apple.CoreSimulator.SimRuntime.iOS-18-6"] = .success("NEW-UDID\n")
    let manager = SimulatorManagerService(runner: runner)
    let type = SimulatorDeviceType(id: "com.apple.CoreSimulator.SimDeviceType.iPhone-16", name: "iPhone 16")
    let runtime = SimulatorRuntime(id: "com.apple.CoreSimulator.SimRuntime.iOS-18-6", name: "iOS 18.6", supportedDeviceTypeIds: [])
    #expect(try await manager.create(name: "My", deviceType: type, runtime: runtime) == "NEW-UDID")
    try await manager.rename("U", to: "R")
    try await manager.clone("U", name: "C")
    try await manager.delete("U")
    try await manager.deleteUnavailable()
    #expect(runner.commands.dropFirst() == [
        "/usr/bin/xcrun simctl rename U R", "/usr/bin/xcrun simctl clone U C",
        "/usr/bin/xcrun simctl delete U", "/usr/bin/xcrun simctl delete unavailable"])
}

@MainActor
@Test func managementRefusesToDeleteRunningDevice() async {
    let runner = MockShellRunner()
    let vm = DeviceManagementViewModel(runner: runner) { AndroidSDK(root: "/sdk") }
    let running = Device(id: "A", name: "A", platform: .android, osVersion: "API 35", state: .running, serial: "emulator-5554")
    #expect(await vm.delete(running) == false)
    #expect(vm.error == "Stop A first")
    #expect(runner.commands.isEmpty)
}

@MainActor
@Test func managementLoadsIOSOptionsOnDemand() async {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl list devicetypes --json"] = .success(deviceTypesJSON)
    runner.responses["/usr/bin/xcrun simctl list runtimes --json"] = .success(runtimesJSON)
    let vm = DeviceManagementViewModel(runner: runner) { nil }
    #expect(runner.commands.isEmpty)
    await vm.loadOptions(for: .ios)
    #expect(vm.deviceTypes.count == 2)
    let ipad = vm.runtimes.first { $0.name == "iOS 27.0" }
    #expect(ipad.map { vm.deviceTypes(for: $0).map(\.name) } == ["iPad Pro"])
}

@MainActor
@Test func managementDeleteIOSDevice() async {
    let runner = MockShellRunner()
    let vm = DeviceManagementViewModel(runner: runner) { nil }
    let device = Device(id: "UDID", name: "iPhone", platform: .ios, osVersion: "iOS 18", state: .stopped)
    #expect(await vm.delete(device))
    #expect(runner.commands == ["/usr/bin/xcrun simctl delete UDID"])
}

@MainActor
@Test func managementReportsMissingSDK() async {
    let vm = DeviceManagementViewModel(runner: MockShellRunner()) { nil }
    let image = SystemImage(apiLevel: "35", variant: "google_apis", abi: "arm64-v8a")
    #expect(await vm.createEmulator(name: "X", image: image,
                                    definition: AvdDeviceDefinition(id: "pixel_8", name: "Pixel 8", tag: nil)) == false)
    #expect(vm.error?.contains("Android SDK not found") == true)
}
