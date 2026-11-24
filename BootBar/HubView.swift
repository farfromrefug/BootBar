import SwiftUI
import BootBarCore

/// Device-hub style window: devices on the left, an optional live mirror in the middle, management on the right.
struct HubView: View {
    @Environment(DeviceListViewModel.self) private var list
    @Environment(DeviceToolsViewModel.self) private var tools
    @Environment(DeviceManagementViewModel.self) private var management
    @Environment(HubRouter.self) private var router
    @Environment(InstallRequestCenter.self) private var installs
    @AppStorage("hubShowsMirror") private var showMirror = true
    @AppStorage("hubShowsInspector") private var showInspector = true
    @State private var dropTargeted = false
    @State private var window: NSWindow?
    @State private var fitTask: Task<Void, Never>?
    /// Width / height of the picture last shown; sizes the middle column so it has no black bars.
    @State private var aspect: CGFloat = 9.0 / 19.5
    @State private var creating: Platform?
    @State private var mirror = MirrorController()
    @State private var deleting: Device?

    var body: some View {
        @Bindable var router = router
        content(router: $router.selection)
            .frame(minHeight: 360)
    }

    private func content(router selection: Binding<String?>) -> some View {
        NavigationSplitView {
            sidebar(selection: selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New iOS Simulator…") { creating = .ios }
                    Button("New Android Emulator…") { creating = .android }
                } label: {
                    Label("New Device", systemImage: "plus")
                }
            }
            ToolbarItem {
                Toggle(isOn: $showMirror) {
                    Label("Mirror", systemImage: "rectangle.on.rectangle")
                }
                .toggleStyle(.button)
                .help("Show the live screen of the selected device")
            }
            ToolbarItem {
                Toggle(isOn: $showInspector) {
                    Label("Tools", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .help("Show or hide the tools panel. Hidden, the window shrinks to the device screen.")
            }
        }
        .task {
            while !Task.isCancelled {
                await list.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: router.selection) { _, _ in creating = nil }
        .background(WindowReader { window = $0 })
        // the app is a menu bar agent; while this window is open it also gets a Dock icon
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .sheet(item: Binding(get: { installs.pending.map(PendingInstall.init) }, set: { if $0 == nil { installs.pending = nil } })) {
            InstallRequestSheet(request: $0.request) { installs.pending = nil }
        }
        .confirmationDialog(deleting.map { "Delete \($0.name)?" } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { device in
            Button("Delete", role: .destructive) { delete(device) }
        } message: { _ in
            Text("This removes the device and its data. It cannot be undone.")
        }
    }

    private var selected: Device? { router.selection.flatMap { list.device(id: $0) } }

    // MARK: Sidebar

    private func sidebar(selection: Binding<String?>) -> some View {
        List(selection: selection) {
            deviceSection("iOS Simulators", list.iosDevices, error: list.iosError)
            deviceSection("Android Emulators", list.androidDevices, error: list.androidError)
            if !list.physicalDevices.isEmpty || list.physicalError != nil {
                deviceSection("Physical Devices", list.physicalDevices, error: list.physicalError)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func deviceSection(_ title: String, _ devices: [Device], error: String?) -> some View {
        Section(title) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                SidebarRow(device: device, isBusy: list.busyDeviceIds.contains(device.id))
                    .tag(device.id)
                    .contextMenu { contextMenu(for: device) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for device: Device) -> some View {
        if !device.isPhysical {
            if device.state == .running {
                Button("Stop") { Task { await list.perform(.stop, on: device) } }
            } else if device.state == .stopped {
                Button("Start") { Task { await list.perform(.start, on: device) } }
                if device.platform == .android {
                    Button("Start without/with Sound") { Task { await list.perform(.startWithAlternateAudio, on: device) } }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { deleting = device }
                .disabled(device.state != .stopped)
        }
    }

    private func delete(_ device: Device) {
        Task {
            if await management.delete(device) {
                if router.selection == device.id { router.selection = nil }
                await list.refresh()
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let platform = creating {
            CreateDeviceView(platform: platform, onDone: { creating = nil })
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        } else if let device = selected {
            GeometryReader { geometry in
                let mirrorWidth = mirrorColumnWidth(for: device, in: geometry.size)
                HStack(spacing: 0) {
                    if showMirror {
                        MirrorPane(device: device, controller: mirror)
                            .frame(width: mirrorWidth)
                        if showInspector { Divider() }
                    }
                    if showInspector || !showMirror {
                        VStack(spacing: 0) {
                            header(device)
                            Divider()
                            DeviceManageContent(device: device, onGone: { router.selection = nil })
                        }
                        .frame(minWidth: Self.inspectorMin, maxWidth: showMirror ? Self.inspectorMax : .infinity)
                        .background(.background.secondary)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .onChange(of: FitKey(width: geometry.size.width, mirror: mirrorWidth, inspector: showInspector, showsMirror: showMirror)) { _, key in
                    scheduleFit(detailWidth: key.width, mirrorWidth: key.mirror)
                }
                .onAppear { scheduleFit(detailWidth: geometry.size.width, mirrorWidth: mirrorWidth) }
            }
            .onChange(of: mirror.frameSize) { _, size in
                if let size, size.width > 0, size.height > 0 { aspect = size.width / size.height }
            }
            .overlay(alignment: .bottom) { toast(showsAlways: !(showInspector || !showMirror)) }
            .overlay(alignment: .topTrailing) {
                if tools.isWorking {
                    ProgressView().controlSize(.small).padding(8)
                        .background(.regularMaterial, in: Capsule()).padding(10)
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard device.state == .running else { return false }
                let paths = urls.filter(\.isFileURL).map(\.path)
                guard !paths.isEmpty else { return false }
                Task { await tools.drop(paths, on: device) }
                return true
            } isTargeted: { dropTargeted = $0 }
        } else {
            ContentUnavailableView("Select a device", systemImage: "iphone.gen3",
                                   description: Text("Pick a simulator, emulator or connected device on the left."))
        }
    }

    /// Result of the last action, for when the tools panel that normally shows it is hidden.
    @ViewBuilder
    private func toast(showsAlways: Bool) -> some View {
        if showsAlways, let message = tools.message {
            Text(message.text)
                .font(.system(size: 11))
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(message.isError ? Color.red : Color.primary)
                .padding(.bottom, 52)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(message.isError ? 8 : 4))
                    if tools.message == message { tools.dismissMessage() }
                }
        }
    }

    private static let inspectorMin: CGFloat = 340
    private static let inspectorMax: CGFloat = 480
    /// Height of the button strip under the picture; it is part of the column but not of the picture.
    static let barHeight: CGFloat = 36

    private struct FitKey: Equatable {
        let width: CGFloat
        let mirror: CGFloat
        let inspector: Bool
        let showsMirror: Bool
    }

    /// The picture is as wide as its height allows, so the column never shows black bars.
    private func mirrorColumnWidth(for device: Device, in size: CGSize) -> CGFloat {
        let bar = (device.platform == .android || !device.isPhysical) ? Self.barHeight : 0
        let width = max(max(size.height - bar, 120) * aspect, 240)
        let screenWidth = window?.screen?.visibleFrame.width ?? 1600
        let room = screenWidth - 260 - (showInspector ? Self.inspectorMin : 0)
        return min(width, max(room, 200))
    }

    /// Resizes the window so the middle column hugs the picture and the tools panel keeps a sensible width.
    private func scheduleFit(detailWidth: CGFloat, mirrorWidth: CGFloat) {
        fitTask?.cancel()
        guard showMirror else { return }
        fitTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let window, !window.styleMask.contains(.fullScreen) else { return }
            let lower = showInspector ? mirrorWidth + Self.inspectorMin : mirrorWidth
            let upper = showInspector ? mirrorWidth + Self.inspectorMax : mirrorWidth
            let delta = min(max(detailWidth, lower), upper) - detailWidth
            guard abs(delta) > 1.5 else { return }
            var frame = window.frame
            frame.size.width += delta
            if let visible = window.screen?.visibleFrame, frame.maxX > visible.maxX {
                frame.origin.x = max(visible.minX, visible.maxX - frame.width)
            }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func header(_ device: Device) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(of: device)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(device.osVersion) · \(label(of: device))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if !device.isPhysical, device.state == .running || device.state == .stopped {
                Button(device.state == .running ? "Stop" : "Start") {
                    Task { await list.perform(device.state == .running ? .stop : .start, on: device) }
                }
                .controlSize(.small)
                .disabled(list.busyDeviceIds.contains(device.id))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func label(of device: Device) -> String {
        switch device.state {
        case .running: device.isPhysical ? "Connected" : "Running"
        case .booting: "Booting…"
        case .stopped: "Stopped"
        case .unavailable: device.statusNote ?? "Unavailable"
        }
    }

    private func color(of device: Device) -> Color {
        SidebarRow.color(for: device.state)
    }
}

private struct PendingInstall: Identifiable {
    let request: InstallRequest
    var id: URL { request.url }
}

private struct SidebarRow: View {
    let device: Device
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Self.color(for: device.state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(device.osVersion).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if isBusy {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }

    static func color(for state: DeviceState) -> Color {
        switch state {
        case .running: .green
        case .booting: .orange
        case .stopped: Color(nsColor: .tertiaryLabelColor)
        case .unavailable: .red
        }
    }
}

// MARK: Mirror

private struct MirrorPane: View {
    let device: Device
    let controller: MirrorController
    @Environment(DeviceToolsViewModel.self) private var tools

    private var key: String { "\(device.id)|\(device.state)" }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                MirrorView(controller: controller)
                overlay
            }
            if device.platform == .android { controls } else if !device.isPhysical { simulatorBar }
        }
        .task(id: key) {
            controller.stop()
            if device.state == .running { controller.start(device) }
        }
        .onDisappear { controller.stop() }
    }

    @ViewBuilder
    private var overlay: some View {
        switch controller.state {
        case .idle:
            Text(device.state == .running ? "" : "Start the device to mirror it")
                .foregroundStyle(.white.opacity(0.6))
        case .starting:
            ProgressView().controlSize(.small).tint(.white)
        case .live:
            EmptyView()
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
                Button("Retry") { controller.start(device) }.controlSize(.small)
            }
            .padding()
        }
    }

    private var simulatorBar: some View {
        ViewThatFits(in: .horizontal) {
            simulatorButtons(compact: false)
            simulatorButtons(compact: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: HubView.barHeight)
        .background(.bar)
    }

    private func simulatorButtons(compact: Bool) -> some View {
        HStack(spacing: 14) {
            if controller.supportsInput {
                simulatorKey(.home, "circle", "Home")
                simulatorKey(.appSwitcher, "square.on.square", "App Switcher")
                simulatorKey(.lock, "power", "Lock")
                if !compact {
                    simulatorKey(.volumeDown, "speaker.wave.1", "Volume down")
                    simulatorKey(.volumeUp, "speaker.wave.3", "Volume up")
                }
            } else if let notice = controller.inputNotice, !compact {
                Text(notice).font(.system(size: 11))
            }
            if let engine = controller.engine, !compact {
                Text(engine).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Button("Open Simulator") { openSimulatorApp() }.controlSize(.small).buttonStyle(.bordered)
        }
        .fixedSize()
    }

    private func simulatorKey(_ button: SimulatorInputSession.Button, _ symbol: String, _ help: String) -> some View {
        Button { controller.press(button) } label: { Image(systemName: symbol) }.help(help)
    }

    private func openSimulatorApp() {
        for identifier in SimulatorHost.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            fullControls
            compactControls
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: HubView.barHeight)
        .background(.bar)
        .disabled(controller.state != .live)
    }

    private var compactControls: some View {
        HStack(spacing: 12) {
            key(.back, "chevron.left", "Back")
            key(.home, "circle", "Home")
            key(.appSwitch, "square", "Overview")
            Button { Task { await tools.perform(.screenshot, on: device) } } label: { Image(systemName: "camera") }
        }
    }

    private var fullControls: some View {
        HStack(spacing: 14) {
            key(.back, "chevron.left", "Back")
            key(.home, "circle", "Home")
            key(.appSwitch, "square", "Overview")
            Divider().frame(height: 16)
            key(.volumeDown, "speaker.wave.1", "Volume down")
            key(.volumeUp, "speaker.wave.3", "Volume up")
            key(.power, "power", "Power")
            Divider().frame(height: 16)
            if let engine = controller.engine {
                Text(engine).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if DeviceTool.rotate.isSupported(for: device) {
                Button { Task { await tools.perform(.rotate, on: device) } } label: { Image(systemName: "rotate.right") }
                    .help("Rotate")
            }
            Button { Task { await tools.perform(.screenshot, on: device) } } label: { Image(systemName: "camera") }
                .help("Screenshot")
        }
        .fixedSize()
    }

    private func key(_ key: AndroidInput.Key, _ symbol: String, _ help: String) -> some View {
        Button { controller.press(key) } label: { Image(systemName: symbol) }.help(help)
    }
}

// MARK: Install links

private struct InstallRequestSheet: View {
    let request: InstallRequest
    let onClose: () -> Void

    @Environment(DeviceListViewModel.self) private var list
    @Environment(DeviceToolsViewModel.self) private var tools
    @State private var targetId: String?
    @State private var started = false

    private var targets: [Device] {
        (list.iosDevices + list.androidDevices + list.physicalDevices).filter { device in
            guard device.state == .running else { return false }
            if let platform = request.platform, device.platform != platform { return false }
            let path = request.url.path.lowercased()
            if device.platform == .ios {
                if path.hasSuffix(".ipa") { return device.isPhysical }
                if path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") { return !device.isPhysical }
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install a build?").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.url.host ?? "").font(.system(size: 13, weight: .medium))
                Text(request.url.absoluteString).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3).textSelection(.enabled)
            }
            Text("A link asked BootBar to download this file and install it. Only continue if you trust its source.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if targets.isEmpty {
                Hint("No running device can take this build. Start a simulator, emulator or connect a device.")
            } else {
                Picker("Install on", selection: Binding(get: { selectedTarget?.id }, set: { targetId = $0 })) {
                    ForEach(targets) { Text("\($0.name) · \($0.osVersion)").tag(Optional($0.id)) }
                }
            }
            if let message = tools.message, started {
                Text(message.text).font(.system(size: 11)).foregroundStyle(message.isError ? Color.red : Color.green)
            }
            HStack {
                Spacer()
                Button(started && !tools.isWorking ? "Done" : "Cancel", action: onClose)
                Button("Download & Install", action: install)
                    .buttonStyle(.borderedProminent)
                    .disabled(tools.isWorking || selectedTarget == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { targetId = targets.first?.id }
    }

    private var selectedTarget: Device? {
        targets.first { $0.id == targetId } ?? targets.first
    }

    private func install() {
        guard let device = selectedTarget else { return }
        started = true
        Task { await tools.perform(.install(request.url.absoluteString), on: device) }
    }
}
