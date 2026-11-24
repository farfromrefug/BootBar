import Foundation

/// A column of a table-like panel (logs, network requests).
public protocol PanelColumn: Hashable, Codable, CaseIterable, Sendable, RawRepresentable where RawValue == String {
    var title: String { get }
    /// What the header says; short for narrow columns.
    var headerTitle: String { get }
    var defaultWidth: Double { get }
    var minimumWidth: Double { get }
    /// Takes the width that is left, cannot be resized and cannot be hidden.
    var isFlexible: Bool { get }
    static var defaultOrder: [Self] { get }
    static var defaultHidden: Set<Self> { get }
}

public enum TimeFormat: String, CaseIterable, Codable, Sendable {
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

/// Which columns of a panel show, in what order and how wide.
public struct ColumnLayout<Column: PanelColumn>: Equatable, Codable, Sendable {
    public private(set) var order: [Column]
    public private(set) var hidden: Set<Column>
    public private(set) var widths: [Column: Double]
    public var timeFormat: TimeFormat

    public init(order: [Column]? = nil, hidden: Set<Column>? = nil, widths: [Column: Double] = [:],
                timeFormat: TimeFormat = .milliseconds) {
        let order = order ?? Column.defaultOrder
        // every column is always in `order`, so a column added later is not lost from a saved layout
        self.order = order + Column.allCases.filter { !order.contains($0) }
        self.hidden = (hidden ?? Column.defaultHidden).filter { !$0.isFlexible }
        self.widths = widths
        self.timeFormat = timeFormat
    }

    public init?(json: String) {
        guard let layout = try? JSONDecoder().decode(ColumnLayout.self, from: Data(json.utf8)) else { return nil }
        self.init(order: layout.order, hidden: layout.hidden, widths: layout.widths, timeFormat: layout.timeFormat)
    }

    public var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public var visible: [Column] { order.filter { !hidden.contains($0) } }

    public func width(of column: Column) -> Double { widths[column] ?? column.defaultWidth }

    public mutating func resize(_ column: Column, to width: Double) {
        guard !column.isFlexible else { return }
        widths[column] = min(max(width, column.minimumWidth), 600)
    }

    /// A flexible column (the message, the URL) is the point of the panel and always shows.
    public mutating func setVisible(_ column: Column, _ isVisible: Bool) {
        guard !column.isFlexible else { return }
        if isVisible { hidden.remove(column) } else { hidden.insert(column) }
    }

    /// Puts `column` where `target` is.
    public mutating func move(_ column: Column, to target: Column) {
        guard column != target, let from = order.firstIndex(of: column), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(column, at: to)
    }
}
