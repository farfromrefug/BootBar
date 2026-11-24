import Foundation

/// The dylibs listed in a simulator's `DYLD_INSERT_LIBRARIES`. That variable is one string for the
/// whole simulator, so arming is read-modify-write and entries are matched by file name.
public struct InjectedDylibs: Equatable, Sendable {
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }

    public var isEmpty: Bool { paths.isEmpty }
    public var environmentValue: String { paths.joined(separator: ":") }

    public static func parsing(_ value: String?) -> InjectedDylibs {
        let paths = (value ?? "").split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("/") && $0.hasSuffix(".dylib") && !$0.contains("\n") }
        return InjectedDylibs(paths: paths)
    }

    /// Replaces any other build of the same dylib: two copies in dyld's list is a load error.
    public func adding(_ path: String) -> InjectedDylibs {
        InjectedDylibs(paths: removing(path).paths + [path])
    }

    public func removing(_ path: String) -> InjectedDylibs {
        let name = (path as NSString).lastPathComponent
        return InjectedDylibs(paths: paths.filter { ($0 as NSString).lastPathComponent != name })
    }
}

/// Arms and disarms a dylib in one simulator through `simctl spawn … launchctl`. Synchronous, so it can
/// also run while the app quits.
public struct SimulatorInjection: Sendable {
    private let xcrun: String
    private let lockDirectory: String
    private static let variable = "DYLD_INSERT_LIBRARIES"

    public init(xcrun: String = "/usr/bin/xcrun",
                lockDirectory: String = NSHomeDirectory() + "/Library/Application Support/BootBar/locks") {
        self.xcrun = xcrun
        self.lockDirectory = lockDirectory
    }

    public func arm(_ dylib: String, on udid: String) throws {
        try locked(udid) { try write(try current(udid).adding(dylib), udid) }
    }

    public func disarm(_ dylib: String, on udid: String) throws {
        try locked(udid) { try write(try current(udid).removing(dylib), udid) }
    }

    public func isArmed(_ dylib: String, on udid: String) throws -> Bool {
        let name = (dylib as NSString).lastPathComponent
        return try current(udid).paths.contains { ($0 as NSString).lastPathComponent == name }
    }

    private func current(_ udid: String) throws -> InjectedDylibs {
        let result = try spawn(udid, ["getenv", Self.variable])
        // launchctl exits 1 with nothing on stdout when the variable is unset; anything else is unknown
        if result.status == 1, result.stdout.isEmpty { return InjectedDylibs(paths: []) }
        guard result.status == 0 else {
            throw ShellError(command: "launchctl getenv", exitCode: result.status, stderr: result.stderr)
        }
        return .parsing(result.stdout)
    }

    private func write(_ dylibs: InjectedDylibs, _ udid: String) throws {
        // an empty value is a library dyld fails to load, so the last one out removes the variable
        let arguments = dylibs.isEmpty ? ["unsetenv", Self.variable] : ["setenv", Self.variable, dylibs.environmentValue]
        let result = try spawn(udid, arguments)
        guard result.status == 0 else {
            throw ShellError(command: "launchctl \(arguments[0])", exitCode: result.status, stderr: result.stderr)
        }
    }

    private struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// stdout and stderr are read separately: injected libraries log to stderr and must not end up in the value.
    private func spawn(_ udid: String, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrun)
        process.arguments = ["simctl", "spawn", udid, "launchctl"] + arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let group = DispatchGroup()
        let collected = CollectedData()
        for (pipe, isOutput) in [(out, true), (err, false)] {
            group.enter()
            // a thread of its own: pool workers can all be busy waiting for each other when many run at once
            Thread.detachNewThread {
                collected.store(pipe.fileHandleForReading.readDataToEndOfFile(), isOutput: isOutput)
                group.leave()
            }
        }
        process.waitUntilExit()
        group.wait()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: collected.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                      stderr: String(decoding: collected.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class CollectedData: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        var stdout: Data { lock.withLock { out } }
        var stderr: Data { lock.withLock { err } }

        func store(_ data: Data, isOutput: Bool) {
            lock.withLock { if isOutput { out = data } else { err = data } }
        }
    }

    /// The read-modify-write is not atomic, so two writers (camera and anything else) hold a file lock.
    private func locked<T>(_ udid: String, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: lockDirectory, withIntermediateDirectories: true)
        let descriptor = open("\(lockDirectory)/\(udid).inject.lock", O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw ShellError(command: "lock", exitCode: 1, stderr: "Could not lock the simulator environment")
        }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw ShellError(command: "lock", exitCode: 1, stderr: "Could not lock the simulator environment")
            }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
