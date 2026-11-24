import Foundation

/// Touch, buttons and keys for an iOS simulator, through Baguette's `baguette input` (it drives the private
/// SimulatorKit HID surface Apple offers no public way to reach). One long-lived process per simulator: starting
/// one costs about a second.
public final class SimulatorInputSession: @unchecked Sendable {
    public enum Phase: String, Sendable { case down, move, up }

    public enum Button: String, Sendable {
        case home, lock
        case appSwitcher = "app-switcher"
        case volumeUp = "volume-up"
        case volumeDown = "volume-down"
        case action
    }

    private let executable: String
    private let udid: String
    private let runner: any ShellRunner
    private let settleAfterHeal: Duration
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var lastError: String?

    private static let executablePaths = ["/opt/homebrew/bin/baguette", "/usr/local/bin/baguette"]

    public init(executable: String, udid: String, runner: any ShellRunner = ProcessShellRunner(),
                settleAfterHeal: Duration = .seconds(4)) {
        self.executable = executable
        self.udid = udid
        self.runner = runner
        self.settleAfterHeal = settleAfterHeal
    }

    public static func locate(exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        executablePaths.first(where: exists)
    }

    /// True when Xcode 27's Device Hub has attached to the simulator: input then reports success and lands nowhere.
    public func isInputShadowed() async -> Bool {
        let output = try? await runner.run("/usr/bin/xcrun", ["simctl", "spawn", udid, "notifyutil", "-g",
                                                              "com.apple.coredevice.dtuhidd.active"])
        return output?.split(separator: " ").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "1" } ?? false
    }

    /// Starts the input process, first reclaiming the input surface when Device Hub shadows it
    /// (that restarts SpringBoard, which `baguette boot` does as well).
    public func start() async throws {
        if await isInputShadowed() {
            try await runner.run(executable, ["heal", "--udid", udid])
            // SpringBoard is restarting: touches sent before it is back are dropped
            try await Task.sleep(for: settleAfterHeal)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["input", "--udid", udid]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.noteAcks(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        try process.run()
        lock.withLock {
            self.process = process
            input = stdin.fileHandleForWriting
        }
    }

    public func stop() {
        let (process, input) = lock.withLock { (self.process, self.input) }
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        lock.withLock {
            self.process = nil
            self.input = nil
        }
    }

    /// The last failure Baguette reported for a gesture, if any.
    public var failure: String? { lock.withLock { lastError } }

    // MARK: Input

    /// Coordinates may be in any unit as long as `width` and `height` use the same one.
    public func touch(_ phase: Phase, x: Double, y: Double, width: Double, height: Double) {
        var message: [String: Any] = ["type": "touch1-\(phase.rawValue)", "x": x, "y": y, "width": width, "height": height]
        // a touch that starts in a band along an edge is a system gesture (home indicator, Lock Screen, Notification Center)
        if phase == .down {
            if y >= height * 0.97 { message["edge"] = "bottom" } else if y <= height * 0.02 { message["edge"] = "top" }
        }
        send(message)
    }

    public func press(_ button: Button) {
        send(["type": "button", "button": button.rawValue])
    }

    public func key(code: String, modifiers: [String] = []) {
        var message: [String: Any] = ["type": "key", "code": code]
        if !modifiers.isEmpty { message["modifiers"] = modifiers }
        send(message)
    }

    /// Printable US-ASCII; anything else belongs in `paste`.
    public func type(_ text: String) {
        send(["type": "type", "text": text])
    }

    /// Puts any unicode on the simulator's pasteboard and presses Cmd+V.
    public func paste(_ text: String) {
        send(["type": "paste", "text": text])
    }

    /// Copies the focused field's selection to the Mac clipboard.
    public func copy() {
        send(["type": "copy"])
    }

    func encode(_ message: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return nil }
        data.append(0x0a)
        return data
    }

    private func send(_ message: [String: Any]) {
        guard let data = encode(message), let input = lock.withLock({ input }) else { return }
        try? input.write(contentsOf: data)
    }

    private func noteAcks(_ data: Data) {
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) where line.contains("\"ok\":false") {
            lock.withLock { lastError = String(line) }
        }
    }
}

/// W3C `KeyboardEvent.code` names for the Mac keys that are not plain text.
public enum SimulatorKeyMap {
    public static let special: [UInt16: String] = [
        36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete", 48: "Tab", 53: "Escape",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp"
    ]

    /// Letters that Cmd turns into an edit shortcut the simulator should receive as keystrokes.
    public static func shortcutCode(for character: String) -> String? {
        guard character.count == 1, let scalar = character.unicodeScalars.first,
              ("a"..."z").contains(Character(scalar)) else { return nil }
        return "Key" + character.uppercased()
    }

    /// True when `type` can send it; everything else is pasted.
    public static func isTypable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value != 127 }
    }
}
