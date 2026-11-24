import Darwin
import Foundation

/// Long-running helper processes BootBar starts (log streams, mirrors, input sessions). They must not outlive the app,
/// even when it is killed, so their pids are written to disk and the next launch reaps what is left.
public final class ChildProcesses: @unchecked Sendable {
    public static let shared = ChildProcesses()

    private struct Record: Codable, Equatable {
        let pid: Int32
        let executable: String
    }

    private let lock = NSLock()
    private let path: String
    private var running: [Int32: Process] = [:]

    public init(path: String = NSHomeDirectory() + "/Library/Application Support/BootBar/children.json") {
        self.path = path
    }

    /// Remember a process that was just started.
    public func track(_ process: Process) {
        lock.withLock {
            running[process.processIdentifier] = process
            save()
        }
    }

    public func untrack(_ process: Process) {
        lock.withLock {
            running[process.processIdentifier] = nil
            save()
        }
    }

    /// Ends everything this app started. Called when quitting and when a termination signal arrives.
    public func terminateAll() {
        let processes = lock.withLock { Array(running.values) }
        for process in processes where process.isRunning { process.terminate() }
        lock.withLock {
            running = [:]
            save()
        }
    }

    /// Ends processes recorded by an earlier run that died without cleaning up. A pid is only killed when it still
    /// runs the executable that was recorded, so a reused pid is left alone.
    @discardableResult
    public func reapOrphans() -> Int {
        let recorded = lock.withLock { load().filter { running[$0.pid] == nil } }
        var reaped = 0
        for record in recorded where Self.executable(of: record.pid) == record.executable {
            kill(record.pid, SIGTERM)
            reaped += 1
        }
        lock.withLock { save() }
        return reaped
    }

    /// How many processes are being tracked right now.
    func trackedCount() -> Int { lock.withLock { running.count } }

    private func load() -> [Record] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// Writes what is running now; callers hold the lock.
    private func save() {
        let records = running.values.compactMap { process -> Record? in
            guard process.isRunning, let url = process.executableURL else { return nil }
            return Record(pid: process.processIdentifier, executable: url.path)
        }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if records.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private static func executable(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
