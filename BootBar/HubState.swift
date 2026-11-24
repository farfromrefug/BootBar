import AppKit
import BootBarCore
import SwiftUI

/// Which device the BootBar window shows; set by the popover when it hands over.
@MainActor
@Observable
final class HubRouter {
    private static let key = "hubSelection"

    /// Remembered between launches.
    var selection: String? = UserDefaults.standard.string(forKey: HubRouter.key) {
        didSet { UserDefaults.standard.set(selection, forKey: Self.key) }
    }
}

/// A build to install, arriving through an `expo-orbit://` or `bootbar://` link.
@MainActor
@Observable
final class InstallRequestCenter {
    static let shared = InstallRequestCenter()

    var pending: InstallRequest?
    /// Bumped on every link so the menu bar label can open the window.
    private(set) var openCount = 0

    func receive(_ request: InstallRequest) {
        pending = request
        openCount += 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The camera is injected into the simulator's launchd environment, so leaving it armed would outlive the app.
    func applicationWillTerminate(_ notification: Notification) {
        VirtualCameraViewModel.disarmForQuit()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = InstallLink.parse(url) else { continue }
            Task { @MainActor in InstallRequestCenter.shared.receive(request) }
        }
    }
}

/// Menu bar icon. It lives as long as the app, so it is where link-triggered windows get opened.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let center: InstallRequestCenter

    var body: some View {
        Image(systemName: "iphone.gen3")
            .onChange(of: center.openCount) { _, _ in
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "hub")
            }
    }
}
