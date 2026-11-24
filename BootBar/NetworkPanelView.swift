import AppKit
import BootBarCore
import SwiftUI

/// HTTP and HTTPS traffic of the selected device: a request list with search and filters, and a detail pane.
struct NetworkPanelView: View {
    let device: Device
    let model: NetworkViewModel
    let kind: Binding<PanelKind>
    let isFull: Bool
    let onToggleFull: () -> Void
    let onClose: () -> Void

    @AppStorage("networkColumnLayout") private var layoutJSON = ""
    @AppStorage("networkRoutesMac") private var routesMac = true
    @State private var showSetup = false
    @State private var isAtBottom = true
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var scrollRequest = 0
    @State private var followTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            filterBar(filter: $model.filter)
            Divider()
            banner
            PanelColumnHeader(layout: Binding(get: { layout }, set: { layout = $0 }), showsTimeFormat: true)
            Divider()
            if model.selectedFlow != nil {
                VSplitView {
                    list.frame(minHeight: 90)
                    FlowDetailView(flow: model.selectedFlow!, model: model, close: { model.selectedFlowId = nil })
                        .frame(minHeight: 140)
                }
            } else {
                list
            }
        }
        .background(.background)
        .onAppear { isAtBottom = true }
        .task(id: device.id) { await model.select(device) }
    }

    private var layout: HTTPColumnLayout {
        get { HTTPColumnLayout(json: layoutJSON) ?? HTTPColumnLayout() }
        nonmutating set { layoutJSON = newValue.json }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            PanelKindPicker(kind: kind)
            captureToggle
            statusText
            Spacer()
            Button { showSetup.toggle() } label: {
                Label("Set Up", systemImage: "checklist")
                    .labelStyle(.titleAndIcon).font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSetup, arrowEdge: .bottom) {
                DeviceSetupView(device: device, model: model, routesMac: $routesMac)
            }
            PanelHeaderButton(symbol: model.isPaused ? "play.fill" : "pause.fill", help: model.isPaused ? "Resume" : "Pause") {
                model.isPaused.toggle()
            }
            PanelHeaderButton(symbol: "arrow.down.to.line", help: isAtBottom ? "Following the newest request" : "Jump to the newest request and follow",
                              tint: isAtBottom ? .accentColor : .secondary) { scrollRequest += 1 }
            PanelHeaderButton(symbol: "trash", help: "Clear") { model.clear() }
            Divider().frame(height: 14)
            PanelHeaderButton(symbol: isFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: isFull ? "Show the tools again" : "Use the whole right panel", action: onToggleFull)
            PanelHeaderButton(symbol: "xmark", help: "Close", action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var captureToggle: some View {
        Button {
            Task { if model.isRunning { await model.stop() } else { await model.start(routeMac: routesMac && device.platform == .ios && !device.isPhysical) } }
        } label: {
            Label(model.isRunning ? "Stop" : "Capture", systemImage: model.isRunning ? "stop.circle.fill" : "record.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.isRunning ? Color.red : Color.primary)
        }
        .controlSize(.small)
        .help(model.isRunning ? "Stop capturing and put the Mac's proxy settings back" : "Start the proxy")
    }

    @ViewBuilder
    private var statusText: some View {
        switch model.state {
        case .running(let port):
            Text(model.filter.isActive || model.limitsToDevice ? "\(model.visible.count) of \(model.totalCount) · :\(String(port))" : "\(model.totalCount) requests · :\(String(port))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
        case .stopped:
            Text("Press Capture to start").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Filters

    private func filterBar(filter: Binding<HTTPFilter>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: filter.query).textFieldStyle(.plain).font(.system(size: 12))
                if !filter.wrappedValue.query.isEmpty {
                    Button { filter.wrappedValue.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    ForEach(HTTPFilter.Scope.allCases, id: \.self) { scope in
                        Toggle(scope.title, isOn: Binding(
                            get: { filter.wrappedValue.scopes.contains(scope) },
                            set: { on in
                                if on { filter.wrappedValue.scopes.insert(scope) } else if filter.wrappedValue.scopes.count > 1 { filter.wrappedValue.scopes.remove(scope) }
                            }))
                    }
                    Divider()
                    Toggle("Regular expression", isOn: filter.isRegex)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("What the search looks at")
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filter.wrappedValue.isValid ? Color.clear : Color.red))

            Menu {
                ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { method in
                    Toggle(method, isOn: Binding(
                        get: { filter.wrappedValue.methods.contains(method) },
                        set: { on in if on { filter.wrappedValue.methods.insert(method) } else { filter.wrappedValue.methods.remove(method) } }))
                }
                Divider()
                Button("Any method") { filter.wrappedValue.methods = [] }
            } label: {
                Text(filter.wrappedValue.methods.isEmpty ? "Methods" : filter.wrappedValue.methods.sorted().joined(separator: ","))
            }
            .menuStyle(.borderlessButton).fixedSize()

            Menu {
                ForEach([(2, "2xx Success"), (3, "3xx Redirect"), (4, "4xx Client error"), (5, "5xx Server error"), (0, "Failed")], id: \.0) { item in
                    Toggle(item.1, isOn: Binding(
                        get: { filter.wrappedValue.statusClasses.contains(item.0) },
                        set: { on in if on { filter.wrappedValue.statusClasses.insert(item.0) } else { filter.wrappedValue.statusClasses.remove(item.0) } }))
                }
                Divider()
                Button("Any status") { filter.wrappedValue.statusClasses = [] }
            } label: {
                Text(filter.wrappedValue.statusClasses.isEmpty ? "Status" : filter.wrappedValue.statusClasses.sorted().map { $0 == 0 ? "failed" : "\($0)xx" }.joined(separator: ","))
            }
            .menuStyle(.borderlessButton).fixedSize()

            AppFilterButton(selection: filter.apps, apps: model.apps, yourApps: [], isFindingApp: false, message: nil,
                            onCurrentApp: {}, loadYourApps: {}, seenTitle: "Seen in the traffic", showsCurrentApp: false)

            Menu {
                Toggle("Only this device", isOn: Binding(get: { model.limitsToDevice }, set: { model.limitsToDevice = $0 }))
                Toggle("Hide tunnels", isOn: filter.hidesTunnels)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        let notReady = model.isRunning && !(model.deviceState.certificateInstalled && model.deviceState.proxyConfigured)
        if notReady || model.setupMessage != nil {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(model.setupMessage ?? "\(device.name) is not sending its traffic here yet.")
                    .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                if model.setupMessage == nil {
                    Button("Set Up") { Task { await model.setUp(device) } }.controlSize(.small).disabled(model.isWorking)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.orange.opacity(0.12))
            Divider()
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if model.visible.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(model.isRunning ? "Waiting for requests from \(device.name)…" : "Capture is off")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { flow in
                            FlowRow(flow: flow, layout: layout, isSelected: model.selectedFlowId == flow.id)
                                .id(flow.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedFlowId = flow.id }
                                .contextMenu { FlowActions(flow: flow, model: model) }
                        }
                    }
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onScrollPhaseChange { _, phase in scrollPhase = phase }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
                } action: { _, atEnd in
                    if scrollPhase == .interacting || scrollPhase == .decelerating { isAtBottom = atEnd }
                }
                .onChange(of: model.visible.last?.id) { _, last in
                    guard isAtBottom, let last else { return }
                    followTask?.cancel()
                    followTask = Task {
                        try? await Task.sleep(for: .milliseconds(60))
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onChange(of: scrollRequest) { _, _ in
                    isAtBottom = true
                    if let last = model.visible.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}

private struct FlowRow: View {
    let flow: HTTPFlow
    let layout: HTTPColumnLayout
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(layout.visible, id: \.self) { column in cell(column) }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.28) : (flow.state == .failed ? Color.red.opacity(0.08) : Color.clear))
    }

    @ViewBuilder
    private func cell(_ column: HTTPColumn) -> some View {
        let width = layout.width(of: column)
        switch column {
        case .id: Text("\(flow.id)").foregroundStyle(.secondary).frame(width: width, alignment: .leading)
        case .time: Text(layout.timeFormat.format(flow.timeText)).foregroundStyle(.secondary).frame(width: width, alignment: .leading)
        case .status: Text(flow.statusText).foregroundStyle(statusColor).frame(width: width, alignment: .leading)
        case .method: Text(flow.method).fontWeight(.semibold).frame(width: width, alignment: .leading)
        case .host: Text(flow.host).lineLimit(1).truncationMode(.middle).frame(width: width, alignment: .leading)
        case .path:
            Text(flow.isTunnel && flow.path.isEmpty ? "" : flow.path).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(flow.isHTTPS ? Color.primary : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .app: Text(flow.appName).foregroundStyle(.secondary).lineLimit(1).frame(width: width, alignment: .leading)
        case .type: Text(flow.kind).foregroundStyle(.secondary).lineLimit(1).frame(width: width, alignment: .leading)
        case .size:
            Text(flow.state == .waiting ? "" : FlowFormatter.sizeText(flow.responseBodySize)).foregroundStyle(.secondary)
                .frame(width: width, alignment: .trailing)
        case .duration:
            Text(FlowFormatter.durationText(flow.duration)).foregroundStyle(.secondary).frame(width: width, alignment: .trailing)
        }
    }

    private var statusColor: Color {
        guard let status = flow.status else { return flow.state == .failed ? .red : .secondary }
        switch status / 100 {
        case 2: return .green
        case 3: return .blue
        case 4: return .orange
        default: return .red
        }
    }
}

/// Copy, save and filter actions for one request, used by the context menu and the detail header.
struct FlowActions: View {
    let flow: HTTPFlow
    let model: NetworkViewModel

    var body: some View {
        Button("Copy URL") { copy(flow.urlString) }
        Button("Copy as cURL") { copy(FlowFormatter.curl(for: flow)) }
        Menu("Copy") {
            Button("Request Headers") { copy(FlowFormatter.headersText(flow.requestHeaders)) }
            Button("Response Headers") { copy(FlowFormatter.headersText(flow.responseHeaders)) }
            Button("Request Body") { copy(String(decoding: FlowFormatter.requestBody(of: flow), as: UTF8.self)) }
            Button("Response Body") { copy(String(decoding: FlowFormatter.responseBody(of: flow), as: UTF8.self)) }
            Button("Host") { copy(flow.host) }
        }
        .disabled(flow.isTunnel)
        Button("Save Response…") { save(FlowFormatter.responseBody(of: flow)) }
            .disabled(flow.responseBody.isEmpty)
        Divider()
        Button("Show Only \(flow.appName)") { model.filter.apps = [flow.appName] }
        Button("Search for \(flow.host)") { model.filter.query = flow.host }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FlowFormatter.suggestedFileName(for: flow)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}
