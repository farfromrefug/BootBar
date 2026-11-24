import Foundation

/// Turns lines of `adb logcat -v threadtime` and `log stream --style ndjson` into entries.
public enum LogParser {
    private static let logcat = try! NSRegularExpression(
        pattern: #"^\d\d-\d\d (\d\d:\d\d:\d\d\.\d{3})\s+(\d+)\s+\d+\s+([VDIWEFS])\s+(.+?)\s*:\s?(.*)$"#)

    public static func parseLogcat(_ line: String) -> LogEntry? {
        let range = NSRange(line.startIndex..., in: line)
        if let match = logcat.firstMatch(in: line, range: range) {
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
            return LogEntry(time: group(1), level: androidLevel(group(3)), pid: Int(group(2)), app: nil,
                            tag: group(4), message: group(5))
        }
        // "--------- beginning of main" and similar buffer markers
        if line.hasPrefix("--------- ") {
            return LogEntry(time: "", level: .info, pid: nil, app: nil, tag: "logcat",
                            message: String(line.dropFirst("--------- ".count)))
        }
        return nil
    }

    static func androidLevel(_ letter: String) -> LogLevel {
        switch letter {
        case "V": .verbose
        case "D": .debug
        case "W": .warning
        case "E": .error
        case "F", "S": .fault
        default: .info
        }
    }

    private struct AppleEvent: Decodable {
        let eventMessage: String?
        let messageType: String?
        let subsystem: String?
        let category: String?
        let processImagePath: String?
        let processID: Int?
        let timestamp: String?
    }

    public static func parseApple(_ line: String) -> LogEntry? {
        guard line.hasPrefix("{"),
              let event = try? JSONDecoder().decode(AppleEvent.self, from: Data(line.utf8)),
              let message = event.eventMessage else { return nil }
        let process = event.processImagePath.map { ($0 as NSString).lastPathComponent }
        let tag = [event.subsystem, event.category].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        return LogEntry(time: appleTime(event.timestamp), level: appleLevel(event.messageType), pid: event.processID,
                        app: process, tag: tag, message: message)
    }

    /// "2026-11-24 16:20:00.123456+0100" to "16:20:00.123"
    static func appleTime(_ timestamp: String?) -> String {
        guard let timestamp, let space = timestamp.firstIndex(of: " ") else { return "" }
        let time = timestamp[timestamp.index(after: space)...]
        guard let dot = time.firstIndex(of: ".") else { return String(time.prefix(8)) }
        let fraction = time[time.index(after: dot)...].prefix(3)
        return "\(time[..<dot]).\(fraction)"
    }

    static func appleLevel(_ type: String?) -> LogLevel {
        switch type {
        case "Debug": .debug
        case "Error": .error
        case "Fault": .fault
        default: .info
        }
    }
}

/// Splits a byte stream into lines, holding a partial last line for the next chunk.
public struct LineSplitter: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func push(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0a) {
            var line = pending[pending.startIndex..<newline]
            if line.last == 0x0d { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        // a stream that never sends a newline must not grow without bound
        if pending.count > 1_000_000 { pending.removeAll() }
        return lines
    }
}
