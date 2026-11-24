import Foundation

public enum LogColumn: String, CaseIterable, Codable, Sendable {
    case time, level, app, tag, pid, message

    public var title: String {
        switch self {
        case .time: "Time"
        case .level: "Level"
        case .app: "App"
        case .tag: "Tag"
        case .pid: "PID"
        case .message: "Message"
        }
    }

    /// What the column header says; short for narrow columns.
    public var headerTitle: String { self == .level ? "Lvl" : title }

    public var defaultWidth: Double {
        switch self {
        case .time: 84
        case .level: 28
        case .app: 110
        case .tag: 110
        case .pid: 46
        case .message: 0   // takes what is left
        }
    }

    public var minimumWidth: Double { self == .level ? 18 : 30 }
}

public enum LogTimeFormat: String, CaseIterable, Codable, Sendable {
    /// 16:20:01.123
    case milliseconds
    /// 16:20:01
    case seconds
    /// 20:01.1 (minutes, seconds, tenth)
    case compact

    public var title: String {
        switch self {
        case .milliseconds: "16:20:01.123"
        case .seconds: "16:20:01"
        case .compact: "20:01.1"
        }
    }

    public func format(_ time: String) -> String {
        switch self {
        case .milliseconds:
            return time
        case .seconds:
            return String(time.prefix(8))
        case .compact:
            guard time.count >= 10 else { return time }
            return String(time.dropFirst(3).prefix(7))
        }
    }
}

/// Which log columns show, in what order and how wide.
public struct LogColumnLayout: Equatable, Codable, Sendable {
    public private(set) var order: [LogColumn]
    public private(set) var hidden: Set<LogColumn>
    public private(set) var widths: [LogColumn: Double]
    public var timeFormat: LogTimeFormat

    public init(order: [LogColumn] = [.time, .level, .app, .tag, .message], hidden: Set<LogColumn> = [.pid],
                widths: [LogColumn: Double] = [:], timeFormat: LogTimeFormat = .milliseconds) {
        // every column is always in `order`, so a column added later is not lost from a saved layout
        self.order = order + LogColumn.allCases.filter { !order.contains($0) }
        self.hidden = hidden.subtracting([.message])
        self.widths = widths
        self.timeFormat = timeFormat
    }

    public init?(json: String) {
        guard let layout = try? JSONDecoder().decode(LogColumnLayout.self, from: Data(json.utf8)) else { return nil }
        self.init(order: layout.order, hidden: layout.hidden, widths: layout.widths, timeFormat: layout.timeFormat)
    }

    public var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public var visible: [LogColumn] { order.filter { !hidden.contains($0) } }

    public func width(of column: LogColumn) -> Double { widths[column] ?? column.defaultWidth }

    public mutating func resize(_ column: LogColumn, to width: Double) {
        guard column != .message else { return }
        widths[column] = min(max(width, column.minimumWidth), 600)
    }

    /// The message column cannot be hidden: it is the log.
    public mutating func setVisible(_ column: LogColumn, _ isVisible: Bool) {
        guard column != .message else { return }
        if isVisible { hidden.remove(column) } else { hidden.insert(column) }
    }

    /// Puts `column` where `target` is.
    public mutating func move(_ column: LogColumn, to target: LogColumn) {
        guard column != target, let from = order.firstIndex(of: column), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(column, at: to)
    }
}
