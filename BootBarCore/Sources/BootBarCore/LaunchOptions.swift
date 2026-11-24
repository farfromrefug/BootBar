import Foundation

public struct AndroidLaunchOptions: Sendable, Equatable {
    public var muteAudio: Bool
    public var extraArguments: String

    public init(muteAudio: Bool = false, extraArguments: String = "") {
        self.muteAudio = muteAudio
        self.extraArguments = extraArguments
    }

    /// Arguments appended after `-avd <name>`. `muted` overrides the global `muteAudio` for one launch.
    public func arguments(muted: Bool? = nil) -> [String] {
        let silent = muted ?? muteAudio
        let extras = ArgumentSplitter.split(extraArguments)
        guard silent else { return extras.filter { !Self.audioFlags.contains($0) } }
        return ["-no-audio"] + extras.filter { !Self.audioFlags.contains($0) }
    }

    private static let audioFlags: Set<String> = ["-no-audio", "-noaudio"]
}

/// Splits a user-typed command line into arguments, honouring quotes and backslash escapes.
public enum ArgumentSplitter {
    public static func split(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" && quote != "'" {
                escaping = true
                inToken = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inToken = true
            } else if character.isWhitespace {
                if inToken { arguments.append(current) }
                current = ""
                inToken = false
            } else {
                current.append(character)
                inToken = true
            }
        }
        if inToken { arguments.append(current) }
        return arguments
    }
}

/// Quotes a value for the remote shell `adb shell` runs on the device.
enum RemoteShell {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
