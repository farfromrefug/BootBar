import Foundation

public enum HTTPColumn: String, CaseIterable, Codable, Sendable, PanelColumn {
    case id, time, status, method, host, path, app, type, size, duration

    public var title: String {
        switch self {
        case .id: "#"
        case .time: "Time"
        case .status: "Status"
        case .method: "Method"
        case .host: "Host"
        case .path: "Path"
        case .app: "App"
        case .type: "Type"
        case .size: "Size"
        case .duration: "Time taken"
        }
    }

    public var headerTitle: String { self == .duration ? "Duration" : title }

    public var defaultWidth: Double {
        switch self {
        case .id: 34
        case .time: 84
        case .status: 52
        case .method: 56
        case .host: 150
        case .path: 0
        case .app: 100
        case .type: 56
        case .size: 62
        case .duration: 68
        }
    }

    public var minimumWidth: Double { self == .id ? 24 : 36 }
    public var isFlexible: Bool { self == .path }
    public static var defaultOrder: [HTTPColumn] { [.id, .status, .method, .host, .path, .app, .type, .size, .duration, .time] }
    public static var defaultHidden: Set<HTTPColumn> { [.time, .id] }
}

public typealias HTTPColumnLayout = ColumnLayout<HTTPColumn>
