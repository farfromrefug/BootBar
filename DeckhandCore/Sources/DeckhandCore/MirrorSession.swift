import CoreMedia
import Foundation

/// Live view of an Android screen (emulator or physical) decoded from `screenrecord`'s H.264 stream.
public final class AndroidMirrorSession: @unchecked Sendable {
    public struct Geometry: Sendable, Equatable {
        public let width: Int
        public let height: Int
    }

    private let streamer: any ByteStreaming
    private let runner: any ShellRunner
    private let sdk: AndroidSDK
    private let serial: String
    private let maxDimension: Int
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(streamer: any ByteStreaming = ProcessByteStreamer(), runner: any ShellRunner = ProcessShellRunner(),
                sdk: AndroidSDK, serial: String, maxDimension: Int = 1280) {
        self.streamer = streamer
        self.runner = runner
        self.sdk = sdk
        self.serial = serial
        self.maxDimension = maxDimension
    }

    /// `onEnd` receives an error message when the stream could not be started or died immediately.
    public func start(onFrame: @escaping @Sendable (VideoFrame) -> Void,
                      onEnd: @escaping @Sendable (String?) -> Void) {
        lock.withLock {
            task?.cancel()
            task = Task { [self] in await run(onFrame: onFrame, onEnd: onEnd) }
        }
    }

    public func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    /// Physical screen size in the device's current orientation.
    public func screenSize() async -> Geometry? {
        guard let output = try? await runner.run(sdk.adbPath, ["-s", serial, "shell", "wm", "size"]) else { return nil }
        return Self.parseWindowSize(output)
    }

    static func parseWindowSize(_ output: String) -> Geometry? {
        // "Physical size: 1080x2400" and, when overridden, "Override size: 720x1600" (the override wins)
        var found: Geometry?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: #"\d+x\d+"#, options: .regularExpression) else { continue }
            let parts = line[range].split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { found = Geometry(width: parts[0], height: parts[1]) }
        }
        return found
    }

    static func recordingSize(for screen: Geometry, maxDimension: Int) -> Geometry {
        let longSide = max(screen.width, screen.height)
        let scale = min(1.0, Double(maxDimension) / Double(longSide))
        func aligned(_ value: Int) -> Int { max(16, Int((Double(value) * scale / 16).rounded()) * 16) }
        return Geometry(width: aligned(screen.width), height: aligned(screen.height))
    }

    private func run(onFrame: @escaping @Sendable (VideoFrame) -> Void,
                     onEnd: @escaping @Sendable (String?) -> Void) async {
        var arguments = ["-s", serial, "exec-out", "screenrecord", "--output-format=h264", "--bit-rate", "8000000"]
        if let screen = await screenSize() {
            let size = Self.recordingSize(for: screen, maxDimension: maxDimension)
            arguments += ["--size", "\(size.width)x\(size.height)"]
        }
        arguments.append("-")

        var quickFailures = 0
        while !Task.isCancelled {
            let started = ContinuousClock.now
            var produced = false
            let decoder = H264StreamDecoder()
            let flusher = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(30))
                    for frame in decoder.flushIfIdle() { onFrame(frame) }
                }
            }
            defer { flusher.cancel() }
            do {
                for try await chunk in streamer.stream(sdk.adbPath, arguments) {
                    for frame in decoder.feed(chunk) {
                        produced = true
                        onFrame(frame)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                onEnd(ErrorMessage.friendly(error))
                return
            }
            // screenrecord stops by itself after three minutes; restart quietly unless it keeps dying at once
            if !produced || ContinuousClock.now - started < .seconds(2) { quickFailures += 1 } else { quickFailures = 0 }
            if quickFailures >= 3 {
                onEnd("The device stopped streaming its screen")
                return
            }
        }
    }
}

/// Touch and key input for a mirrored Android screen, sent through `adb shell input`.
public struct AndroidInput: Sendable {
    public enum Key: Int, Sendable {
        case home = 3, back = 4, volumeUp = 24, volumeDown = 25, power = 26, appSwitch = 187
    }

    private let runner: any ShellRunner
    private let sdk: AndroidSDK
    private let serial: String

    public init(runner: any ShellRunner = ProcessShellRunner(), sdk: AndroidSDK, serial: String) {
        self.runner = runner
        self.sdk = sdk
        self.serial = serial
    }

    public func tap(x: Int, y: Int) async throws {
        try await input(["tap", "\(x)", "\(y)"])
    }

    public func swipe(from: (x: Int, y: Int), to: (x: Int, y: Int), duration: Duration) async throws {
        try await input(["swipe", "\(from.x)", "\(from.y)", "\(to.x)", "\(to.y)",
                         "\(Int(duration / .milliseconds(1)))"])
    }

    public func press(_ key: Key) async throws {
        try await input(["keyevent", "\(key.rawValue)"])
    }

    /// Plain typed text; `input text` only copes with ASCII, so other characters are skipped.
    public func type(_ text: String) async throws {
        // inside the single quotes only `input text`'s own %s (space) needs care
        let escaped = text.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }
            .map { $0 == " " ? "%s" : String($0) }.joined()
        guard !escaped.isEmpty else { return }
        try await input(["text", RemoteShell.quote(escaped)])
    }

    public func press(keyCode: Int) async throws {
        try await input(["keyevent", "\(keyCode)"])
    }

    private func input(_ arguments: [String]) async throws {
        try await runner.run(sdk.adbPath, ["-s", serial, "shell", "input"] + arguments)
    }
}
