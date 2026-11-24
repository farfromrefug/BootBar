import AppKit
import DeckhandCore
import SwiftUI

/// One request in the style of the browser network tools: headers, the request body, a response preview and timing.
struct FlowDetailView: View {
    let flow: HTTPFlow
    let model: NetworkViewModel
    let close: () -> Void

    enum Tab: String, CaseIterable {
        case headers = "Headers", request = "Request", response = "Response", timing = "Timing"
    }

    @AppStorage("networkDetailTab") private var tabRaw = Tab.headers.rawValue
    @AppStorage("networkResponseRaw") private var showsRaw = false

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .headers }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { tab }, set: { tabRaw = $0.rawValue })) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text(flow.urlString).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    FlowActions(flow: flow, model: model)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                PanelHeaderButton(symbol: "xmark", help: "Close the details", action: close)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            switch tab {
            case .headers: headers
            case .request: BodyView(data: FlowFormatter.requestBody(of: flow), mimeType: flow.requestContentType,
                                   truncated: flow.isRequestBodyTruncated, totalSize: flow.requestBodySize, showsRaw: .constant(false),
                                   emptyText: flow.isTunnel ? "Tunnelled, not decrypted" : "No request body")
            case .response: response
            case .timing: timing
            }
        }
        .background(.background)
    }

    // MARK: Headers

    private var headers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Section("General") {
                    row("Request URL", flow.urlString)
                    row("Request Method", flow.method)
                    if flow.isTunnel {
                        row("Connection", "Tunnelled, not decrypted")
                    } else {
                        row("Status Code", flow.status.map { "\($0) \(flow.reason ?? "")" } ?? flow.statusText, color: statusColor)
                    }
                    row("HTTP Version", flow.httpVersion)
                    row("App", flow.appName + (flow.client.pid.map { " (pid \($0))" } ?? ""))
                    if let error = flow.error { row("Error", error, color: .red) }
                }
                if !flow.responseHeaders.isEmpty {
                    Section("Response Headers", copy: FlowFormatter.headersText(flow.responseHeaders)) {
                        ForEach(Array(flow.responseHeaders.enumerated()), id: \.offset) { row($1.name, $1.value) }
                    }
                }
                if !flow.requestHeaders.isEmpty {
                    Section("Request Headers", copy: FlowFormatter.headersText(flow.requestHeaders)) {
                        ForEach(Array(flow.requestHeaders.enumerated()), id: \.offset) { row($1.name, $1.value) }
                    }
                }
                if let query = flow.query, !query.isEmpty {
                    Section("Query Parameters") {
                        ForEach(Array(Self.queryItems(query).enumerated()), id: \.offset) { row($1.0, $1.1) }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func queryItems(_ query: String) -> [(String, String)] {
        query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (text: Substring) in String(text).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(text) }
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    private func row(_ name: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).fontWeight(.semibold).foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text(value).foregroundStyle(color).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var statusColor: Color {
        switch (flow.status ?? 0) / 100 {
        case 2: .green
        case 3: .blue
        case 4: .orange
        case 0: .secondary
        default: .red
        }
    }

    private struct Section<Content: View>: View {
        let title: String
        var copy: String?
        @ViewBuilder let content: Content

        init(_ title: String, copy: String? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.copy = copy
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.system(size: 11, weight: .bold))
                    if let copy {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(copy, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Copy \(title.lowercased())")
                    }
                }
                content
            }
        }
    }

    // MARK: Response

    private var response: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $showsRaw) {
                    Text("Preview").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text([flow.responseContentType, FlowFormatter.sizeText(flow.responseBodySize)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copy(String(decoding: FlowFormatter.responseBody(of: flow), as: UTF8.self)) }
                    .controlSize(.small).disabled(flow.responseBody.isEmpty)
                Button("Save…") { save() }.controlSize(.small).disabled(flow.responseBody.isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            Divider()
            BodyView(data: FlowFormatter.responseBody(of: flow), mimeType: flow.responseMimeType,
                     truncated: flow.isResponseBodyTruncated, totalSize: flow.responseBodySize, showsRaw: $showsRaw,
                     emptyText: flow.isTunnel ? "Tunnelled, not decrypted" : (flow.state == .complete ? "No response body" : "Waiting for the response…"))
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FlowFormatter.suggestedFileName(for: flow)
        let data = FlowFormatter.responseBody(of: flow)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    // MARK: Timing

    private var timing: some View {
        let start = flow.startedAt
        let steps: [(String, TimeInterval?)] = [
            ("Request sent", flow.requestSentAt.map { $0.timeIntervalSince(start) }),
            ("Waiting for the first byte", flow.firstByteAt.map { $0.timeIntervalSince(flow.requestSentAt ?? start) }),
            ("Content download", flow.finishedAt.flatMap { end in flow.firstByteAt.map { end.timeIntervalSince($0) } }),
            ("Total", flow.duration)
        ]
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                row("Started", start.formatted(date: .abbreviated, time: .standard))
                ForEach(steps, id: \.0) { row($0.0, FlowFormatter.durationText($0.1)) }
                row("Request size", FlowFormatter.sizeText(flow.requestBodySize))
                row("Response size", FlowFormatter.sizeText(flow.responseBodySize))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A body shown as pretty JSON, an image, text or a hex dump.
private struct BodyView: View {
    let data: Data
    let mimeType: String?
    let truncated: Bool
    let totalSize: Int
    @Binding var showsRaw: Bool
    let emptyText: String

    /// Showing megabytes of text in a text view is slow; the rest can be copied or saved.
    private static let displayLimit = 512 * 1024

    var body: some View {
        let kind = FlowFormatter.kind(of: data, mimeType: mimeType)
        VStack(spacing: 0) {
            if truncated {
                Text("Only the first \(FlowFormatter.sizeText(data.count)) of \(FlowFormatter.sizeText(totalSize)) were kept.")
                    .font(.system(size: 11)).padding(6).frame(maxWidth: .infinity).background(.orange.opacity(0.15))
            }
            switch kind {
            case .empty:
                Text(emptyText).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .image where !showsRaw:
                if let image = NSImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(spacing: 6) {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(maxWidth: max(image.size.width, 1), maxHeight: max(image.size.height, 1))
                                .background(checkerboard)
                            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(12).frame(maxWidth: .infinity)
                    }
                } else {
                    SelectableText(text: Self.hexDump(data))
                }
            case .binary:
                SelectableText(text: Self.hexDump(data))
            case .json where !showsRaw:
                SelectableText(text: limited(FlowFormatter.prettyJSON(data) ?? String(decoding: data, as: UTF8.self)))
            default:
                SelectableText(text: kind == .image ? Self.hexDump(data) : limited(String(decoding: data, as: UTF8.self)))
            }
        }
    }

    private func limited(_ text: String) -> String {
        text.utf8.count > Self.displayLimit ? String(text.prefix(Self.displayLimit)) + "\n… (cut, copy or save to get everything)" : text
    }

    private var checkerboard: some View {
        Rectangle().fill(.quaternary.opacity(0.5))
    }

    static func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = Array(data.prefix(16 * 1024))
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let text = String(chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", offset) + hex.padding(toLength: 47, withPad: " ", startingAt: 0) + "  " + text)
        }
        if data.count > bytes.count { lines.append("… \(FlowFormatter.sizeText(data.count - bytes.count)) more") }
        return lines.joined(separator: "\n")
    }
}

/// A read-only monospaced text view: cheap for large bodies and selectable.
private struct SelectableText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 6, height: 6)
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.textContainer?.widthTracksTextView = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}
