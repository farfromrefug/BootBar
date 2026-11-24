import Compression
import Foundation

/// Undoes `Content-Encoding` so a body can be shown.
public enum BodyDecoder {
    /// The decoded body, or nil when the encoding is unknown or the data is not valid for it.
    public static func decode(_ data: Data, encoding: String?) -> Data? {
        let names = (encoding ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0 != "identity" && !$0.isEmpty }
        var result = data
        // encodings are listed in the order they were applied, so they come off in reverse
        for name in names.reversed() {
            guard let next = decodeOne(result, name) else { return nil }
            result = next
        }
        return result
    }

    private static func decodeOne(_ data: Data, _ name: String) -> Data? {
        switch name {
        case "gzip", "x-gzip": return inflate(stripGzipHeader(data))
        case "deflate": return inflate(stripZlibHeader(data)) ?? inflate(data)
        case "br": return run(data, algorithm: COMPRESSION_BROTLI)
        default: return nil
        }
    }

    private static func inflate(_ data: Data?) -> Data? {
        guard let data else { return nil }
        return run(data, algorithm: COMPRESSION_ZLIB)
    }

    /// Skips the 10-byte header and optional fields of a gzip stream; the 8-byte trailer is left for the decoder to ignore.
    static func stripGzipHeader(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {   // extra field
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {   // file name, comment: zero-terminated
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }   // header checksum
        guard offset < bytes.count - 8 else { return nil }
        return Data(bytes[offset..<(bytes.count - 8)])
    }

    /// `deflate` in HTTP is zlib-wrapped: two header bytes in front of the raw stream.
    static func stripZlibHeader(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 2, bytes[0] & 0x0f == 8, (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 else { return nil }
        return Data(bytes.dropFirst(2))
    }

    private static func run(_ data: Data, algorithm: compression_algorithm) -> Data? {
        guard !data.isEmpty else { return Data() }
        let bufferSize = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }

        var output = Data()
        return data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            stream.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = data.count
            stream.pointee.dst_ptr = destination
            stream.pointee.dst_size = bufferSize
            while true {
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.pointee.dst_size
                output.append(destination, count: produced)
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = bufferSize
                if status == COMPRESSION_STATUS_END { return output }
                if status != COMPRESSION_STATUS_OK { return output.isEmpty ? nil : output }
                // truncated input: the decoder wants more than there is and would otherwise spin
                if produced == 0 && stream.pointee.src_size == 0 { return output.isEmpty ? nil : output }
                if output.count > 200 * 1024 * 1024 { return nil }   // a decompression bomb
            }
        }
    }
}
