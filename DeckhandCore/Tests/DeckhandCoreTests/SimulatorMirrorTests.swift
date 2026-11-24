import Foundation
import Testing
@testable import DeckhandCore

private func chunk(tag: UInt8, _ payload: [UInt8]) -> Data {
    let length = UInt32(payload.count + 1)
    return Data((0..<4).map { UInt8((length >> (8 * UInt32(3 - $0))) & 0xff) } + [tag] + payload)
}

/// The avcC `baguette stream` sent for a 402×874-point iPhone 17 Pro (High profile, 4-byte NAL lengths).
private let avcC: [UInt8] = Array(Data(hexString: "01640033ffe1001627640033ac13143c04c0149e6a9a81010103c20108f801000428ee3cb0")!)

private extension Data {
    init?(hexString: String) {
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            guard let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex),
                  let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

@Test func parserSplitsChunksAcrossArbitraryReads() throws {
    var parser = AVCCStreamParser()
    let stream = chunk(tag: 4, [1, 2, 3]) + chunk(tag: 1, avcC) + chunk(tag: 3, [9])
    var chunks: [AVCCStreamParser.Chunk] = []
    for byte in stream { chunks += try parser.push(Data([byte])) }
    #expect(chunks.map(\.tag) == [4, 1, 3])
    #expect(chunks[0].payload == Data([1, 2, 3]))
    #expect(chunks[1].payload == Data(avcC))
}

@Test func parserRejectsNonsenseLengths() {
    var parser = AVCCStreamParser()
    #expect(throws: AVCCStreamParser.ParseError.oversizedChunk(0x7fff_ffff)) {
        _ = try parser.push(Data([0x7f, 0xff, 0xff, 0xff, 2]))
    }
}

@Test func builderReadsTheAvcCDescriptionAndWrapsFrames() throws {
    var builder = AVCCFrameBuilder()
    #expect(builder.frame(Data([0, 0, 0, 1, 0x65])) == nil)   // no description yet
    let tooShort = builder.configure(avcC: Data([1, 2]))
    let configured = builder.configure(avcC: Data(avcC))
    #expect(!tooShort)
    #expect(configured)
    let frame = try #require(builder.frame(Data([0, 0, 0, 2, 0x65, 0xb8])))
    #expect(frame.width == 402 * 3)
    #expect(frame.height == 874 * 3)
}

private struct FakeStreamer: ByteStreaming {
    let chunks: [Data]
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            #expect(arguments == ["stream", "--udid", "U", "--format", "avcc", "--fps", "60", "--scale", "1"])
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var ends: [String?] = []
    func frame() { lock.withLock { frames += 1 } }
    func end(_ message: String?) { lock.withLock { ends.append(message) } }
    var frameCount: Int { lock.withLock { frames } }
    var endMessages: [String?] { lock.withLock { ends } }
}

@Test func sessionDeliversKeyframesAndDeltasButSkipsTheJpegSeed() async throws {
    let counter = Counter()
    let streamer = FakeStreamer(chunks: [
        chunk(tag: 4, [0xff, 0xd8]), chunk(tag: 1, avcC),
        chunk(tag: 2, [0, 0, 0, 2, 0x65, 0xb8]), chunk(tag: 3, [0, 0, 0, 2, 0x41, 0x01]), chunk(tag: 3, [0, 0, 0, 2, 0x41, 0x02])
    ])
    SimulatorMirrorSession(executable: "/x/baguette", udid: "U", streamer: streamer)
        .start(onFrame: { _ in counter.frame() }, onEnd: { counter.end($0) })
    try await Task.sleep(for: .milliseconds(300))
    #expect(counter.frameCount == 3)
    #expect(counter.endMessages == ["The simulator stopped streaming"])
}

@Test func sessionReportsAStreamThatNeverProducesAPicture() async throws {
    let counter = Counter()
    SimulatorMirrorSession(executable: "/x/baguette", udid: "U", streamer: FakeStreamer(chunks: []))
        .start(onFrame: { _ in counter.frame() }, onEnd: { counter.end($0) })
    try await Task.sleep(for: .milliseconds(300))
    #expect(counter.endMessages == ["Baguette did not deliver any picture"])
}
