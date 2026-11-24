import SwiftUI
import BootBarCore

struct CreateDeviceView: View {
    let platform: Platform
    let onDone: () -> Void

    @Environment(DeviceListViewModel.self) private var listModel
    @Environment(DeviceManagementViewModel.self) private var management
    @State private var name = ""
    @State private var nameEdited = false
    @State private var runtimeId: String?
    @State private var deviceTypeId: String?
    @State private var imageId: String?
    @State private var definitionId: String?
    @State private var hardware = AvdHardwareOptions()

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: platform == .ios ? "New iOS Simulator" : "New Android Emulator", onBack: onDone)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if management.isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        form
                    }
                    if let error = management.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
                .padding(14)
            }
        }
        .task {
            management.dismissError()
            await management.loadOptions(for: platform)
            selectDefaults()
        }
    }

    @ViewBuilder
    private var form: some View {
        TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
            .textFieldStyle(.roundedBorder)
        if platform == .ios {
            iosPickers
        } else {
            androidPickers
        }
        HStack {
            Spacer()
            Button("Cancel", action: onDone)
            Button("Create", action: create)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate || management.isWorking)
        }
        if management.isWorking { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
    }

    @ViewBuilder
    private var iosPickers: some View {
        if management.runtimes.isEmpty {
            Hint("No iOS runtimes installed. Add one in Xcode → Settings → Components.")
        } else {
            Picker("Runtime", selection: Binding(get: { runtimeId }, set: { runtimeId = $0; pickDeviceType() })) {
                ForEach(management.runtimes) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Device", selection: $deviceTypeId) {
                ForEach(selectedRuntime.map(management.deviceTypes(for:)) ?? []) { Text($0.name).tag(Optional($0.id)) }
            }
            .onChange(of: deviceTypeId) { _, _ in suggestName() }
        }
    }

    @ViewBuilder
    private var androidPickers: some View {
        if management.systemImages.isEmpty {
            Hint("No system images installed. Install one from Android Studio → SDK Manager → SDK Platforms.")
        } else {
            Picker("System image", selection: Binding(get: { imageId }, set: { imageId = $0; pickDefinition() })) {
                ForEach(management.systemImages) { Text("\($0.title) · \($0.abi)").tag(Optional($0.id)) }
            }
            Picker("Device", selection: $definitionId) {
                ForEach(selectedImage.map(management.definitions(for:)) ?? []) { Text($0.name).tag(Optional($0.id)) }
            }
            .onChange(of: definitionId) { _, _ in suggestName() }
            DisclosureGroup("Advanced options") {
                AvdOptionsForm(options: $hardware, includesSdCard: true).padding(.top, 8)
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    private var selectedRuntime: SimulatorRuntime? { management.runtimes.first { $0.id == runtimeId } }
    private var selectedDeviceType: SimulatorDeviceType? { management.deviceTypes.first { $0.id == deviceTypeId } }
    private var selectedImage: SystemImage? { management.systemImages.first { $0.id == imageId } }
    private var selectedDefinition: AvdDeviceDefinition? {
        management.deviceDefinitions.first { $0.id == definitionId }
    }

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return platform == .ios
            ? selectedRuntime != nil && selectedDeviceType != nil
            : selectedImage != nil && selectedDefinition != nil
    }

    private func selectDefaults() {
        if platform == .ios {
            runtimeId = management.runtimes.first?.id
            pickDeviceType()
        } else {
            imageId = management.systemImages.first?.id
            pickDefinition()
        }
    }

    private func pickDeviceType() {
        let options = selectedRuntime.map(management.deviceTypes(for:)) ?? []
        if !options.contains(where: { $0.id == deviceTypeId }) {
            deviceTypeId = (options.first { $0.name.hasPrefix("iPhone") } ?? options.first)?.id
        }
        suggestName()
    }

    private func pickDefinition() {
        let options = selectedImage.map(management.definitions(for:)) ?? []
        if !options.contains(where: { $0.id == definitionId }) {
            definitionId = (options.first { $0.id == "pixel_8" } ?? options.first)?.id
        }
        suggestName()
    }

    private func suggestName() {
        guard !nameEdited else { return }
        if platform == .ios, let type = selectedDeviceType {
            name = type.name
        } else if let image = selectedImage, let definition = selectedDefinition {
            name = "\(definition.name)_API_\(image.apiLevel)"
                .map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Task {
            let created: Bool
            if platform == .ios, let runtime = selectedRuntime, let type = selectedDeviceType {
                created = await management.createSimulator(name: trimmed, deviceType: type, runtime: runtime)
            } else if let image = selectedImage, let definition = selectedDefinition {
                created = await management.createEmulator(name: trimmed, image: image, definition: definition,
                                                          options: hardware)
            } else {
                return
            }
            if created {
                await listModel.refresh()
                onDone()
            }
        }
    }
}
