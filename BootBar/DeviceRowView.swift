import SwiftUI
import BootBarCore

struct DeviceRowView: View {
    @Environment(DeviceToolsViewModel.self) private var toolsModel
    @AppStorage(Preferences.muteAudioKey) private var muteAudio = false

    let device: Device
    let isBusy: Bool
    let error: String?
    let onAction: (DeviceAction) -> Void
    let onManage: () -> Void
    let onDelete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                deviceInfo
                Spacer(minLength: 8)
                trailing
            }
            if confirmingDelete {
                HStack(spacing: 8) {
                    Text("Delete \(device.name)?").font(.system(size: 11))
                    Spacer()
                    Button("Cancel") { confirmingDelete = false }
                    Button("Delete", role: .destructive) {
                        confirmingDelete = false
                        onDelete()
                    }
                }
                .controlSize(.small)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onManage)
    }

    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.name).font(.system(size: 13, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        "\(device.osVersion) · \(stateLabel)"
    }

    private var stateLabel: String {
        switch device.state {
        case .running: device.isPhysical ? "Connected" : "Running"
        case .booting: "Booting…"
        case .stopped: "Stopped"
        case .unavailable: device.statusNote ?? "Unavailable"
        }
    }

    private var stateColor: Color {
        switch device.state {
        case .running: .green
        case .booting: .orange
        case .stopped: Color(nsColor: .tertiaryLabelColor)
        case .unavailable: .red
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else {
            if !device.isPhysical { primaryActionButton }
            actionMenu
        }
    }

    private var primaryActionButton: some View {
        Button {
            onAction(device.state == .running ? .stop : .start)
        } label: {
            Image(systemName: device.state == .running ? "stop.fill" : "play.fill")
                .foregroundStyle(device.state == .booting ? Color.secondary : (device.state == .running ? Color.red : Color.blue))
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .disabled(device.state == .booting)
    }

    private var actionMenu: some View {
        Menu {
            if !device.isPhysical && device.state == .stopped {
                Button("Start Headless") { onAction(.startHeadless) }
            }
            if !device.isPhysical && device.platform == .android && device.state == .stopped {
                Button(muteAudio ? "Start with Sound" : "Start without Sound") {
                    onAction(.startWithAlternateAudio)
                }
            }
            if !device.isPhysical {
                Button("Cold Boot") { onAction(.coldBoot) }
                Button(device.platform == .ios ? "Erase" : "Wipe Data", role: .destructive) {
                    onAction(.erase)
                }
            }
            if device.state == .running {
                if !device.isPhysical { Divider() }
                if DeviceTool.screenshot.isSupported(for: device) {
                    Button("Screenshot") { runTool(.screenshot) }
                }
                if DeviceTool.startRecording.isSupported(for: device) {
                    if toolsModel.isRecording(device) {
                        Button("Stop Recording") { runTool(.stopRecording) }
                    } else {
                        Button("Start Recording") { runTool(.startRecording) }
                    }
                }
                if DeviceTool.appearance(dark: true).isSupported(for: device) {
                    Menu("Appearance") {
                        Button("Dark") { runTool(.appearance(dark: true)) }
                        Button("Light") { runTool(.appearance(dark: false)) }
                    }
                }
            }
            Divider()
            Button("Manage…", action: onManage)
            if !device.isPhysical {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(device.state != .stopped)
            }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
    }

    private func runTool(_ tool: DeviceTool) {
        Task { await toolsModel.perform(tool, on: device) }
    }
}
