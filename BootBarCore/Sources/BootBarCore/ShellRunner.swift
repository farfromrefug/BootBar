import Foundation

public protocol ShellRunner: Sendable {
    @discardableResult
    func run(_ executable: String, _ arguments: [String]) async throws -> String
    func launchDetached(_ executable: String, _ arguments: [String], failureWindow: Duration) async throws
}

public struct ShellError: Error, Equatable, Sendable {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public init(command: String, exitCode: Int32, stderr: String) {
        self.command = command
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

public enum ErrorMessage {
    /// What to show for a failed command: its stderr, or the exit code when it said nothing.
    public static func friendly(_ error: Error) -> String {
        guard let shellError = error as? ShellError else { return error.localizedDescription }
        return shellError.stderr.isEmpty ? "Command failed (exit \(shellError.exitCode))" : shellError.stderr
    }
}

private let capturedStderrLimit = 8 * 1024

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            let remaining = capturedStderrLimit - data.count
            guard remaining > 0 else { return }
            data.append(chunk.prefix(remaining))
        }
    }

    var text: String {
        String(decoding: lock.withLock { data }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LaunchedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func launch(_ process: Process) throws {
        try lock.withLock {
            guard !isCancelled else { throw CancellationError() }
            try process.run()
            self.process = process
        }
    }

    func terminate() {
        lock.withLock {
            isCancelled = true
            guard let process, process.isRunning else { return }
            process.terminate()
        }
    }
}

private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasFinished = false

    func signal() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !hasFinished else { return nil }
            hasFinished = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        pending?.resume()
    }

    func wait(upTo window: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.wait() }
            group.addTask { try? await Task.sleep(for: window) }
            await group.next()
            group.cancelAll()
        }
    }

    private func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { newContinuation in
                let finishedAlready: Bool = lock.withLock {
                    guard !hasFinished else { return true }
                    continuation = newContinuation
                    return false
                }
                if finishedAlready { newContinuation.resume() }
            }
        } onCancel: {
            signal()
        }
    }
}

public struct ProcessShellRunner: ShellRunner {
    public init() {}

    @discardableResult
    public func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let launched = LaunchedProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result { try Self.runSync(executable, arguments, launched) })
                }
            }
        } onCancel: {
            launched.terminate()
        }
    }

    public func launchDetached(_ executable: String, _ arguments: [String],
                               failureWindow: Duration) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr

        let captured = OutputBuffer()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            captured.append(chunk)
        }

        let exited = ExitWaiter()
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        await exited.wait(upTo: failureWindow)

        guard !process.isRunning, process.terminationStatus != 0 else { return }
        throw ShellError(command: Self.describe(executable, arguments),
                         exitCode: process.terminationStatus,
                         stderr: captured.text)
    }

    private static func runSync(_ executable: String, _ arguments: [String],
                                _ launched: LaunchedProcess) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try launched.launch(process)

        let captured = OutputBuffer()
        let errorHandle = stderr.fileHandleForReading
        let draining = DispatchGroup()
        DispatchQueue.global().async(group: draining) {
            captured.append(errorHandle.readDataToEndOfFile())
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        draining.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ShellError(command: describe(executable, arguments),
                             exitCode: process.terminationStatus,
                             stderr: captured.text)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    private static func describe(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// Long-running process whose stdout is consumed incrementally (a video stream, for instance).
public protocol ByteStreaming: Sendable {
    /// Yields stdout chunks until the process exits. Cancelling the consumer terminates the process.
    func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<Data, Error>
}

public struct ProcessByteStreamer: ByteStreaming {
    public init() {}

    public func stream(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let captured = OutputBuffer()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { captured.append(chunk) }
            }
            // The stream ends at EOF rather than at process exit, so no buffered output is lost.
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    continuation.yield(chunk)
                    return
                }
                handle.readabilityHandler = nil
                process.waitUntilExit()
                if process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ShellError(
                        command: Self.describe(executable, arguments),
                        exitCode: process.terminationStatus, stderr: captured.text))
                }
            }
            continuation.onTermination = { _ in
                stdout.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Runs to completion and returns raw stdout (images, for example).
    public func collect(_ executable: String, _ arguments: [String]) async throws -> Data {
        var data = Data()
        for try await chunk in stream(executable, arguments) { data.append(chunk) }
        return data
    }

    private static func describe(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).joined(separator: " ")
    }
}
