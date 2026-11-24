import Foundation
import Observation

/// Streams a device's log and keeps the last `capacity` entries, filtered live.
@MainActor
@Observable
public final class LogViewModel {
    public enum State: Equatable, Sendable {
        case idle
        case streaming
        case failed(String)
    }

    public struct AppCount: Identifiable, Equatable, Sendable {
        public let name: String
        public let count: Int
        public var id: String { name }
    }

    public private(set) var visible: [LogEntry] = []
    public private(set) var totalCount = 0
    public private(set) var state: State = .idle
    /// Entries that arrived while paused and are not shown yet.
    public private(set) var queuedWhilePaused = 0
    public private(set) var apps: [AppCount] = []

    public var filter = LogFilter() {
        didSet {
            guard filter != oldValue else { return }
            scheduleRefilter()
        }
    }

    public var isPaused = false {
        didSet {
            guard isPaused != oldValue, !isPaused else { return }
            let queued = queue
            queue = []
            queuedWhilePaused = 0
            append(queued)
        }
    }

    public let capacity: Int

    @ObservationIgnored private var entries: [LogEntry] = []
    @ObservationIgnored private var queue: [LogEntry] = []
    @ObservationIgnored private var appCounts: [String: Int] = [:]
    @ObservationIgnored private var matcher = LogFilter().compiled()
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var refilterTask: Task<Void, Never>?

    private let runner: any ShellRunner
    private let streamer: any ByteStreaming
    private let locateSDK: @Sendable () -> AndroidSDK?
    private let debounce: Duration

    public init(runner: any ShellRunner = ProcessShellRunner(), streamer: any ByteStreaming = ProcessByteStreamer(),
                capacity: Int = 50_000, debounce: Duration = .milliseconds(150),
                locateSDK: @escaping @Sendable () -> AndroidSDK?) {
        self.runner = runner
        self.streamer = streamer
        self.capacity = capacity
        self.debounce = debounce
        self.locateSDK = locateSDK
    }

    // MARK: Streaming

    /// Starts streaming `device`, replacing whatever was streaming before and clearing the buffer.
    public func start(_ device: Device) {
        stop()
        clear()
        let source: LogSource
        do {
            source = try LogSource.make(for: device, sdk: locateSDK())
        } catch {
            state = .failed(String(describing: error))
            return
        }
        state = .streaming
        let token = generation
        let runner = runner
        let streamer = streamer
        streamTask = Task.detached { [weak self] in
            var splitter = LineSplitter()
            let names = source.adbPath.flatMap { adb in
                source.serial.map { AndroidProcessNames(runner: runner, adbPath: adb, serial: $0) }
            }
            do {
                for try await chunk in streamer.stream(source.executable, source.arguments) {
                    var batch: [LogEntry] = []
                    for line in splitter.push(chunk) {
                        guard var entry = source.parse(line) else { continue }
                        if entry.app == nil, let pid = entry.pid, let names { entry.app = await names.name(for: pid) }
                        batch.append(entry)
                    }
                    if !batch.isEmpty { await self?.receive(batch, token: token) }
                }
                await self?.finish(token: token, error: nil)
            } catch {
                await self?.finish(token: token, error: ErrorMessage.friendly(error))
            }
        }
    }

    public func stop() {
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        refilterTask?.cancel()
        if state == .streaming { state = .idle }
    }

    public func clear() {
        entries = []
        queue = []
        queuedWhilePaused = 0
        appCounts = [:]
        visible = []
        totalCount = 0
        apps = []
    }

    private func receive(_ batch: [LogEntry], token: Int) {
        guard token == generation else { return }
        ingest(batch)
    }

    private func finish(token: Int, error: String?) {
        guard token == generation else { return }
        state = error.map(State.failed) ?? .idle
    }

    // MARK: Entries

    func ingest(_ batch: [LogEntry]) {
        if isPaused {
            queue.append(contentsOf: batch)
            queuedWhilePaused = queue.count
            return
        }
        append(batch)
    }

    private func append(_ batch: [LogEntry]) {
        guard !batch.isEmpty else { return }
        var numbered: [LogEntry] = []
        numbered.reserveCapacity(batch.count)
        for var entry in batch {
            entry.id = nextId
            nextId += 1
            appCounts[entry.appName, default: 0] += 1
            numbered.append(entry)
        }
        entries.append(contentsOf: numbered)
        if entries.count > capacity {
            entries.removeFirst(max(entries.count - capacity, capacity / 10))
            rebuildCounts()
            refilterNow()
        } else {
            visible.append(contentsOf: numbered.filter(matcher.matches))
        }
        totalCount = entries.count
        publishApps()
    }

    private func rebuildCounts() {
        appCounts = entries.reduce(into: [:]) { $0[$1.appName, default: 0] += 1 }
    }

    private func publishApps() {
        apps = appCounts.map { AppCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private func scheduleRefilter() {
        refilterTask?.cancel()
        refilterTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            refilterNow()
        }
    }

    private func refilterNow() {
        matcher = filter.compiled()
        visible = filter.isActive ? entries.filter(matcher.matches) : entries
    }

    /// The visible lines as text, for copying or saving.
    public func text(of entries: [LogEntry]? = nil) -> String {
        (entries ?? visible).map(\.line).joined(separator: "\n")
    }
}
