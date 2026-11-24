import SwiftUI

struct SettingsView: View {
    @AppStorage(Preferences.sdkPathKey) private var androidSdkPath = ""
    @AppStorage(Preferences.muteAudioKey) private var muteAudio = false
    @AppStorage(Preferences.extraArgumentsKey) private var extraArguments = ""
    @AppStorage(Preferences.captureDirectoryKey) private var captureDirectory = ""
    @AppStorage(Preferences.showPhysicalDevicesKey) private var showPhysicalDevices = true
    @AppStorage(Preferences.syncClipboardKey) private var syncClipboard = true
    @State private var launchModel = LaunchAtLoginModel()
    @State private var linkHandler = LinkHandlerModel()

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchModel.isEnabled },
                    set: { launchModel.set($0) }
                ))
                if let message = launchModel.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Android") {
                TextField("SDK Path", text: $androidSdkPath,
                          prompt: Text("/Users/you/Library/Android/sdk"))
                Text("Leave empty to auto-detect from $ANDROID_HOME, $ANDROID_SDK_ROOT, or ~/Library/Android/sdk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Physical devices") {
                Toggle("Show connected iPhones, iPads and Android phones", isOn: $showPhysicalDevices)
                Text("Uses adb and devicectl. Turn off to only list simulators and emulators.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mirror") {
                Toggle("Sync the clipboard with the mirrored device", isOn: $syncClipboard)
                Text("While a mirror is open, what you copy on the Mac is available to paste on the device and the other way round. Turn off if you copy secrets you do not want on a test device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Install links") {
                Toggle("Open expo-orbit:// links in BootBar", isOn: Binding(
                    get: { linkHandler.isDefault },
                    set: { linkHandler.setDefault($0) }))
                Text("EAS and Expo \"Open in Orbit\" links download the build and ask which device to install it on. Turn off to give the links back to Expo Orbit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = linkHandler.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Emulator launch") {
                Toggle("Start without sound", isOn: $muteAudio)
                Text("Adds -no-audio. Each device's menu then offers Start with Sound for a single launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Extra arguments", text: $extraArguments, prompt: Text("-gpu host -no-boot-anim"))
                Text("Passed to every emulator start, cold boot and wipe. Quote values containing spaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Screenshots & recordings") {
                HStack {
                    TextField("Save to", text: $captureDirectory, prompt: Text("~/Desktop"))
                    Button("Choose…") {
                        FilePicker.chooseDirectory { captureDirectory = $0 }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onAppear {
            launchModel.refresh()
            linkHandler.refresh()
        }
    }
}
