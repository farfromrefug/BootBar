import CoreMedia
import Foundation

/// Splits an Annex B byte stream into NAL units (start codes removed).
public struct AnnexBParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Returns every NAL unit that is known to be complete; the trailing one waits for the next start code.
    public mutating func push(_ data: Data) -> [[UInt8]] {
        buffer.append(contentsOf: data)
        let starts = startCodePositions()
        guard starts.count >= 2 else {
            // no complete unit yet; never let a stream without start codes grow without bound
            if buffer.count > 8_000_000 { buffer.removeAll() }
            return []
        }
        var units: [[UInt8]] = []
        for index in 0..<(starts.count - 1) {
            let begin = starts[index].end
            var end = starts[index + 1].start
            while end > begin, buffer[end - 1] == 0 { end -= 1 }
            if end > begin { units.append(Array(buffer[begin..<end])) }
        }
        buffer.removeSubrange(0..<starts[starts.count - 1].start)
        return units
    }

    /// The unit after the last start code, taken as complete. For streams that go quiet after a frame.
    public mutating func flush() -> [UInt8]? {
        guard let last = startCodePositions().last, last.end < buffer.count else { return nil }
        let unit = Array(buffer[last.end...])
        buffer.removeAll()
        return unit
    }

    private func startCodePositions() -> [(start: Int, end: Int)] {
        var positions: [(Int, Int)] = []
        var index = 0
        while index + 2 < buffer.count {
            if buffer[index] == 0, buffer[index + 1] == 0, buffer[index + 2] == 1 {
                let start = index > 0 && buffer[index - 1] == 0 ? index - 1 : index
                positions.append((start, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        return positions
    }
}

public struct VideoFrame: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public let width: Int
    public let height: Int
}

/// Turns H.264 NAL units into sample buffers an `AVSampleBufferDisplayLayer` can show immediately.
public struct H264FrameBuilder: Sendable {
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?

    public init() {}

    public mutating func push(_ nal: [UInt8]) -> VideoFrame? {
        guard let header = nal.first else { return nil }
        switch header & 0x1F {
        case 7:
            if sps != nal { sps = nal; format = nil }
        case 8:
            if pps != nal { pps = nal; format = nil }
        case 1, 5:
            return makeFrame(nal)
        default:
            break
        }
        return nil
    }

    private mutating func makeFrame(_ nal: [UInt8]) -> VideoFrame? {
        if format == nil, let sps, let pps { format = Self.formatDescription(sps: sps, pps: pps) }
        guard let format else { return nil }

        var avcc = [UInt8](repeating: 0, count: 4)
        let length = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: length) { avcc.replaceSubrange(0..<4, with: $0) }
        avcc.append(contentsOf: nal)
        return Self.frame(avcc: avcc, format: format)
    }

    /// Wraps length-prefixed (AVCC) sample data into a buffer an `AVSampleBufferDisplayLayer` shows immediately.
    static func frame(avcc: [UInt8], format: CMVideoFormatDescription) -> VideoFrame? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
              CMBlockBufferReplaceDataBytes(with: avcc, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: avcc.count) == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        return VideoFrame(sampleBuffer: sample, width: Int(dimensions.width), height: Int(dimensions.height))
    }

    private static func formatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var description: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                let pointers = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }
}

/// Feeds raw stream chunks to the parser and builder. A static screen makes `screenrecord` go silent
/// right after a frame, so the unit still waiting for a next start code is flushed once the stream idles.
public final class H264StreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = AnnexBParser()
    private var builder = H264FrameBuilder()
    private var lastChunk = ContinuousClock.now
    private let idleAfter: Duration

    public init(idleAfter: Duration = .milliseconds(60)) {
        self.idleAfter = idleAfter
    }

    public func feed(_ data: Data) -> [VideoFrame] {
        lock.withLock {
            lastChunk = ContinuousClock.now
            return parser.push(data).compactMap { builder.push($0) }
        }
    }

    public func flushIfIdle() -> [VideoFrame] {
        lock.withLock {
            guard ContinuousClock.now - lastChunk >= idleAfter, let unit = parser.flush() else { return [] }
            return builder.push(unit).map { [$0] } ?? []
        }
    }
}
