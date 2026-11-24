import Testing
@testable import BootBarCore

private func makeService(_ options: AndroidLaunchOptions) -> (EmulatorService, MockShellRunner) {
    let runner = MockShellRunner()
    let service = EmulatorService(runner: runner, sdk: AndroidSDK(root: "/sdk"), launchOptions: options,
                                  avdHome: "/avd") { _ in nil }
    return (service, runner)
}

@Test func startAppliesGlobalOptions() async throws {
    let (service, runner) = makeService(AndroidLaunchOptions(muteAudio: true, extraArguments: "-gpu host"))
    try await service.start("Pixel_8")
    #expect(runner.commands == ["detached /sdk/emulator/emulator -avd Pixel_8 -no-audio -gpu host"])
}

@Test func startOverrideUnmutesWhenGloballyMuted() async throws {
    let (service, runner) = makeService(AndroidLaunchOptions(muteAudio: true))
    try await service.start("Pixel_8", muteAudio: false)
    #expect(runner.commands == ["detached /sdk/emulator/emulator -avd Pixel_8"])
}

@Test func startOverrideMutesWhenGloballyUnmuted() async throws {
    let (service, runner) = makeService(AndroidLaunchOptions())
    try await service.start("Pixel_8", muteAudio: true)
    #expect(runner.commands == ["detached /sdk/emulator/emulator -avd Pixel_8 -no-audio"])
}

@Test func wipeKeepsGlobalOptions() async throws {
    let (service, runner) = makeService(AndroidLaunchOptions(muteAudio: true))
    let device = Device(id: "Pixel_8", name: "Pixel_8", platform: .android, osVersion: "API 34", state: .stopped)
    try await service.wipe(device)
    #expect(runner.commands == ["detached /sdk/emulator/emulator -avd Pixel_8 -no-audio -wipe-data"])
}

@MainActor
@Test func startWithAlternateAudioFlipsGlobalMute() async {
    let runner = MockShellRunner()
    let device = Device(id: "Pixel_8", name: "Pixel_8", platform: .android, osVersion: "API 34", state: .stopped)
    runner.responses["/usr/bin/xcrun simctl list devices --json"] = .success(#"{"devices":{}}"#)
    runner.responses["/sdk/emulator/emulator -list-avds"] = .success("")
    runner.responses["/sdk/platform-tools/adb devices"] = .success("List of devices attached\n")

    let unmuted = DeviceListViewModel(runner: runner, launchOptions: { AndroidLaunchOptions(muteAudio: false) }) {
        AndroidSDK(root: "/sdk")
    }
    await unmuted.perform(.startWithAlternateAudio, on: device)
    let muted = DeviceListViewModel(runner: runner, launchOptions: { AndroidLaunchOptions(muteAudio: true) }) {
        AndroidSDK(root: "/sdk")
    }
    await muted.perform(.startWithAlternateAudio, on: device)

    let launches = runner.commands.filter { $0.hasPrefix("detached ") }
    #expect(launches == ["detached /sdk/emulator/emulator -avd Pixel_8 -no-audio",
                         "detached /sdk/emulator/emulator -avd Pixel_8"])
}

@MainActor
@Test func plainStartUsesGlobalMute() async {
    let runner = MockShellRunner()
    let device = Device(id: "Pixel_8", name: "Pixel_8", platform: .android, osVersion: "API 34", state: .stopped)
    runner.responses["/usr/bin/xcrun simctl list devices --json"] = .success(#"{"devices":{}}"#)
    runner.responses["/sdk/emulator/emulator -list-avds"] = .success("")
    runner.responses["/sdk/platform-tools/adb devices"] = .success("List of devices attached\n")
    let vm = DeviceListViewModel(runner: runner, launchOptions: { AndroidLaunchOptions(muteAudio: true) }) {
        AndroidSDK(root: "/sdk")
    }
    await vm.perform(.start, on: device)
    #expect(runner.commands.contains("detached /sdk/emulator/emulator -avd Pixel_8 -no-audio"))
}

@MainActor
@Test func startHeadlessLaunchesTheEmulatorWithoutAWindow() async {
    let runner = MockShellRunner()
    let device = Device(id: "Pixel_8", name: "Pixel_8", platform: .android, osVersion: "API 34", state: .stopped)
    runner.responses["/usr/bin/xcrun simctl list devices --json"] = .success(#"{"devices":{}}"#)
    runner.responses["/sdk/emulator/emulator -list-avds"] = .success("")
    runner.responses["/sdk/platform-tools/adb devices"] = .success("List of devices attached\n")
    let model = DeviceListViewModel(runner: runner, launchOptions: { AndroidLaunchOptions(muteAudio: true) }) { AndroidSDK(root: "/sdk") }
    await model.perform(.startHeadless, on: device)
    #expect(runner.commands.filter { $0.hasPrefix("detached ") } == ["detached /sdk/emulator/emulator -avd Pixel_8 -no-audio -no-window"])
}
