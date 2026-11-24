import Foundation
import Testing
@testable import BootBarCore

@Test func storedIdsRoundTripAndUnknownFallsBackToTerminal() {
    for app in TerminalApp.presets { #expect(TerminalApp(id: app.id) == app) }
    #expect(TerminalApp(id: "nonsense") == .terminal)
    #expect(TerminalApp(id: "custom", customName: "  Hyper ") == .custom("Hyper"))
    #expect(TerminalApp(id: "custom", customName: " ") == .terminal)
}

@Test func commandFileTerminalsOpenTheScriptDirectly() {
    #expect(TerminalApp.terminal.openArguments(script: "/s") == ["-a", "Terminal", "/s"])
    #expect(TerminalApp.iterm.openArguments(script: "/s") == ["-a", "iTerm", "/s"])
    #expect(TerminalApp.custom("Hyper").openArguments(script: "/s") == ["-a", "Hyper", "/s"])
}

@Test func commandLineTerminalsGetAFreshInstanceWithTheScriptAsProgram() {
    #expect(TerminalApp.ghostty.openArguments(script: "/s") == ["-na", "Ghostty", "--args", "-e", "/s"])
    #expect(TerminalApp.kitty.openArguments(script: "/s") == ["-na", "kitty", "--args", "/s"])
    #expect(TerminalApp.wezterm.openArguments(script: "/s") == ["-na", "WezTerm", "--args", "start", "--", "/s"])
    #expect(TerminalApp.alacritty.openArguments(script: "/s") == ["-na", "Alacritty", "--args", "-e", "/s"])
}

@Test func launcherWritesAnExecutableScriptAndOpensItInTheChosenTerminal() async throws {
    let directory = NSTemporaryDirectory() + "bb-term-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let runner = MockShellRunner()
    try await TerminalLauncher.open("adb logcat", in: .ghostty, runner: runner, directory: directory)

    let command = try #require(runner.commands.first)
    #expect(command.hasPrefix("/usr/bin/open -na Ghostty --args -e \(directory)/bootbar-"))
    let script = String(command.split(separator: " ").last!)
    #expect(try String(contentsOfFile: script, encoding: .utf8).hasSuffix("adb logcat\n"))
    #expect(FileManager.default.isExecutableFile(atPath: script))
}

@MainActor
@Test func toolsOpenLogsInTheConfiguredTerminal() async {
    let runner = MockShellRunner()
    let model = DeviceToolsViewModel(runner: runner, terminalApp: { .kitty }, locateSDK: { AndroidSDK(root: "/sdk") })
    let device = Device(id: "Pixel", name: "Pixel", platform: .android, osVersion: "API 36", state: .running, serial: "emulator-5554")
    await model.perform(.logs, on: device)
    #expect(runner.commands.first?.hasPrefix("/usr/bin/open -na kitty --args ") == true)
}
