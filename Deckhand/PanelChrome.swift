import AppKit
import DeckhandCore
import SwiftUI

/// Which panel the bottom of the right column shows.
enum PanelKind: String {
    case logs, network
}

enum PanelMode: String {
    case hidden, split, full
}

/// Switches the bottom panel between the log and the network traffic.
struct PanelKindPicker: View {
    @Binding var kind: PanelKind

    var body: some View {
        Picker("", selection: $kind) {
            Text("Logs").tag(PanelKind.logs)
            Text("Network").tag(PanelKind.network)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .controlSize(.small)
    }
}

// MARK: Columns

/// Column titles for a table-like panel: drag to reorder, drag the edge to resize, right-click to hide columns.
struct PanelColumnHeader<Column: PanelColumn>: View {
    @Binding var layout: ColumnLayout<Column>
    var showsTimeFormat = false

    var body: some View {
        let layout = layout
        HStack(spacing: 6) {
            ForEach(layout.visible, id: \.self) { column in
                cell(column, layout: layout)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .background(.quaternary.opacity(0.5))
        .contextMenu {
            ForEach(Column.allCases.filter { !$0.isFlexible }, id: \.self) { column in
                Toggle(column.title, isOn: Binding(
                    get: { !layout.hidden.contains(column) },
                    set: { value in
                        var updated = layout
                        updated.setVisible(column, value)
                        self.layout = updated
                    }))
            }
            if showsTimeFormat {
                Divider()
                Picker("Time format", selection: Binding(
                    get: { layout.timeFormat },
                    set: { value in
                        var updated = layout
                        updated.timeFormat = value
                        self.layout = updated
                    })) {
                    ForEach(TimeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Divider()
            Button("Reset Columns") { self.layout = ColumnLayout() }
        }
    }

    @ViewBuilder
    private func cell(_ column: Column, layout: ColumnLayout<Column>) -> some View {
        HStack(spacing: 0) {
            Text(column.headerTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !column.isFlexible {
                ColumnResizeHandle(width: layout.width(of: column)) { width in
                    var updated = layout
                    updated.resize(column, to: width)
                    self.layout = updated
                }
            }
        }
        .frame(width: column.isFlexible ? nil : layout.width(of: column))
        .frame(maxWidth: column.isFlexible ? .infinity : nil, alignment: .leading)
        .draggable(column.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = Column(rawValue: raw) else { return false }
            var updated = layout
            updated.move(dragged, to: column)
            self.layout = updated
            return true
        }
        .contextMenu {
            if !column.isFlexible {
                Button("Hide \(column.title)") {
                    var updated = layout
                    updated.setVisible(column, false)
                    self.layout = updated
                }
            }
        }
    }
}

/// Drag the right edge of a column header to resize that column.
struct ColumnResizeHandle: View {
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

// MARK: Apps

/// Pick the apps to show: the foreground app on top, then your apps, then everything seen. The list is
/// alphabetical and bounded, so it does not jump around while entries stream in.
struct AppFilterPopover: View {
    let apps: [AppCount]
    let yourApps: [String]
    @Binding var selection: Set<String>
    let isFindingApp: Bool
    let message: String?
    let onCurrentApp: () -> Void
    let loadYourApps: () async -> Void
    var seenTitle = "Seen in the log"
    var showsCurrentApp = true
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if showsCurrentApp {
                    Button(action: onCurrentApp) {
                        Label("Current app", systemImage: "scope")
                    }
                    .controlSize(.small)
                    .disabled(isFindingApp)
                    if isFindingApp { ProgressView().controlSize(.mini) }
                }
                Spacer()
                Button("All apps") { selection = [] }
                    .controlSize(.small)
                    .disabled(selection.isEmpty)
            }
            if let message {
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
                    sectionTitle(seenTitle)
                    ForEach(seen, id: \.name) { row($0.name, count: $0.count) }
                }
            }
            .frame(height: 300)
        }
        .padding(12)
        .frame(width: 320)
        .task { await loadYourApps() }
    }

    private var yours: [String] { yourApps.filter(matches) }

    private var seen: [AppCount] {
        apps.filter { matches($0.name) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }

    private func row(_ name: String, count: Int?) -> some View {
        Toggle(isOn: Binding(
            get: { selection.contains(name) },
            set: { on in
                if on { selection.insert(name) } else { selection.remove(name) }
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

/// The button that opens `AppFilterPopover`, with the target shortcut next to it.
struct AppFilterButton: View {
    @Binding var selection: Set<String>
    let apps: [AppCount]
    let yourApps: [String]
    let isFindingApp: Bool
    let message: String?
    let onCurrentApp: () -> Void
    let loadYourApps: () async -> Void
    var seenTitle = "Seen in the log"
    var showsCurrentApp = true
    @State private var showing = false

    var body: some View {
        HStack(spacing: 6) {
            if showsCurrentApp {
                Button(action: onCurrentApp) {
                    if isFindingApp {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "scope")
                    }
                }
                .buttonStyle(.plain)
                .help("Show only the app in the foreground")
            }

            Button { showing.toggle() } label: {
                HStack(spacing: 3) {
                    Text(selection.isEmpty ? "All apps" : selection.count == 1 ? selection.first! : "\(selection.count) apps")
                        .lineLimit(1)
                        .frame(maxWidth: 140)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AppFilterPopover(apps: apps, yourApps: yourApps, selection: $selection, isFindingApp: isFindingApp,
                                 message: message, onCurrentApp: onCurrentApp, loadYourApps: loadYourApps,
                                 seenTitle: seenTitle, showsCurrentApp: showsCurrentApp)
            }
        }
    }
}

// MARK: Layout

/// A thin bar between the tools and a panel that resizes the panel when dragged.
struct PanelResizeHandle: View {
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

/// An icon button for a panel header.
struct PanelHeaderButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).foregroundStyle(tint) }
            .buttonStyle(.plain)
            .help(help)
    }
}
