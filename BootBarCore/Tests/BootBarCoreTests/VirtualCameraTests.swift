import CoreImage
import Foundation
import Testing
@testable import BootBarCore

private func temporaryDirectory() throws -> String {
    let path = NSTemporaryDirectory() + "bb-camera-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test func dylibListMergesByFileName() {
    let existing = InjectedDylibs.parsing("/a/Other.dylib:/old/sha1/VirtualCamera.dylib:junk:relative.dylib")
    #expect(existing.paths == ["/a/Other.dylib", "/old/sha1/VirtualCamera.dylib"])
    let armed = existing.adding("/new/sha2/VirtualCamera.dylib")
    #expect(armed.paths == ["/a/Other.dylib", "/new/sha2/VirtualCamera.dylib"])
    #expect(armed.removing("/anywhere/VirtualCamera.dylib").paths == ["/a/Other.dylib"])
    #expect(InjectedDylibs.parsing(nil).isEmpty)
    #expect(InjectedDylibs(paths: ["/a.dylib", "/b.dylib"]).environmentValue == "/a.dylib:/b.dylib")
}

@Test func headerLayoutIsLittleEndian() {
    let header = SharedFrameLayout.header(sequence: 0x01020304, timestampMs: 5, width: 640, height: 480,
                                          flags: CameraFlags(fill: true, mirror: true))
    #expect(header.count == 24)
    #expect(Array(header[0..<4]) == [4, 3, 2, 1])
    #expect(Array(header[4..<8]) == [5, 0, 0, 0])
    #expect(Array(header[8..<12]) == [0x80, 0x02, 0, 0])
    #expect(Array(header[12..<16]) == [0xe0, 0x01, 0, 0])
    #expect(Array(header[16..<20]) == [3, 0, 0, 0])
    #expect(Array(header[20..<24]) == [0, 0, 0, 0])
}

@Test func bufferWritesHeaderAndPixelsAndLocksOutASecondWriter() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/SimCam.bgra"
    let buffer = try SharedFrameBuffer(path: path)
    #expect(throws: SharedFrameBufferError.inUse(path: path)) { _ = try SharedFrameBuffer(path: path) }

    buffer.write(width: 2, height: 1, flags: CameraFlags(mirror: true)) { pixels, rowBytes in
        #expect(rowBytes == 8)
        pixels.copyMemory(from: [UInt8]([1, 2, 3, 255, 4, 5, 6, 255]), byteCount: 8)
    }
    buffer.write(width: 2, height: 1, flags: CameraFlags()) { _, _ in }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(data.count == SharedFrameLayout.totalByteCount)
    #expect(Array(data[0..<4]) == [2, 0, 0, 0])   // second frame, sequence 2
    #expect(Array(data[24..<32]) == [1, 2, 3, 255, 4, 5, 6, 255])
    buffer.close()
    _ = try SharedFrameBuffer(path: path)   // lock released
}

@Test func bufferIgnoresFramesLargerThanTheCanvas() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let buffer = try SharedFrameBuffer(path: directory + "/b")
    var painted = false
    buffer.write(width: 1281, height: 10, flags: CameraFlags()) { _, _ in painted = true }
    #expect(!painted)
}

@Test func rendererScalesBigFramesDownToTheCanvas() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/b"
    let buffer = try SharedFrameBuffer(path: path)
    let renderer = FrameRenderer(buffer: buffer)
    renderer.render(CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2560, height: 1280)))
    renderer.render(CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32)))
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(Array(data[8..<12]) == [64, 0, 0, 0])   // the last frame is the small one, not upscaled
    #expect(Array(data[12..<16]) == [32, 0, 0, 0])
    #expect(data[24 + 1] == 255)   // green channel of the first BGRA pixel
    #expect(renderer.takeFrameCount() == 2)
    #expect(renderer.takeFrameCount() == 0)
}

@Test func installCopiesTheLibraryToAHashedFolder() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let source = directory + "/src/VirtualCamera.dylib"
    try FileManager.default.createDirectory(atPath: directory + "/src", withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: URL(fileURLWithPath: source))
    let support = directory + "/support"
    let library = VirtualCameraDylib(supportDirectory: support, candidates: { ["/missing.dylib", source] })
    let installed = try library.install()
    #expect(installed.hasPrefix(support + "/"))
    #expect(installed.hasSuffix("/VirtualCamera.dylib"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: installed)) == Data([1, 2, 3]))
    #expect(try library.install() == installed)

    try Data([9, 9]).write(to: URL(fileURLWithPath: source))
    #expect(try library.install() != installed)   // a new build gets its own path
}

@Test func installFailsWithAHintWhenBaguetteIsMissing() {
    let library = VirtualCameraDylib(supportDirectory: "/nonexistent", candidates: { ["/missing.dylib"] })
    #expect(!library.isAvailable)
    #expect(throws: VirtualCameraDylibError.notFound) { _ = try library.install() }
    #expect(VirtualCameraDylibError.notFound.description.contains("brew install baguette"))
}

/// A stand-in for `xcrun` that keeps DYLD_INSERT_LIBRARIES in a file, so the real read-modify-write runs.
private func makeFakeXcrun(in directory: String, failing: [String] = []) throws -> (path: String, state: String) {
    let state = directory + "/env"
    let script = directory + "/xcrun"
    let failures = failing.map { "[ \"$5\" = \"\($0)\" ] && { echo 'boom' >&2; exit 2; }" }.joined(separator: "\n")
    try """
    #!/bin/sh
    # args: simctl spawn UDID launchctl <verb> VAR [value]
    echo "diagnostic from an injected library" >&2
    \(failures)
    case "$5" in
      getenv) if [ -s "\(state)" ]; then cat "\(state)"; else exit 1; fi ;;
      setenv) printf '%s' "$7" > "\(state)" ;;
      unsetenv) rm -f "\(state)" ;;
    esac
    """.write(toFile: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
    return (script, state)
}

@Test func injectionArmsAndDisarmsWithoutDroppingOtherLibraries() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let fake = try makeFakeXcrun(in: directory)
    try "/x/Motion.dylib".write(toFile: fake.state, atomically: true, encoding: .utf8)
    let injection = SimulatorInjection(xcrun: fake.path, lockDirectory: directory + "/locks")

    try injection.arm("/y/VirtualCamera.dylib", on: "UDID")
    #expect(try String(contentsOfFile: fake.state, encoding: .utf8) == "/x/Motion.dylib:/y/VirtualCamera.dylib")
    #expect(try injection.isArmed("/other/VirtualCamera.dylib", on: "UDID"))

    try injection.disarm("/y/VirtualCamera.dylib", on: "UDID")
    #expect(try String(contentsOfFile: fake.state, encoding: .utf8) == "/x/Motion.dylib")
    try String().write(toFile: fake.state, atomically: true, encoding: .utf8)
    try injection.arm("/y/VirtualCamera.dylib", on: "UDID")
    try injection.disarm("/y/VirtualCamera.dylib", on: "UDID")
    #expect(!FileManager.default.fileExists(atPath: fake.state))   // last one out unsets the variable
}

@Test func injectionRefusesToWriteWhenTheEnvironmentCannotBeRead() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let fake = try makeFakeXcrun(in: directory, failing: ["getenv"])
    let injection = SimulatorInjection(xcrun: fake.path, lockDirectory: directory + "/locks")
    #expect(throws: ShellError.self) { try injection.arm("/y/VirtualCamera.dylib", on: "UDID") }
    #expect(!FileManager.default.fileExists(atPath: fake.state))
}

@Test func videoRotationBecomesAnOrientation() {
    #expect(VideoProducer.orientation(of: .identity) == .up)
    #expect(VideoProducer.orientation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)) == .right)
    #expect(VideoProducer.orientation(of: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)) == .left)
    #expect(VideoProducer.orientation(of: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)) == .down)
}

@Test func imageProducerRejectsFilesThatAreNotImages() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try "not an image".write(toFile: directory + "/a.png", atomically: true, encoding: .utf8)
    await #expect(throws: CameraSourceError.self) {
        try await ImageProducer(path: directory + "/a.png").start { _ in }
    }
}

private struct FakeProducer: CameraFrameProducing {
    func start(onFrame: @escaping @Sendable (CIImage) -> Void) async throws {
        onFrame(CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 4)))
    }
    func stop() {}
}

private let simulator = Device(id: "UDID", name: "iPhone", platform: .ios, osVersion: "iOS 27", state: .running)

@MainActor
private func makeModel(directory: String, failing: [String] = [], library: String? = nil)
    throws -> (VirtualCameraViewModel, state: String, buffer: String) {
    let fake = try makeFakeXcrun(in: directory, failing: failing)
    let dylib = directory + "/VirtualCamera.dylib"
    try Data([7]).write(to: URL(fileURLWithPath: dylib))
    let model = VirtualCameraViewModel(
        dylib: VirtualCameraDylib(supportDirectory: directory + "/support", candidates: { [library ?? dylib] }),
        injection: SimulatorInjection(xcrun: fake.path, lockDirectory: directory + "/locks"),
        bufferPath: directory + "/SimCam.bgra",
        makeProducer: { _ in FakeProducer() },
        listWebcams: { [WebcamInfo(id: "cam", name: "FaceTime", isDefault: true)] })
    return (model, fake.state, directory + "/SimCam.bgra")
}

@MainActor
@Test func startArmsTheSimulatorAndStreamsThenStopCleansUp() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let (model, state, bufferPath) = try makeModel(directory: directory)
    await model.start(on: simulator, source: .image(path: "/x.png"))
    #expect(model.phase == .streaming)
    #expect(model.activeDeviceId == "UDID")
    #expect(model.error == nil)
    #expect(try String(contentsOfFile: state, encoding: .utf8).hasSuffix("/VirtualCamera.dylib"))
    let data = try Data(contentsOf: URL(fileURLWithPath: bufferPath))
    #expect(Array(data[8..<12]) == [8, 0, 0, 0])

    model.flags = CameraFlags(fill: true, mirror: false)
    await model.stop()
    #expect(model.phase == .idle)
    #expect(model.activeDeviceId == nil)
    #expect(!FileManager.default.fileExists(atPath: state))
}

@MainActor
@Test func missingLibraryReportsTheFixAndArmsNothing() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let (model, state, _) = try makeModel(directory: directory, library: "/missing.dylib")
    await model.start(on: simulator, source: .image(path: "/x.png"))
    #expect(model.phase == .idle)
    #expect(model.error?.contains("brew install baguette") == true)
    #expect(!FileManager.default.fileExists(atPath: state))
}

@MainActor
@Test func aSecondCameraIsRefusedWhileOneRuns() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let (model, _, _) = try makeModel(directory: directory)
    await model.start(on: simulator, source: .image(path: "/x.png"))
    await model.start(on: simulator, source: .image(path: "/y.png"))
    #expect(model.error == "A camera is already running")
    #expect(model.phase == .streaming)
    await model.stop()
}

@MainActor
@Test func failedCleanupBlocksTheNextStartUntilStopSucceeds() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let (model, state, _) = try makeModel(directory: directory, failing: ["unsetenv"])
    await model.start(on: simulator, source: .image(path: "/x.png"))
    await model.stop()
    #expect(model.cleanupRequired)
    #expect(model.phase == .idle)
    #expect(model.error?.contains("Stop again") == true)
    await model.start(on: simulator, source: .image(path: "/x.png"))
    #expect(model.phase == .idle)
    #expect(model.error?.contains("Stop it again") == true)
    #expect(FileManager.default.fileExists(atPath: state))
    ArmedCamera.shared.clear()
}

@MainActor
@Test func cameraNeedsARunningSimulator() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let (model, _, _) = try makeModel(directory: directory)
    await model.start(on: Device(id: "A", name: "A", platform: .android, osVersion: "API", state: .running), source: .image(path: "/x"))
    #expect(model.error == "Start an iOS simulator first")
    model.loadWebcams()
    #expect(model.webcams.map(\.name) == ["FaceTime"])
}
