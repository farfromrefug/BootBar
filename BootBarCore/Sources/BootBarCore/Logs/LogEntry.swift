import Foundation

public enum LogLevel: Int, Comparable, CaseIterable, Sendable, Codable {
    case verbose, debug, info, warning, error, fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .verbose: "Verbose"
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        case .fault: "Fault"
        }
    }

    public var letter: String {
        switch self {
        case .verbose: "V"
        case .debug: "D"
        case .info: "I"
        case .warning: "W"
        case .error: "E"
        case .fault: "F"
        }
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public var id: Int
    /// `HH:mm:ss.SSS`
    public let time: String
    public let level: LogLevel
    public let pid: Int?
    /// The app or process that logged, when known (the package on Android, the executable on iOS).
    public var app: String?
    /// Android tag, or the subsystem and category on iOS.
    public let tag: String
    public let message: String

    public init(id: Int = 0, time: String, level: LogLevel, pid: Int?, app: String?, tag: String, message: String) {
        self.id = id
        self.time = time
        self.level = level
        self.pid = pid
        self.app = app
        self.tag = tag
        self.message = message
    }

    /// What the "Apps" filter groups by.
    public var appName: String { app ?? pid.map { "pid \($0)" } ?? "unknown" }

    /// True for the app itself and, on Android, for its other processes (`com.example:remote`).
    public func belongs(toApp name: String) -> Bool {
        appName == name || appName.hasPrefix(name + ":")
    }

    public var line: String { "\(time) \(level.letter) \(appName) \(tag): \(message)" }
}

public struct LogFilter: Equatable, Sendable, Codable {
    public var query = ""
    public var isRegex = false
    public var minimumLevel: LogLevel = .verbose
    /// Empty means every app.
    public var apps: Set<String> = []

    public init(query: String = "", isRegex: Bool = false, minimumLevel: LogLevel = .verbose, apps: Set<String> = []) {
        self.query = query
        self.isRegex = isRegex
        self.minimumLevel = minimumLevel
        self.apps = apps
    }

    /// False for a regular expression that does not compile, so the UI can say so.
    public var isValid: Bool { !isRegex || query.isEmpty || (try? NSRegularExpression(pattern: query)) != nil }

    public var isActive: Bool { !query.isEmpty || minimumLevel != .verbose || !apps.isEmpty }

    public func compiled() -> Matcher { Matcher(filter: self) }

    /// A filter prepared for matching many entries.
    public struct Matcher: Sendable {
        fileprivate let filter: LogFilter
        private let expression: NSRegularExpression?

        fileprivate init(filter: LogFilter) {
            self.filter = filter
            expression = filter.isRegex && !filter.query.isEmpty
                ? try? NSRegularExpression(pattern: filter.query, options: [.caseInsensitive]) : nil
        }

        public func matches(_ entry: LogEntry) -> Bool {
            guard entry.level >= filter.minimumLevel else { return false }
            if !filter.apps.isEmpty, !filter.apps.contains(where: { entry.belongs(toApp: $0) }) { return false }
            guard !filter.query.isEmpty else { return true }
            if filter.isRegex {
                guard let expression else { return true }   // an invalid pattern filters nothing
                return [entry.message, entry.tag, entry.appName].contains {
                    expression.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
                }
            }
            return [entry.message, entry.tag, entry.appName].contains {
                $0.range(of: filter.query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
