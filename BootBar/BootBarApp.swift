import SwiftUI
import BootBarCore

@main
struct BootBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel: DeviceListViewModel
    @State private var toolsModel = DeviceToolsViewModel(
        captureDirectory: { Preferences.captureDirectory },
        locateSDK: { Preferences.locateSDK() })
    @State private var managementModel = DeviceManagementViewModel { Preferences.locateSDK() }
    @State private var cameraModel = VirtualCameraViewModel()
    @State private var hubRouter = HubRouter()
    @State private var installCenter = InstallRequestCenter.shared

    init() {
        Preferences.registerDefaults()
        _viewModel = State(initialValue: DeviceListViewModel(
            launchOptions: { Preferences.androidLaunchOptions },
            showPhysicalDevices: { Preferences.showPhysicalDevices },
            locateSDK: { Preferences.locateSDK() }))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView()
                .environment(viewModel)
                .environment(toolsModel)
                .environment(managementModel)
                .environment(cameraModel)
                .environment(hubRouter)
                .frame(width: 340, height: 560)
        } label: {
            MenuBarLabel(center: installCenter)
        }
        .menuBarExtraStyle(.window)

        Window("BootBar", id: "hub") {
            HubView()
                .environment(viewModel)
                .environment(toolsModel)
                .environment(managementModel)
                .environment(cameraModel)
                .environment(hubRouter)
                .environment(installCenter)
        }
        .defaultSize(width: 1180, height: 720)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
        }
    }
}
