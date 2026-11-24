import Foundation

public enum LogSourceError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)

    public var description: String {
        switch self {
        case .unsupported(let reason): reason
        }
    }
}

/// Which command streams a device's log, and how its lines are read.
public struct LogSource: Sendable {
    public enum Format: Sendable { case logcat, apple }

    public let executable: String
    public let arguments: [String]
    public let format: Format
    public let serial: String?
    public let adbPath: String?

    /// `sdk` is needed for Android devices only.
    public static func make(for device: Device, sdk: AndroidSDK?) throws -> LogSource {
        switch (device.platform, device.isPhysical) {
        case (.android, _):
            guard let sdk, let serial = device.serial else {
                throw LogSourceError.unsupported("Android SDK not found — set path in Settings")
            }
            return LogSource(executable: sdk.adbPath,
                             arguments: ["-s", serial, "logcat", "-v", "threadtime", "-T", "500"],
                             format: .logcat, serial: serial, adbPath: sdk.adbPath)
        case (.ios, false):
            return LogSource(executable: "/usr/bin/xcrun",
                             arguments: ["simctl", "spawn", device.id, "log", "stream", "--style", "ndjson", "--level", "debug"],
                             format: .apple, serial: nil, adbPath: nil)
        case (.ios, true):
            throw LogSourceError.unsupported("Apple offers no log stream for a real iPhone or iPad outside Console.app")
        }
    }

    func parse(_ line: String) -> LogEntry? {
        switch format {
        case .logcat: LogParser.parseLogcat(line)
        case .apple: LogParser.parseApple(line)
        }
    }
}

/// Resolves Android process ids to package names, refreshing only when an unknown pid shows up.
actor AndroidProcessNames {
    private let runner: any ShellRunner
    private let adbPath: String
    private let serial: String
    private var names: [Int: String] = [:]
    private var lastRefresh = ContinuousClock.Instant.now - .seconds(10)
    private let minimumInterval: Duration

    init(runner: any ShellRunner, adbPath: String, serial: String, minimumInterval: Duration = .seconds(2)) {
        self.runner = runner
        self.adbPath = adbPath
        self.serial = serial
        self.minimumInterval = minimumInterval
    }

    func name(for pid: Int) async -> String? {
        if let known = names[pid] { return known }
        guard ContinuousClock.now - lastRefresh >= minimumInterval else { return nil }
        lastRefresh = .now
        if let output = try? await runner.run(adbPath, ["-s", serial, "shell", "ps", "-A", "-o", "PID,NAME"]) {
            for (id, name) in Self.parse(output) { names[id] = name }
        }
        return names[pid]
    }

    static func parse(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let pid = Int(parts[0]), !parts[1].isEmpty { result[pid] = parts[1] }
        }
        return result
    }
}
