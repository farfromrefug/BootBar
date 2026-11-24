import Foundation

/// A request to install a build, carried by a `expo-orbit://` or `deckhand://` link.
public struct InstallRequest: Equatable, Sendable {
    public let url: URL
    /// Known from the link or the file name; nil when the build could be for either platform.
    public let platform: Platform?

    public init(url: URL, platform: Platform?) {
        self.url = url
        self.platform = platform
    }
}

public enum InstallLink {
    public static let schemes: Set<String> = ["expo-orbit", "deckhand"]

    /// `expo-orbit:///download?url=https://…/build.tar.gz`, with or without the empty host and with
    /// `download`, `install` or no action at all.
    public static func parse(_ link: URL) -> InstallRequest? {
        guard let scheme = link.scheme?.lowercased(), schemes.contains(scheme),
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = ["url", "buildUrl", "artifactUrl", "build_url"].lazy
            .compactMap { name in items.first { $0.name == name }?.value }.first
        guard let value, let target = URL(string: value),
              let targetScheme = target.scheme?.lowercased(), targetScheme == "https" || targetScheme == "http"
        else { return nil }
        let declared = items.first { $0.name == "platform" }?.value.flatMap { Platform(rawValue: $0.lowercased()) }
        return InstallRequest(url: target, platform: declared ?? platform(of: target))
    }

    static func platform(of url: URL) -> Platform? {
        let path = url.path.lowercased()
        if path.hasSuffix(".apk") || path.hasSuffix(".aab") || path.hasSuffix(".apks") { return .android }
        if path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") || path.hasSuffix(".ipa") || path.hasSuffix(".app") {
            return .ios
        }
        return nil
    }
}
