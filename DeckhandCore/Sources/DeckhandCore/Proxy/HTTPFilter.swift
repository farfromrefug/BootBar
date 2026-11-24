import Foundation

public struct HTTPFilter: Equatable, Sendable, Codable {
    public enum Scope: String, CaseIterable, Codable, Sendable {
        case url, headers, body

        public var title: String {
            switch self {
            case .url: "URL"
            case .headers: "Headers"
            case .body: "Bodies"
            }
        }
    }

    public var query = ""
    public var isRegex = false
    /// Where the search looks.
    public var scopes: Set<Scope> = [.url]
    /// Empty means every method.
    public var methods: Set<String> = []
    /// 2, 3, 4, 5 for status classes and 0 for flows that failed. Empty means all.
    public var statusClasses: Set<Int> = []
    /// Empty means every app.
    public var apps: Set<String> = []
    /// Hide CONNECT tunnels that were not decrypted (excluded hosts, other protocols).
    public var hidesTunnels = true

    public init(query: String = "", isRegex: Bool = false, scopes: Set<Scope> = [.url], methods: Set<String> = [],
                statusClasses: Set<Int> = [], apps: Set<String> = [], hidesTunnels: Bool = true) {
        self.query = query
        self.isRegex = isRegex
        self.scopes = scopes
        self.methods = methods
        self.statusClasses = statusClasses
        self.apps = apps
        self.hidesTunnels = hidesTunnels
    }

    public var isValid: Bool { !isRegex || query.isEmpty || (try? NSRegularExpression(pattern: query)) != nil }

    public var isActive: Bool {
        !query.isEmpty || !methods.isEmpty || !statusClasses.isEmpty || !apps.isEmpty || !hidesTunnels
    }

    public func compiled() -> Matcher { Matcher(filter: self) }

    public struct Matcher: Sendable {
        fileprivate let filter: HTTPFilter
        private let expression: NSRegularExpression?

        fileprivate init(filter: HTTPFilter) {
            self.filter = filter
            expression = filter.isRegex && !filter.query.isEmpty
                ? try? NSRegularExpression(pattern: filter.query, options: [.caseInsensitive]) : nil
        }

        public func matches(_ flow: HTTPFlow) -> Bool {
            if filter.hidesTunnels, flow.isTunnel, flow.state != .failed { return false }
            if !filter.methods.isEmpty, !filter.methods.contains(flow.method) { return false }
            if !filter.statusClasses.isEmpty {
                let group = flow.state == .failed ? 0 : (flow.status.map { $0 / 100 } ?? -1)
                guard filter.statusClasses.contains(group) else { return false }
            }
            if !filter.apps.isEmpty, !filter.apps.contains(flow.appName) { return false }
            guard !filter.query.isEmpty else { return true }
            return searchable(flow).contains { text in
                if filter.isRegex {
                    guard let expression else { return true }
                    return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                }
                return text.range(of: filter.query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        private func searchable(_ flow: HTTPFlow) -> [String] {
            var texts = [flow.method, flow.urlString, flow.appName, flow.statusText]
            if filter.scopes.contains(.headers) {
                texts += (flow.requestHeaders + flow.responseHeaders).map { "\($0.name): \($0.value)" }
            }
            if filter.scopes.contains(.body) {
                texts.append(String(decoding: flow.requestBody.prefix(200_000), as: UTF8.self))
                texts.append(String(decoding: FlowFormatter.responseBody(of: flow).prefix(200_000), as: UTF8.self))
            }
            return texts
        }
    }
}
