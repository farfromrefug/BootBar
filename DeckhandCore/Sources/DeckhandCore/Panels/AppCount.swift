import Foundation

/// An app seen by a panel, with how many entries it produced.
public struct AppCount: Identifiable, Equatable, Sendable {
    public let name: String
    public let count: Int
    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}
