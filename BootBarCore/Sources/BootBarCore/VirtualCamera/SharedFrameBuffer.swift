import Darwin
import Foundation

/// The frame buffer the virtual camera dylib reads inside the simulator.
///
/// `/tmp/SimCam.bgra` holds a 24-byte little-endian header followed by BGRA pixels
/// (premultiplied first, 32-bit little endian):
///
///     [0..<4] sequence   [4..<8] timestamp (ms)   [8..<12] width   [12..<16] height
///     [16..<20] flags (bit 0 fill, bit 1 mirror)  [20..<24] reserved
///
/// The simulator's `/tmp` is the host's `/private/tmp`, so a mapped file written here is
/// visible to apps there. The dylib's reader rejects frames above 1280×1280.
public enum SharedFrameLayout {
    public static let path = "/tmp/SimCam.bgra"
    public static let headerSize = 24
    public static let maxWidth = 1280
    public static let maxHeight = 1280
    public static var totalByteCount: Int { headerSize + maxWidth * maxHeight * 4 }

    public static func header(sequence: UInt32, timestampMs: UInt32, width: Int, height: Int, flags: CameraFlags) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: headerSize)
        for (offset, value) in [(0, sequence), (4, timestampMs), (8, UInt32(width)), (12, UInt32(height)), (16, flags.packed)] {
            for shift in 0..<4 { bytes[offset + shift] = UInt8((value >> (8 * UInt32(shift))) & 0xff) }
        }
        return bytes
    }
}

public struct CameraFlags: Equatable, Sendable {
    public var fill: Bool
    public var mirror: Bool

    public init(fill: Bool = false, mirror: Bool = false) {
        self.fill = fill
        self.mirror = mirror
    }

    public var packed: UInt32 { (fill ? 1 : 0) | (mirror ? 2 : 0) }
}

public enum SharedFrameBufferError: LocalizedError, Equatable, CustomStringConvertible {
    case open(path: String, code: Int32)
    case inUse(path: String)
    case resize(code: Int32)
    case map(code: Int32)

    public var description: String {
        switch self {
        case .open(let path, let code): "Could not open \(path): \(String(cString: strerror(code)))"
        case .inUse(let path): "Another virtual camera (Baguette, for instance) is already using \(path). Stop it first."
        case .resize(let code): "Could not size the frame buffer: \(String(cString: strerror(code)))"
        case .map(let code): "Could not map the frame buffer: \(String(cString: strerror(code)))"
        }
    }
}

/// Writer side of the shared frame buffer. Holds an exclusive file lock, which also keeps
/// Baguette (it locks the same file) from writing frames at the same time.
public final class SharedFrameBuffer: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var base: UnsafeMutableRawPointer?
    private var sequence: UInt32 = 0
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now

    public init(path: String = SharedFrameLayout.path) throws {
        self.path = path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw SharedFrameBufferError.open(path: path, code: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw SharedFrameBufferError.inUse(path: path)
        }
        guard ftruncate(descriptor, off_t(SharedFrameLayout.totalByteCount)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SharedFrameBufferError.resize(code: code)
        }
        guard let mapped = mmap(nil, SharedFrameLayout.totalByteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
              mapped != MAP_FAILED else {
            let code = errno
            Darwin.close(descriptor)
            throw SharedFrameBufferError.map(code: code)
        }
        self.descriptor = descriptor
        base = mapped
    }

    deinit { close() }

    /// Lets `fill` paint BGRA pixels for a `width`×`height` frame straight into the mapping,
    /// then publishes the header with a new sequence number.
    public func write(width: Int, height: Int, flags: CameraFlags,
                      fill: (_ pixels: UnsafeMutableRawPointer, _ rowBytes: Int) -> Void) {
        guard width > 0, height > 0, width <= SharedFrameLayout.maxWidth, height <= SharedFrameLayout.maxHeight else { return }
        lock.withLock {
            guard let base else { return }
            fill(base + SharedFrameLayout.headerSize, width * 4)
            sequence &+= 1
            let elapsed = ContinuousClock.now - origin
            let milliseconds = UInt32(truncatingIfNeeded: Int(elapsed / .milliseconds(1)))
            let header = SharedFrameLayout.header(sequence: sequence, timestampMs: milliseconds, width: width,
                                                   height: height, flags: flags)
            header.withUnsafeBytes { memcpy(base, $0.baseAddress!, SharedFrameLayout.headerSize) }
            msync(base, SharedFrameLayout.headerSize + width * height * 4, MS_SYNC)
        }
    }

    public func close() {
        lock.withLock {
            if let base { munmap(base, SharedFrameLayout.totalByteCount) }
            base = nil
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                Darwin.close(descriptor)
            }
            descriptor = -1
        }
    }
}

extension SharedFrameBufferError {
    public var errorDescription: String? { description }
}
