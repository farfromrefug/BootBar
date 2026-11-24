import Foundation
import Testing
@testable import BootBarCore

private let adbDevices = """
List of devices attached
1cba1468               device usb:1048576X product:HLTE556N model:HLTE_556N device:HLTE556N transport_id:13
emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:11
R5CT1234               unauthorized usb:1 transport_id:4
192.168.1.5:5555       offline transport_id:5

"""

@Test func parsesPhysicalAndroidDevicesAndSkipsEmulators() {
    let devices = AvdParser.parsePhysicalDevices(adbDevices)
    #expect(devices.map(\.serial) == ["1cba1468", "R5CT1234", "192.168.1.5:5555"])
    #expect(devices.map(\.state) == ["device", "unauthorized", "offline"])
    #expect(devices.first?.model == "HLTE 556N")
    #expect(devices[1].model == nil)
}

@Test func listsAndroidPhysicalDevicesWithStates() async throws {
    let runner = MockShellRunner()
    runner.responses["/sdk/platform-tools/adb devices -l"] = .success(adbDevices)
    runner.responses["/sdk/platform-tools/adb -s 1cba1468 shell getprop ro.build.version.release"] = .success("14\r\n")
    let devices = try await PhysicalDeviceService(runner: runner).listAndroid(sdk: AndroidSDK(root: "/sdk"))
    #expect(devices.map(\.id) == ["1cba1468", "R5CT1234", "192.168.1.5:5555"])
    #expect(devices.map(\.state) == [.running, .unavailable, .unavailable])
    #expect(devices[0].osVersion == "Android 14")
    #expect(devices[0].isPhysical)
    #expect(devices[1].statusNote?.contains("USB debugging") == true)
    #expect(!runner.commands.contains { $0.contains("emulator-5554") })
}

private let devicectlJSON = """
{"result":{"devices":[
{"identifier":"SIM-1","properties":{"hardware":{"reality":"simulated","udid":"SIM-1","platform":"iOS","marketingName":"iPhone 17"},"state":{"name":"iPhone 17"}}},
{"identifier":"CORE-1","properties":{
 "connection":{"pairingState":"paired"},
 "hardware":{"reality":"physical","udid":"0000-UDID","platform":"iOS","marketingName":"iPhone 12"},
 "software":{"osVersionNumber":{"stringValue":"27.0.1"}},
 "state":{"name":"My iPhone"}}},
{"identifier":"CORE-2","properties":{
 "connection":{"pairingState":"unpaired"},
 "hardware":{"reality":"physical","udid":"0000-OTHER","platform":"iOS","marketingName":"iPad"},
 "state":{"name":"Old iPad"}}},
{"identifier":"WATCH","properties":{"hardware":{"reality":"physical","udid":"W","platform":"watchOS"},"state":{"name":"Watch"}}}
]}}
"""

@Test func parsesPhysicalIOSDevicesOnly() throws {
    let devices = try DeviceCtlParser.parseDevices(json: devicectlJSON)
    #expect(devices.map(\.name) == ["My iPhone", "Old iPad"])
    #expect(devices[0].id == "0000-UDID")
    #expect(devices[0].osVersion == "iOS 27.0.1")
    #expect(devices.map(\.state) == [.running, .unavailable])
    #expect(devices.allSatisfy { $0.isPhysical })
}

@Test func parsesDeviceAppList() throws {
    let json = """
    {"result":{"apps":[
     {"bundleIdentifier":"com.b","name":"Beta","defaultApp":false},
     {"bundleIdentifier":"com.apple.mobilesafari","name":"Safari","defaultApp":true},
     {"bundleIdentifier":"com.a","name":"alpha"}]}}
    """
    let apps = try DeviceCtlParser.parseApps(json: json)
    #expect(apps.map(\.id) == ["com.a", "com.b", "com.apple.mobilesafari"])
    #expect(apps.map(\.isSystem) == [false, false, true])
}

private let phone = Device(id: "0000-UDID", name: "My iPhone", platform: .ios, osVersion: "iOS 27", state: .running,
                           isPhysical: true)
private let noNamer = CaptureNamer(now: { Date(timeIntervalSince1970: 0) }, prepareDirectory: { _ in })

@Test func physicalIOSToolsUseDevicectl() async throws {
    let runner = MockShellRunner()
    let tools = PhysicalIOSTools(runner: runner, namer: noNamer, temporaryDirectory: "/tmp")
    let shot = try await tools.screenshot(phone, directory: "/out")
    try await tools.launch(phone, app: "com.example")
    try await tools.uninstall(phone, app: "com.example")
    try await tools.install(phone, source: "/tmp/build.ipa")
    try await tools.stopRecording(phone)
    #expect(runner.commands == [
        "/usr/bin/xcrun devicectl device capture screenshot --device 0000-UDID --destination \(shot)",
        "/usr/bin/xcrun devicectl device process launch --device 0000-UDID --terminate-existing com.example",
        "/usr/bin/xcrun devicectl device uninstall app --device 0000-UDID com.example",
        "/usr/bin/xcrun devicectl device install app --device 0000-UDID /tmp/build.ipa",
        "/usr/bin/pkill -INT -f capture screen-record --device 0000-UDID"])
}

@Test func physicalDevicesLackEmulatorOnlyTools() {
    let android = Device(id: "S", name: "Phone", platform: .android, osVersion: "Android 14", state: .running,
                         serial: "S", isPhysical: true)
    #expect(!DeviceTool.location(latitude: 0, longitude: 0).isSupported(for: android))
    #expect(DeviceTool.rotate.isSupported(for: android))
    #expect(DeviceTool.screenshot.isSupported(for: android))
    #expect(DeviceTool.install("x").isSupported(for: android))
    #expect(!DeviceTool.appearance(dark: true).isSupported(for: phone))
    #expect(DeviceTool.launch(app: "x").isSupported(for: phone))
}

@MainActor
@Test func listModelIncludesPhysicalDevicesWhenEnabled() async {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl list devices --json"] = .success(#"{"devices":{}}"#)
    runner.responses["/sdk/emulator/emulator -list-avds"] = .success("")
    runner.responses["/sdk/platform-tools/adb devices"] = .success("List of devices attached\n")
    runner.responses["/sdk/platform-tools/adb devices -l"] = .success(adbDevices)
    runner.responses["/usr/bin/xcrun devicectl list devices --timeout 15 -j - --omit-deprecated-fields-in-json"] =
        .success(devicectlJSON)
    let vm = DeviceListViewModel(runner: runner, showPhysicalDevices: { true }) { AndroidSDK(root: "/sdk") }
    await vm.refresh()
    #expect(vm.physicalDevices.count == 5)
    #expect(vm.device(id: "0000-UDID")?.name == "My iPhone")
    await vm.refresh()
    #expect(runner.commands.filter { $0.contains("devicectl list") }.count == 1)
}

@MainActor
@Test func listModelSkipsPhysicalDevicesWhenDisabled() async {
    let runner = MockShellRunner()
    let vm = DeviceListViewModel(runner: runner) { AndroidSDK(root: "/sdk") }
    await vm.refresh()
    #expect(vm.physicalDevices.isEmpty)
    #expect(!runner.commands.contains { $0.contains("devicectl") || $0.hasSuffix("devices -l") })
}

@MainActor
@Test func startingPhysicalDeviceFailsClearly() async {
    let vm = DeviceListViewModel(runner: MockShellRunner()) { AndroidSDK(root: "/sdk") }
    await vm.perform(.start, on: phone)
    #expect(vm.rowErrors[phone.id]?.contains("Physical devices") == true)
}
