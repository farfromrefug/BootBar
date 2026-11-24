import AppKit
import BootBarCore
import SwiftUI

enum LogPanelMode: String {
    case hidden, split, full
}

/// The device log: search, level and app filters, and a live list that follows the tail.
struct LogPanelView: View {
    let device: Device
    let model: LogViewModel
    let isFull: Bool
    let onToggleFull: () -> Void
    let onClose: () -> Void

    @AppStorage("logColumnLayout") private var layoutJSON = ""
    @State private var showApps = false
    @State private var following = true
    @State private var selection: Set<Int> = []
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            filterBar(filter: $model.filter)
            Divider()
            columnHeader
            Divider()
            content
        }
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Label("Logs", systemImage: "text.alignleft").font(.system(size: 12, weight: .semibold))
            status
            Spacer()
            headerButton(model.isPaused ? "play.fill" : "pause.fill", model.isPaused ? "Resume" : "Pause") {
                model.isPaused.toggle()
            }
            headerButton("arrow.down.to.line", following ? "Stop following the newest line" : "Follow the newest line",
                         tint: following ? .accentColor : .secondary) { following.toggle() }
            headerButton("doc.on.doc", "Copy the visible lines") { copy(model.text()) }
            headerButton("trash", "Clear") { model.clear() }
            Divider().frame(height: 14)
            headerButton(isFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         isFull ? "Show the tools again" : "Use the whole right panel", action: onToggleFull)
            headerButton("xmark", "Close the log", action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .streaming:
            Text(model.filter.isActive ? "\(model.visible.count) of \(model.totalCount)" : "\(model.totalCount) lines")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.isPaused {
                Text("paused · \(model.queuedWhilePaused) waiting").font(.system(size: 11)).foregroundStyle(.orange)
            }
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
        case .idle:
            Text(device.state == .running ? "" : "Start the device to see its log")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func headerButton(_ symbol: String, _ help: String, tint: Color = .secondary,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).foregroundStyle(tint) }
            .buttonStyle(.plain)
            .help(help)
    }

    // MARK: Filters

    private func filterBar(filter: Binding<LogFilter>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: filter.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !filter.wrappedValue.query.isEmpty {
                    Button { filter.wrappedValue.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Toggle(isOn: filter.isRegex) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .help("Treat the search as a regular expression")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filter.wrappedValue.isValid ? Color.clear : Color.red))

            Menu {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Button {
                        filter.wrappedValue.minimumLevel = level
                    } label: {
                        Label(level.title, systemImage: filter.wrappedValue.minimumLevel == level ? "checkmark" : "")
                    }
                }
            } label: {
                Text(filter.wrappedValue.minimumLevel == .verbose ? "All levels" : "≥ \(filter.wrappedValue.minimumLevel.title)")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            appsMenu(filter: filter)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottomTrailing) {
            if let message = model.discoveryMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.trailing, 10).offset(y: 9)
            }
        }
    }

    private func appsMenu(filter: Binding<LogFilter>) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.filterToCurrentApp() }
            } label: {
                if model.isFindingApp {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "scope")
                }
            }
            .buttonStyle(.plain)
            .help("Show only the app in the foreground")

            Button { showApps.toggle() } label: {
                let apps = filter.wrappedValue.apps
                HStack(spacing: 3) {
                    Text(apps.isEmpty ? "All apps" : apps.count == 1 ? apps.first! : "\(apps.count) apps")
                        .lineLimit(1)
                        .frame(maxWidth: 140)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showApps, arrowEdge: .bottom) {
                AppFilterPopover(model: model)
            }
        }
    }

    // MARK: Columns

    private var layout: LogColumnLayout {
        get { LogColumnLayout(json: layoutJSON) ?? LogColumnLayout() }
        nonmutating set { layoutJSON = newValue.json }
    }

    private var columnHeader: some View {
        let layout = layout
        return HStack(spacing: 6) {
            ForEach(layout.visible, id: \.self) { column in
                headerCell(column, layout: layout)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .background(.quaternary.opacity(0.5))
        .contextMenu {
            ForEach(LogColumn.allCases.filter { $0 != .message }, id: \.self) { column in
                Toggle(column.title, isOn: Binding(
                    get: { !layout.hidden.contains(column) },
                    set: { value in
                        var updated = layout
                        updated.setVisible(column, value)
                        self.layout = updated
                    }))
            }
            Divider()
            Picker("Time format", selection: Binding(
                get: { layout.timeFormat },
                set: { value in
                    var updated = layout
                    updated.timeFormat = value
                    self.layout = updated
                })) {
                ForEach(LogTimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Reset Columns") { self.layout = LogColumnLayout() }
        }
    }

    @ViewBuilder
    private func headerCell(_ column: LogColumn, layout: LogColumnLayout) -> some View {
        let isMessage = column == .message
        HStack(spacing: 0) {
            Text(column.headerTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !isMessage {
                ColumnResizeHandle(width: layout.width(of: column)) { width in
                    var updated = layout
                    updated.resize(column, to: width)
                    self.layout = updated
                }
            }
        }
        .frame(width: isMessage ? nil : layout.width(of: column))
        .frame(maxWidth: isMessage ? .infinity : nil, alignment: .leading)
        .draggable(column.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = LogColumn(rawValue: raw) else { return false }
            var updated = layout
            updated.move(dragged, to: column)
            self.layout = updated
            return true
        }
        .contextMenu {
            if !isMessage {
                Button("Hide \(column.title)") {
                    var updated = layout
                    updated.setVisible(column, false)
                    self.layout = updated
                }
            }
        }
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if model.visible.isEmpty {
            VStack {
                Spacer()
                Text(emptyText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(model.visible, selection: $selection) { entry in
                    LogRow(entry: entry, layout: layout)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                        .contextMenu { contextMenu(for: entry) }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 16)
                .onChange(of: model.visible.last?.id) { _, last in
                    guard following, let last else { return }
                    scrollTask?.cancel()
                    // lines can arrive faster than they can be drawn, so scroll once per pause
                    scrollTask = Task {
                        try? await Task.sleep(for: .milliseconds(80))
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onCopyCommand {
                    let lines = model.visible.filter { selection.contains($0.id) }.map(\.line).joined(separator: "\n")
                    return lines.isEmpty ? [] : [NSItemProvider(object: lines as NSString)]
                }
            }
        }
    }

    private var emptyText: String {
        if model.state == .streaming, model.totalCount > 0 { return "No line matches the filter" }
        return model.state == .streaming ? "Waiting for log lines…" : ""
    }

    @ViewBuilder
    private func contextMenu(for entry: LogEntry) -> some View {
        Button("Copy Line") { copy(entry.line) }
        Button("Copy Message") { copy(entry.message) }
        Divider()
        Button("Show Only \(entry.appName)") { model.filter.apps = [entry.appName] }
        Button("Hide \(entry.appName)") {
            model.filter.apps = Set(model.apps.map(\.name)).subtracting([entry.appName])
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let layout: LogColumnLayout

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(layout.visible, id: \.self) { column in
                cell(column)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ column: LogColumn) -> some View {
        switch column {
        case .time:
            Text(layout.timeFormat.format(entry.time)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: layout.width(of: .time), alignment: .leading)
        case .level:
            Text(entry.level.letter).fontWeight(.bold).foregroundStyle(color)
                .frame(width: layout.width(of: .level), alignment: .leading)
        case .app:
            Text(entry.appName).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: layout.width(of: .app), alignment: .leading)
        case .tag:
            Text(entry.tag).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: layout.width(of: .tag), alignment: .leading)
        case .pid:
            Text(entry.pid.map(String.init) ?? "").foregroundStyle(.secondary).lineLimit(1)
                .frame(width: layout.width(of: .pid), alignment: .leading)
        case .message:
            Text(entry.message).foregroundStyle(entry.level >= .error ? Color.red : Color.primary).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var color: Color {
        switch entry.level {
        case .verbose, .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error, .fault: .red
        }
    }
}

/// Drag the right edge of a column header to resize that column.
private struct ColumnResizeHandle: View {
    let width: Double
    let onResize: (Double) -> Void
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: 12)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        onResize(start + value.translation.width)
                    }
                    .onEnded { _ in startWidth = nil })
    }
}

/// Pick the apps to show: the foreground app on top, then your apps, then everything seen in the log.
/// The list is alphabetical and bounded, so it does not jump around while lines stream in.
private struct AppFilterPopover: View {
    let model: LogViewModel
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await model.filterToCurrentApp() }
                } label: {
                    Label("Current app", systemImage: "scope")
                }
                .controlSize(.small)
                .disabled(model.isFindingApp)
                if model.isFindingApp { ProgressView().controlSize(.mini) }
                Spacer()
                Button("All apps") { model.filter.apps = [] }
                    .controlSize(.small)
                    .disabled(model.filter.apps.isEmpty)
            }
            if let message = model.discoveryMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
            }
            TextField("Find an app", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !yours.isEmpty {
                        sectionTitle("Your apps")
                        ForEach(yours, id: \.self) { row($0, count: nil) }
                    }
                    sectionTitle("Seen in the log")
                    ForEach(seen, id: \.name) { row($0.name, count: $0.count) }
                }
            }
            .frame(height: 300)
        }
        .padding(12)
        .frame(width: 320)
        .task { await model.loadYourApps() }
    }

    private var yours: [String] {
        model.yourApps.filter { matches($0) }
    }

    private var seen: [LogViewModel.AppCount] {
        model.apps.filter { matches($0.name) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func row(_ name: String, count: Int?) -> some View {
        Toggle(isOn: Binding(
            get: { model.filter.apps.contains(name) },
            set: { on in
                if on { model.filter.apps.insert(name) } else { model.filter.apps.remove(name) }
            })) {
            HStack {
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let count { Text("\(count)").foregroundStyle(.tertiary).font(.system(size: 10)) }
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }
}

/// A thin bar between the tools and the log that resizes the log when dragged.
struct LogResizeHandle: View {
    @Binding var height: Double
    let available: Double
    @State private var startHeight: Double?

    var body: some View {
        ZStack {
            Divider()
            Capsule().fill(.tertiary).frame(width: 36, height: 3)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startHeight ?? height
                    startHeight = start
                    height = min(max(start - value.translation.height, 120), max(available - 160, 120))
                }
                .onEnded { _ in startHeight = nil })
    }
}
