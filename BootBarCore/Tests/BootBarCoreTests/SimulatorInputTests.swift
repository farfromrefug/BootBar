import Foundation
import Testing
@testable import BootBarCore

/// A stand-in for `baguette`: logs every stdin line and acks it.
private func makeFakeBaguette(in directory: String) throws -> (path: String, log: String) {
    let log = directory + "/input.log"
    let script = directory + "/baguette"
    try """
    #!/bin/sh
    # args: input --udid UDID
    while IFS= read -r line; do
      echo "$line" >> "\(log)"
      echo '{"ok":true}'
    done
    """.write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    return (script, log)
}

private func tempDirectory() throws -> String {
    let path = NSTemporaryDirectory() + "bb-input-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func lines(of path: String, expecting count: Int) async throws -> [String] {
    for _ in 0..<60 {
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let all = text.split(whereSeparator: \.isNewline).map(String.init)
            if all.count >= count { return all }
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    return (try? String(contentsOfFile: path, encoding: .utf8))?.split(whereSeparator: \.isNewline).map(String.init) ?? []
}

@Test func touchesAreEncodedWithEdgeBandsForSystemGestures() throws {
    let session = SimulatorInputSession(executable: "/x", udid: "U", runner: MockShellRunner())
    let interior = String(decoding: session.encode(["type": "touch1-down", "x": 10.0, "y": 20.0, "width": 100.0, "height": 200.0])!, as: UTF8.self)
    #expect(interior == "{\"height\":200,\"type\":\"touch1-down\",\"width\":100,\"x\":10,\"y\":20}\n")
}

@Test func sessionSendsGesturesButtonsAndKeysToTheInputProcess() async throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let fake = try makeFakeBaguette(in: directory)
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl spawn U notifyutil -g com.apple.coredevice.dtuhidd.active"] =
        .success("com.apple.coredevice.dtuhidd.active 0\n")
    let session = SimulatorInputSession(executable: fake.path, udid: "U", runner: runner, settleAfterHeal: .zero)
    try await session.start()
    session.touch(.down, x: 100, y: 2600, width: 1206, height: 2622)   // bottom edge
    session.touch(.move, x: 100, y: 1000, width: 1206, height: 2622)
    session.touch(.up, x: 100, y: 1000, width: 1206, height: 2622)
    session.touch(.down, x: 600, y: 1300, width: 1206, height: 2622)   // interior
    session.touch(.down, x: 600, y: 10, width: 1206, height: 2622)     // top edge
    session.press(.appSwitcher)
    session.key(code: "KeyA", modifiers: ["command"])
    session.type("hi")
    session.paste("héllo")

    let sent = try await lines(of: fake.log, expecting: 9)
    session.stop()
    try #require(sent.count == 9)
    #expect(sent[0].contains("\"edge\":\"bottom\"") && sent[0].contains("\"type\":\"touch1-down\""))
    #expect(sent[1].contains("touch1-move") && !sent[1].contains("edge"))
    #expect(sent[2].contains("touch1-up"))
    #expect(!sent[3].contains("edge"))
    #expect(sent[4].contains("\"edge\":\"top\""))
    #expect(sent[5] == "{\"button\":\"app-switcher\",\"type\":\"button\"}")
    #expect(sent[6] == "{\"code\":\"KeyA\",\"modifiers\":[\"command\"],\"type\":\"key\"}")
    #expect(sent[7] == "{\"text\":\"hi\",\"type\":\"type\"}")
    #expect(sent[8] == "{\"text\":\"héllo\",\"type\":\"paste\"}")
    #expect(!runner.commands.contains { $0.contains(" heal ") })
}

@Test func startReclaimsTheInputSurfaceWhenDeviceHubShadowsIt() async throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let fake = try makeFakeBaguette(in: directory)
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl spawn U notifyutil -g com.apple.coredevice.dtuhidd.active"] =
        .success("com.apple.coredevice.dtuhidd.active 1\n")
    let session = SimulatorInputSession(executable: fake.path, udid: "U", runner: runner, settleAfterHeal: .zero)
    #expect(await session.isInputShadowed())
    try await session.start()
    session.stop()
    #expect(runner.commands.contains("\(fake.path) heal --udid U"))
}

@Test func unknownShadowStateIsNotHealed() async {
    let runner = MockShellRunner()
    runner.responses["/usr/bin/xcrun simctl spawn U notifyutil -g com.apple.coredevice.dtuhidd.active"] =
        .failure(ShellError(command: "x", exitCode: 1, stderr: "not booted"))
    #expect(!(await SimulatorInputSession(executable: "/x", udid: "U", runner: runner).isInputShadowed()))
}

@Test func locatesBaguetteInHomebrew() {
    #expect(SimulatorInputSession.locate(exists: { $0 == "/opt/homebrew/bin/baguette" }) == "/opt/homebrew/bin/baguette")
    #expect(SimulatorInputSession.locate(exists: { _ in false }) == nil)
}

@Test func keyMapNamesSpecialKeysAndShortcuts() {
    #expect(SimulatorKeyMap.special[36] == "Enter")
    #expect(SimulatorKeyMap.special[51] == "Backspace")
    #expect(SimulatorKeyMap.shortcutCode(for: "a") == "KeyA")
    #expect(SimulatorKeyMap.shortcutCode(for: "1") == nil)
    #expect(SimulatorKeyMap.isTypable("Hello, World 123"))
    #expect(!SimulatorKeyMap.isTypable("é"))
    #expect(!SimulatorKeyMap.isTypable(""))
}
