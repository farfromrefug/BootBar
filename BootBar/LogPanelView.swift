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
    }

    private func appsMenu(filter: Binding<LogFilter>) -> some View {
        Menu {
            Button("All apps") { filter.wrappedValue.apps = [] }
            Divider()
            ForEach(model.apps.prefix(60)) { app in
                Button {
                    if filter.wrappedValue.apps.contains(app.name) {
                        filter.wrappedValue.apps.remove(app.name)
                    } else {
                        filter.wrappedValue.apps.insert(app.name)
                    }
                } label: {
                    Label("\(app.name) (\(app.count))", systemImage: filter.wrappedValue.apps.contains(app.name) ? "checkmark" : "")
                }
            }
        } label: {
            let apps = filter.wrappedValue.apps
            Text(apps.isEmpty ? "All apps" : apps.count == 1 ? apps.first! : "\(apps.count) apps")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                    LogRow(entry: entry)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.time).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(entry.level.letter).fontWeight(.bold).foregroundStyle(color).frame(width: 10)
            Text(label)
                .foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .leading)
            Text(entry.message).foregroundStyle(entry.level >= .error ? Color.red : Color.primary).lineLimit(3)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The app, then the tag, unless the tag only repeats the app.
    private var label: String {
        entry.tag.isEmpty || entry.tag == entry.appName ? entry.appName : "\(entry.appName) \(entry.tag)"
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
