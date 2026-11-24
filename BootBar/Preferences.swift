import Foundation
import BootBarCore

nonisolated enum Preferences {
    static let sdkPathKey = "androidSdkPath"
    static let muteAudioKey = "androidMuteAudio"
    static let extraArgumentsKey = "androidExtraArguments"
    static let captureDirectoryKey = "captureDirectory"
    static let showPhysicalDevicesKey = "showPhysicalDevices"
    static let syncClipboardKey = "syncClipboard"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [showPhysicalDevicesKey: true, syncClipboardKey: true])
    }

    static var showPhysicalDevices: Bool { UserDefaults.standard.bool(forKey: showPhysicalDevicesKey) }

    static var syncClipboard: Bool { UserDefaults.standard.bool(forKey: syncClipboardKey) }

    static var androidLaunchOptions: AndroidLaunchOptions {
        let defaults = UserDefaults.standard
        return AndroidLaunchOptions(muteAudio: defaults.bool(forKey: muteAudioKey),
                                    extraArguments: defaults.string(forKey: extraArgumentsKey) ?? "")
    }

    static var captureDirectory: String {
        let stored = UserDefaults.standard.string(forKey: captureDirectoryKey) ?? ""
        return stored.isEmpty ? NSHomeDirectory() + "/Desktop" : (stored as NSString).expandingTildeInPath
    }

    static func locateSDK() -> AndroidSDK? {
        SDKLocator(override: UserDefaults.standard.string(forKey: sdkPathKey)).locate()
    }
}
