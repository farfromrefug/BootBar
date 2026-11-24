import CoreMedia
import Foundation

/// Reads `baguette stream --format avcc`: chunks of a 4-byte big-endian length (covering the tag and payload),
/// a 1-byte tag and the payload.
struct AVCCStreamParser {
    enum Tag: UInt8 {
        case jpegSeed = 4
        case description = 1
        case keyframe = 2
        case delta = 3
    }

    struct Chunk: Equatable {
        let tag: UInt8
        let payload: Data
    }

    enum ParseError: Error, Equatable {
        case oversizedChunk(Int)
    }

    private var buffer = Data()
    private static let maxChunk = 64 * 1024 * 1024

    mutating func push(_ data: Data) throws -> [Chunk] {
        buffer.append(data)
        var chunks: [Chunk] = []
        while buffer.count >= 5 {
            let length = Int(buffer.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            guard length >= 1, length <= Self.maxChunk else { throw ParseError.oversizedChunk(length) }
            guard buffer.count >= 4 + length else { break }
            let tag = buffer[buffer.startIndex + 4]
            chunks.append(Chunk(tag: tag, payload: Data(buffer.dropFirst(5).prefix(length - 1))))
            buffer.removeFirst(4 + length)
        }
        return chunks
    }
}

/// Turns the stream's avcC description and AVCC frames into sample buffers.
struct AVCCFrameBuilder {
    private var format: CMVideoFormatDescription?

    /// The avcC box body: version, profile, compatibility, level, length size, then the SPS and PPS lists.
    mutating func configure(avcC: Data) -> Bool {
        let bytes = [UInt8](avcC)
        guard bytes.count >= 7, bytes[0] == 1 else { return false }
        let headerLength = Int(bytes[4] & 0x03) + 1
        var offset = 6
        var sets: [[UInt8]] = []

        func readSets(count: Int) -> Bool {
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { return false }
                let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + size <= bytes.count else { return false }
                sets.append(Array(bytes[offset..<(offset + size)]))
                offset += size
            }
            return true
        }
        guard readSets(count: Int(bytes[5] & 0x1f)), offset < bytes.count else { return false }
        let ppsCount = Int(bytes[offset])
        offset += 1
        guard readSets(count: ppsCount), sets.count >= 2 else { return false }

        let pointers = sets.map { set -> UnsafePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            copy.initialize(from: set, count: set.count)
            return UnsafePointer(copy)
        }
        defer { pointers.forEach { $0.deallocate() } }
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
            parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: Int32(headerLength), formatDescriptionOut: &description)
        guard status == noErr else { return false }
        format = description
        return true
    }

    func frame(_ payload: Data) -> VideoFrame? {
        guard let format else { return nil }
        return H264FrameBuilder.frame(avcc: [UInt8](payload), format: format)
    }
}

/// Live view of an iOS simulator at up to 60 fps, from Baguette's H.264 stream.
public final class SimulatorMirrorSession: @unchecked Sendable {
    private let streamer: any ByteStreaming
    private let executable: String
    private let udid: String
    private let fps: Int
    private let scale: Int
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(executable: String, udid: String, streamer: any ByteStreaming = ProcessByteStreamer(),
                fps: Int = 60, scale: Int = 1) {
        self.executable = executable
        self.udid = udid
        self.streamer = streamer
        self.fps = fps
        self.scale = scale
    }

    /// `onEnd` receives a message when the stream could not start or died.
    public func start(onFrame: @escaping @Sendable (VideoFrame) -> Void, onEnd: @escaping @Sendable (String?) -> Void) {
        lock.withLock {
            task?.cancel()
            task = Task { [self] in await run(onFrame: onFrame, onEnd: onEnd) }
        }
    }

    public func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    private func run(onFrame: @escaping @Sendable (VideoFrame) -> Void, onEnd: @escaping @Sendable (String?) -> Void) async {
        var parser = AVCCStreamParser()
        var builder = AVCCFrameBuilder()
        var produced = false
        do {
            for try await data in streamer.stream(executable, ["stream", "--udid", udid, "--format", "avcc",
                                                               "--fps", "\(fps)", "--scale", "\(scale)"]) {
                for chunk in try parser.push(data) {
                    switch AVCCStreamParser.Tag(rawValue: chunk.tag) {
                    case .description:
                        _ = builder.configure(avcC: chunk.payload)
                    case .keyframe, .delta:
                        if let frame = builder.frame(chunk.payload) {
                            produced = true
                            onFrame(frame)
                        }
                    case .jpegSeed, nil:
                        break
                    }
                }
            }
        } catch {
            if Task.isCancelled { return }
            onEnd(ErrorMessage.friendly(error))
            return
        }
        if Task.isCancelled { return }
        onEnd(produced ? "The simulator stopped streaming" : "Baguette did not deliver any picture")
    }
}
