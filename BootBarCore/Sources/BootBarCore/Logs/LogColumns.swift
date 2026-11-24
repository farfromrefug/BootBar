import Foundation

public enum LogColumn: String, CaseIterable, Codable, Sendable, PanelColumn {
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

    public var isFlexible: Bool { self == .message }

    public static var defaultOrder: [LogColumn] { [.time, .level, .app, .tag, .message] }
    public static var defaultHidden: Set<LogColumn> { [.pid] }
}

public typealias LogTimeFormat = TimeFormat
public typealias LogColumnLayout = ColumnLayout<LogColumn>
