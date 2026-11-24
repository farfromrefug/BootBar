import AppKit

/// Whether BootBar is the registered handler of `expo-orbit://` links.
@MainActor
@Observable
final class LinkHandlerModel {
    private static let scheme = "expo-orbit"
    private static let orbitBundleId = "dev.expo.orbit"

    private(set) var isDefault = false
    private(set) var errorMessage: String?

    init() { refresh() }

    func refresh() {
        isDefault = currentHandler() == Bundle.main.bundleIdentifier
    }

    func setDefault(_ enabled: Bool) {
        errorMessage = nil
        guard let target = enabled ? Bundle.main.bundleURL : orbitURL() else {
            errorMessage = "Expo Orbit is not installed"
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: target, toOpenURLsWithScheme: Self.scheme) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if let error {
                    self.errorMessage = error.localizedDescription
                } else if enabled && !self.isDefault {
                    // LaunchServices ignores apps outside the Applications folders (a build run from Xcode, for one)
                    self.errorMessage = "macOS only sends links to apps in /Applications or ~/Applications. Move BootBar there and try again."
                }
            }
        }
    }

    private func orbitURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.orbitBundleId)
    }

    private func currentHandler() -> String? {
        guard let url = URL(string: "\(Self.scheme)://"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}
