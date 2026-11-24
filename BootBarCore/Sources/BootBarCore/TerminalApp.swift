import AppKit
import Foundation

/// The terminal that opens for Shell and Logs actions.
public enum TerminalApp: Hashable, Sendable {
    case terminal, iterm, ghostty, kitty, wezterm, alacritty, warp
    /// Any other terminal that opens a `.command` file, by application name.
    case custom(String)

    public static let presets: [TerminalApp] = [.terminal, .iterm, .ghostty, .kitty, .wezterm, .alacritty, .warp]

    /// The stored form: a preset id, or `custom` together with `customName`.
    public var id: String {
        switch self {
        case .terminal: "terminal"
        case .iterm: "iterm"
        case .ghostty: "ghostty"
        case .kitty: "kitty"
        case .wezterm: "wezterm"
        case .alacritty: "alacritty"
        case .warp: "warp"
        case .custom: "custom"
        }
    }

    public init(id: String, customName: String = "") {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch id {
        case "iterm": self = .iterm
        case "ghostty": self = .ghostty
        case "kitty": self = .kitty
        case "wezterm": self = .wezterm
        case "alacritty": self = .alacritty
        case "warp": self = .warp
        case "custom" where !name.isEmpty: self = .custom(name)
        default: self = .terminal
        }
    }

    public var title: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        case .ghostty: "Ghostty"
        case .kitty: "kitty"
        case .wezterm: "WezTerm"
        case .alacritty: "Alacritty"
        case .warp: "Warp"
        case .custom(let name): name
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .kitty: "net.kovidgoyal.kitty"
        case .wezterm: "com.github.wez.wezterm"
        case .alacritty: "org.alacritty"
        case .warp: "dev.warp.Warp-Stable"
        case .custom: nil
        }
    }

    public var isInstalled: Bool {
        guard let bundleIdentifier else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Arguments for `/usr/bin/open` that run the executable script in this terminal.
    func openArguments(script: String) -> [String] {
        switch self {
        // these hand a .command file to the app, which runs it in a new window
        case .terminal: ["-a", "Terminal", script]
        case .iterm: ["-a", "iTerm", script]
        case .warp: ["-a", "Warp", script]
        case .custom(let name): ["-a", name, script]
        // these take the program to run on their command line, so they need a fresh instance
        case .ghostty: ["-na", "Ghostty", "--args", "-e", script]
        case .kitty: ["-na", "kitty", "--args", script]
        case .wezterm: ["-na", "WezTerm", "--args", "start", "--", script]
        case .alacritty: ["-na", "Alacritty", "--args", "-e", script]
        }
    }
}
