import Foundation

public enum BodyKind: Equatable, Sendable {
    case empty, json, image, html, xml, text, binary
}

/// Turns a flow into the text a developer copies, saves or reads.
public enum FlowFormatter {
    /// The response body with `Content-Encoding` removed, when it can be.
    public static func responseBody(of flow: HTTPFlow) -> Data {
        decoded(flow.responseBody, headers: flow.responseHeaders)
    }

    public static func requestBody(of flow: HTTPFlow) -> Data {
        decoded(flow.requestBody, headers: flow.requestHeaders)
    }

    private static func decoded(_ body: Data, headers: [HTTPHeader]) -> Data {
        guard !body.isEmpty, let encoding = headers.value(for: "Content-Encoding") else { return body }
        return BodyDecoder.decode(body, encoding: encoding) ?? body
    }

    public static func kind(of data: Data, mimeType: String?) -> BodyKind {
        if data.isEmpty { return .empty }
        let mime = mimeType ?? ""
        if mime.contains("json") || (mime.isEmpty && looksLikeJSON(data)) { return .json }
        if mime.hasPrefix("image/") || data.starts(with: [0x89, 0x50, 0x4e, 0x47]) || data.starts(with: [0xff, 0xd8, 0xff])
            || data.starts(with: Array("GIF8".utf8)) { return .image }
        if mime.contains("html") { return .html }
        if mime.contains("xml") { return .xml }
        if mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("x-www-form-urlencoded")
            || mime.contains("graphql") { return .text }
        return String(data: data.prefix(4096), encoding: .utf8) != nil && !data.prefix(4096).contains(0) ? .text : .binary
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0a && $0 != 0x0d && $0 != 0x09 }) else { return false }
        return (first == UInt8(ascii: "{") || first == UInt8(ascii: "[")) && (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Indented JSON, or nil when the data is not JSON.
    public static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    /// `Name: value` lines.
    public static func headersText(_ headers: [HTTPHeader]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// The request as it went over the wire, without the body.
    public static func requestHead(of flow: HTTPFlow) -> String {
        "\(flow.method) \(flow.path.isEmpty ? "/" : flow.path) \(flow.httpVersion)\n" + headersText(flow.requestHeaders)
    }

    public static func responseHead(of flow: HTTPFlow) -> String {
        guard let status = flow.status else { return "" }
        return "\(flow.httpVersion) \(status) \(flow.reason ?? "")\n" + headersText(flow.responseHeaders)
    }

    /// A `curl` command that repeats the request.
    public static func curl(for flow: HTTPFlow) -> String {
        var parts = ["curl"]
        if flow.method != "GET" { parts += ["-X", flow.method] }
        parts.append(shellQuote(flow.urlString))
        let skipped: Set<String> = ["content-length", "host", "connection", "accept-encoding", "proxy-connection"]
        for header in flow.requestHeaders where !skipped.contains(header.name.lowercased()) {
            parts += ["-H", shellQuote("\(header.name): \(header.value)")]
        }
        if flow.requestHeaders.value(for: "Accept-Encoding") != nil { parts.append("--compressed") }
        let body = requestBody(of: flow)
        if !body.isEmpty {
            if let text = String(data: body, encoding: .utf8) {
                parts += ["--data-raw", shellQuote(text)]
            } else {
                parts += ["--data-binary", shellQuote("@<binary \(body.count) bytes>")]
            }
        }
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A file name for saving a response, from the URL and content type.
    public static func suggestedFileName(for flow: HTTPFlow) -> String {
        let last = flow.pathOnly.split(separator: "/").last.map(String.init) ?? ""
        if last.contains(".") { return last }
        let ext: String
        switch kind(of: flow.responseBody, mimeType: flow.responseMimeType) {
        case .json: ext = "json"
        case .html: ext = "html"
        case .xml: ext = "xml"
        case .image: ext = flow.responseMimeType.flatMap { $0.split(separator: "/").last.map(String.init) } ?? "img"
        case .text: ext = "txt"
        default: ext = "bin"
        }
        return (last.isEmpty ? flow.host : last) + "." + ext
    }

    public static func sizeText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    public static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        return seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}
