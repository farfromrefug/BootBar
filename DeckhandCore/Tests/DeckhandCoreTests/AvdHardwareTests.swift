import Foundation
import Testing
@testable import DeckhandCore

private let sampleIni = """
AvdId=Medium_Phone
disk.dataPartition.size=10G
hw.cpu.ncore=4
hw.gpu.mode=host
hw.keyboard=yes
hw.ramSize=2048
showDeviceFrame=yes
vm.heapSize=228
"""

@Test func configEntriesOnlyIncludeSetOptions() {
    #expect(AvdHardwareOptions().configEntries.isEmpty)
    let options = AvdHardwareOptions(ramMB: 4096, cpuCores: 6, internalStorageMB: 8192, gpuMode: .swiftshaderIndirect,
                                     showDeviceFrame: false, coldBootOnly: true)
    let entries = options.configEntries.map { "\($0.key)=\($0.value)" }
    #expect(entries == ["hw.ramSize=4096", "hw.cpu.ncore=6", "disk.dataPartition.size=8192M", "hw.gpu.enabled=yes",
                        "hw.gpu.mode=swiftshader_indirect", "showDeviceFrame=no", "fastboot.forceColdBoot=yes",
                        "fastboot.forceFastBoot=no"])
}

@Test func mergeReplacesInPlaceAndAppendsMissing() {
    let merged = AvdConfigEditor.merge(sampleIni, entries: [("hw.ramSize", "4096"), ("hw.camera.front", "none")])
    let lines = merged.split(separator: "\n").map(String.init)
    #expect(lines.contains("hw.ramSize=4096"))
    #expect(!lines.contains("hw.ramSize=2048"))
    #expect(lines.last == "hw.camera.front=none")
    #expect(lines.count == 9)
    #expect(lines.firstIndex(of: "hw.ramSize=4096") == 5)
    #expect(merged.hasSuffix("\n"))
}

@Test func parseReadsOptionsBack() {
    let options = AvdConfigEditor.parse(sampleIni)
    #expect(options.ramMB == 2048)
    #expect(options.cpuCores == 4)
    #expect(options.internalStorageMB == 10240)
    #expect(options.vmHeapMB == 228)
    #expect(options.gpuMode == .host)
    #expect(options.showDeviceFrame == true)
    #expect(options.hardwareKeyboard == true)
    #expect(options.frontCamera == nil)
}

@Test func sizesParseWithUnits() {
    #expect(AvdConfigEditor.megabytes("2048MB", defaultUnit: "M") == 2048)
    #expect(AvdConfigEditor.megabytes("6442450944", defaultUnit: "B") == 6144)
    #expect(AvdConfigEditor.megabytes("512M", defaultUnit: "B") == 512)
    #expect(AvdConfigEditor.megabytes("", defaultUnit: "M") == nil)
}

private final class FileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String]
    init(_ files: [String: String]) { self.files = files }
    func read(_ path: String) -> String? { lock.withLock { files[path] } }
    func write(_ path: String, _ text: String) { lock.withLock { files[path] = text } }
}

@Test func createAppliesHardwareOptionsAfterAvdManager() async throws {
    let runner = MockShellRunner()
    runner.responses["/usr/libexec/java_home"] = .failure(ShellError(command: "java_home", exitCode: 1, stderr: ""))
    let files = FileBox(["/avd/Test.avd/config.ini": sampleIni])
    let service = AvdManagerService(
        runner: runner, sdk: AndroidSDK(root: "/sdk"),
        java: JavaLocator(runner: runner, environment: [:], isExecutable: { _ in false }),
        avdHome: "/avd", readFile: { files.read($0) }, writeFile: { files.write($0, $1) },
        isExecutable: { $0 == "/sdk/cmdline-tools/latest/bin/avdmanager" }, listDirectory: { _ in [] })
    let image = SystemImage(apiLevel: "36", variant: "google_apis", abi: "arm64-v8a")
    try await service.create(name: "Test", image: image, deviceId: "pixel_8",
                             options: AvdHardwareOptions(ramMB: 4096, sdCardMB: 512, showDeviceFrame: false))
    #expect(runner.commands.last == "/sdk/cmdline-tools/latest/bin/avdmanager create avd -n Test -k system-images;android-36;google_apis;arm64-v8a -d pixel_8 --sdcard 512M")
    let ini = files.read("/avd/Test.avd/config.ini") ?? ""
    #expect(ini.contains("hw.ramSize=4096"))
    #expect(ini.contains("showDeviceFrame=no"))
    #expect(service.configuration(of: "Test")?.ramMB == 4096)
}

@Test func applyConfigurationWithoutOptionsTouchesNothing() throws {
    let runner = MockShellRunner()
    let service = AvdManagerService(runner: runner, sdk: AndroidSDK(root: "/sdk"), avdHome: "/avd",
                                    readFile: { _ in Issue.record("read"); return nil },
                                    writeFile: { _, _ in Issue.record("write") })
    try service.applyConfiguration(AvdHardwareOptions(), to: "Test")
}

@MainActor
@Test func updateHardwareRefusesRunningEmulator() async {
    let vm = DeviceManagementViewModel(runner: MockShellRunner()) { AndroidSDK(root: "/sdk") }
    let running = Device(id: "A", name: "A", platform: .android, osVersion: "API 35", state: .running, serial: "emulator-5554")
    #expect(await vm.updateHardware(of: running, to: AvdHardwareOptions(ramMB: 1024)) == false)
    #expect(vm.error == "Stop A first")
}
