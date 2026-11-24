import Foundation
import Testing
@testable import DeckhandCore

private func sleeper() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["300"]
    try process.run()
    return process
}

private func waitUntilGone(_ process: Process) async -> Bool {
    for _ in 0..<60 {
        if !process.isRunning { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

private func tempPath() -> String {
    NSTemporaryDirectory() + "bb-children-\(UUID().uuidString)/children.json"
}

@Test func trackedProcessesAreRecordedAndForgottenOnExit() throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    let registry = ChildProcesses(path: path)
    let process = try sleeper()
    registry.track(process)
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(try String(contentsOfFile: path, encoding: .utf8).contains("sleep"))
    process.terminate()
    registry.untrack(process)
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func terminateAllEndsEverythingTheAppStarted() async throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    let registry = ChildProcesses(path: path)
    let first = try sleeper()
    let second = try sleeper()
    registry.track(first)
    registry.track(second)
    registry.terminateAll()
    #expect(await waitUntilGone(first))
    #expect(await waitUntilGone(second))
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func theNextLaunchReapsWhatACrashedRunLeftBehind() async throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    let leftBehind = try sleeper()
    ChildProcesses(path: path).track(leftBehind)   // the "old" run recorded it, then died without cleaning up

    let next = ChildProcesses(path: path)
    #expect(next.reapOrphans() == 1)
    #expect(await waitUntilGone(leftBehind))
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func aReusedPidRunningSomethingElseIsLeftAlone() async throws {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    let bystander = try sleeper()
    defer { bystander.terminate() }
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    // the recorded executable is not what that pid runs now
    try Data(#"[{"pid":\#(bystander.processIdentifier),"executable":"/usr/bin/adb"}]"#.utf8).write(to: URL(fileURLWithPath: path))
    #expect(ChildProcesses(path: path).reapOrphans() == 0)
    try await Task.sleep(for: .milliseconds(150))
    #expect(bystander.isRunning)
}

@Test func theStreamerRegistersItsProcessAndReleasesItWhenCancelled() async throws {
    let task = Task {
        for try await _ in ProcessByteStreamer().stream("/bin/sleep", ["300"]) {}
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(ChildProcesses.shared.trackedCount() >= 1)
    task.cancel()
    try await Task.sleep(for: .milliseconds(300))
    #expect(ChildProcesses.shared.trackedCount() == 0)
}
