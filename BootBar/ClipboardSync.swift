import AppKit
import BootBarCore

/// Keeps the Mac clipboard and the mirrored device's clipboard in step while a mirror is open.
@MainActor
final class ClipboardSync {
    private var task: Task<Void, Never>?
    private var lastMacChangeCount = -1
    /// The text both sides agreed on last; stops a copy from bouncing back and forth.
    private var lastText: String?

    private static let maxLength = 200_000

    func stop() {
        task?.cancel()
        task = nil
        lastMacChangeCount = -1
        lastText = nil
    }

    /// Android through scrcpy: the Mac side is polled here, the device side arrives in `receive(fromDevice:)`.
    func startAndroid(_ session: ScrcpySession) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let text = self?.macTextIfChanged() { session.setClipboard(text) }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func receive(fromDevice text: String) {
        guard text != lastText, text.count <= Self.maxLength else { return }
        lastText = text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastMacChangeCount = pasteboard.changeCount
    }

    /// Simulators have no push channel, so both directions are polled.
    func startSimulator(_ device: Device, runner: any ShellRunner = ProcessShellRunner()) {
        stop()
        let tools = SimulatorTools(runner: runner)
        task = Task { [weak self] in
            while !Task.isCancelled {
                if self?.macTextIfChanged() != nil {
                    try? await tools.pushHostPasteboard(device)
                } else if let text = try? await tools.pasteboard(device), !text.isEmpty, text != self?.lastText,
                          text.count <= Self.maxLength {
                    try? await tools.pullPasteboard(device)
                    self?.noteSent(text)
                }
                try? await Task.sleep(for: .milliseconds(1200))
            }
        }
    }

    /// Records a paste the user triggered, so the poll does not send the same text again.
    func noteSent(_ text: String) {
        lastText = text
        lastMacChangeCount = NSPasteboard.general.changeCount
    }

    private func macTextIfChanged() -> String? {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastMacChangeCount else { return nil }
        lastMacChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty, text.count <= Self.maxLength,
              text != lastText else { return nil }
        lastText = text
        return text
    }
}

/// Mac key codes that map to Android keycodes; everything else is typed as text.
enum AndroidKeyMap {
    static let special: [UInt16: Int] = [
        36: 66, 76: 66,        // return, keypad enter -> ENTER
        51: 67, 117: 112,      // delete -> DEL, forward delete -> FORWARD_DEL
        48: 61,                // tab
        53: 4,                 // escape -> BACK
        123: 21, 124: 22, 125: 20, 126: 19,   // arrows -> DPAD
        115: 122, 119: 123,    // home / end -> MOVE_HOME / MOVE_END
        116: 92, 121: 93       // page up / down
    ]

    static let copy = 278
    static let cut = 277
    static let keyA = 29
    static let metaCtrl = 0x1000
}
