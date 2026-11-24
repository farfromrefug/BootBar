import SwiftUI
import BootBarCore

@main
struct BootBarApp: App {
    @State private var viewModel: DeviceListViewModel
    @State private var toolsModel = DeviceToolsViewModel(
        captureDirectory: { Preferences.captureDirectory },
        locateSDK: { Preferences.locateSDK() })
    @State private var managementModel = DeviceManagementViewModel { Preferences.locateSDK() }

    init() {
        Preferences.registerDefaults()
        _viewModel = State(initialValue: DeviceListViewModel(
            launchOptions: { Preferences.androidLaunchOptions },
            showPhysicalDevices: { Preferences.showPhysicalDevices },
            locateSDK: { Preferences.locateSDK() }))
    }

    var body: some Scene {
        MenuBarExtra("BootBar", systemImage: "iphone.gen3") {
            MenuBarPanelView()
                .environment(viewModel)
                .environment(toolsModel)
                .environment(managementModel)
                .frame(width: 340, height: 560)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
