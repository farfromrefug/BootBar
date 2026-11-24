import CoreMedia
import Foundation
import Testing
@testable import DeckhandCore

private let sps: [UInt8] = [0x67, 0x42, 0xc0, 0x29, 0x8d, 0x68, 0x09, 0x00, 0xa1, 0xa4, 0x20, 0x20, 0x20, 0x20, 0xf0, 0x88, 0x46, 0xa0]
private let pps: [UInt8] = [0x68, 0xce, 0x01, 0xa8, 0x35, 0xc8]
private let idr: [UInt8] = [0x65, 0xb8, 0x00, 0x04, 0x05, 0x9f, 0xff, 0xff, 0x04, 0x51, 0x40, 0x80]
private let startCode4: [UInt8] = [0, 0, 0, 1]
private let startCode3: [UInt8] = [0, 0, 1]

private func stream(_ units: [[UInt8]]) -> Data {
    Data(units.enumerated().flatMap { ($0.offset % 2 == 0 ? startCode4 : startCode3) + $0.element })
}

@Test func parserSplitsUnitsAndHoldsTheLastOne() {
    var parser = AnnexBParser()
    let units = parser.push(stream([sps, pps, idr]))
    #expect(units == [sps, pps])
    #expect(parser.flush() == idr)
    #expect(parser.flush() == nil)
}

@Test func parserHandlesUnitsSplitAcrossChunks() {
    var parser = AnnexBParser()
    let data = stream([sps, pps, idr, idr])
    var units: [[UInt8]] = []
    for byte in data { units += parser.push(Data([byte])) }
    #expect(units == [sps, pps, idr])
    #expect(parser.flush() == idr)
}

@Test func builderCreatesFramesWithDimensionsFromSps() {
    var builder = H264FrameBuilder()
    #expect(builder.push(sps) == nil)
    #expect(builder.push(pps) == nil)
    let frame = builder.push(idr)
    #expect(frame?.width == 576)
    #expect(frame?.height == 1280)
}

@Test func builderIgnoresSlicesBeforeParameterSets() {
    var builder = H264FrameBuilder()
    #expect(builder.push(idr) == nil)
}

@Test func decoderFlushesTheLastFrameOfAQuietStream() async throws {
    let decoder = H264StreamDecoder(idleAfter: .milliseconds(20))
    #expect(decoder.feed(stream([sps, pps, idr])).isEmpty)
    #expect(decoder.flushIfIdle().isEmpty)
    try await Task.sleep(for: .milliseconds(40))
    #expect(decoder.flushIfIdle().count == 1)
    #expect(decoder.flushIfIdle().isEmpty)
}

@Test func windowSizePrefersOverride() {
    let output = "Physical size: 1080x2400\nOverride size: 720x1600\n"
    #expect(AndroidMirrorSession.parseWindowSize(output) == .init(width: 720, height: 1600))
    #expect(AndroidMirrorSession.parseWindowSize("nothing") == nil)
}

@Test func recordingSizeScalesDownAndAligns() {
    #expect(AndroidMirrorSession.recordingSize(for: .init(width: 1080, height: 2400), maxDimension: 1280)
            == .init(width: 576, height: 1280))
    #expect(AndroidMirrorSession.recordingSize(for: .init(width: 720, height: 1280), maxDimension: 1280)
            == .init(width: 720, height: 1280))
    #expect(AndroidMirrorSession.recordingSize(for: .init(width: 2400, height: 1080), maxDimension: 1280)
            == .init(width: 1280, height: 576))
}

private struct FakeStreamer: ByteStreaming {
    let chunks: [Data]
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Test func sessionDeliversFramesFromTheStream() async throws {
    let runner = MockShellRunner()
    runner.responses["/sdk/platform-tools/adb -s S shell wm size"] = .success("Physical size: 1080x2400\n")
    let session = AndroidMirrorSession(streamer: FakeStreamer(chunks: [stream([sps, pps, idr, idr])]), runner: runner,
                                       sdk: AndroidSDK(root: "/sdk"), serial: "S")
    let frames = FrameCounter()
    session.start(onFrame: { _ in frames.add() }, onEnd: { _ in })
    try await Task.sleep(for: .milliseconds(300))
    session.stop()
    #expect(frames.value >= 1)
}

@Test func sessionReportsAStreamThatKeepsDyingImmediately() async throws {
    let runner = MockShellRunner()
    let session = AndroidMirrorSession(streamer: FakeStreamer(chunks: []), runner: runner,
                                       sdk: AndroidSDK(root: "/sdk"), serial: "S")
    let ended = FrameCounter()
    session.start(onFrame: { _ in }, onEnd: { _ in ended.add() })
    try await Task.sleep(for: .milliseconds(300))
    #expect(ended.value == 1)
}

@Test func androidInputCommands() async throws {
    let runner = MockShellRunner()
    let input = AndroidInput(runner: runner, sdk: AndroidSDK(root: "/sdk"), serial: "S")
    try await input.tap(x: 10, y: 20)
    try await input.swipe(from: (1, 2), to: (3, 4), duration: .milliseconds(250))
    try await input.press(.home)
    #expect(runner.commands == [
        "/sdk/platform-tools/adb -s S shell input tap 10 20",
        "/sdk/platform-tools/adb -s S shell input swipe 1 2 3 4 250",
        "/sdk/platform-tools/adb -s S shell input keyevent 3"])
}
