import Foundation
import Observation

/// Runs the capture proxy and keeps what it sees: the flows, their filter and the setup of devices.
@MainActor
@Observable
public final class NetworkViewModel {
    public enum State: Equatable, Sendable {
        case stopped
        case running(port: Int)
        case failed(String)
    }

    public private(set) var state: State = .stopped
    public private(set) var visible: [HTTPFlow] = []
    public private(set) var totalCount = 0
    public private(set) var apps: [AppCount] = []
    public private(set) var isRoutingMac = false
    public private(set) var setupMessage: String?
    public private(set) var isWorking = false
    public private(set) var deviceState = DeviceProxyState()
    public var selectedFlowId: Int?
    public var isPaused = false

    /// Each device keeps its own filter, like the log's.
    public var filter = HTTPFilter() {
        didSet {
            guard filter != oldValue else { return }
            if let device { savedFilters[device.id] = filter; persistFilters() }
            scheduleRefilter()
        }
    }

    /// Show only what the selected device sent (simulators; Android is told apart by its adb connection).
    public var limitsToDevice = true {
        didSet { if limitsToDevice != oldValue { refilterNow() } }
    }

    public var port = 8899
    public var capacity: Int

    @ObservationIgnored private var flows: [HTTPFlow] = []
    @ObservationIgnored private var indexById: [Int: Int] = [:]
    @ObservationIgnored private var matcher = HTTPFilter().compiled()
    @ObservationIgnored private var appCounts: [String: Int] = [:]
    @ObservationIgnored private var server: ProxyServer?
    @ObservationIgnored private var authority: CertificateAuthority?
    @ObservationIgnored private var device: Device?
    @ObservationIgnored private var savedFilters: [String: HTTPFilter] = [:]
    @ObservationIgnored private var refilterTask: Task<Void, Never>?
    @ObservationIgnored private var configuredAndroid: [String: Device] = [:]
    @ObservationIgnored private var pendingFlows: [HTTPFlow] = []
    @ObservationIgnored private var flushScheduled = false

    private let runner: any ShellRunner
    private let locateSDK: @Sendable () -> AndroidSDK?
    private let makeAuthority: @Sendable () throws -> CertificateAuthority
    private let systemProxy: SystemProxy
    private let defaults: UserDefaults?
    private let debounce: Duration
    private static let filtersKey = "networkFilters"

    public init(runner: any ShellRunner = ProcessShellRunner(), capacity: Int = 5000, debounce: Duration = .milliseconds(150),
                defaults: UserDefaults? = nil, systemProxy: SystemProxy = SystemProxy(),
                makeAuthority: @escaping @Sendable () throws -> CertificateAuthority = { try CertificateAuthority() },
                locateSDK: @escaping @Sendable () -> AndroidSDK?) {
        self.runner = runner
        self.capacity = capacity
        self.debounce = debounce
        self.defaults = defaults
        self.systemProxy = systemProxy
        self.makeAuthority = makeAuthority
        self.locateSDK = locateSDK
        if let data = defaults?.data(forKey: Self.filtersKey),
           let saved = try? JSONDecoder().decode([String: HTTPFilter].self, from: data) {
            savedFilters = saved
        }
    }

    public var isRunning: Bool { if case .running = state { true } else { false } }

    public var selectedFlow: HTTPFlow? {
        selectedFlowId.flatMap { id in indexById[id].map { flows[$0] } }
    }

    public var certificatePath: String? { authority?.certificatePath ?? (try? makeAuthority())?.certificatePath }

    // MARK: Capture

    /// Starts the proxy. `routeMac` also points the macOS proxy at it, which is what makes simulators use it.
    public func start(routeMac: Bool) async {
        guard !isRunning else { return }
        do {
            let authority = try makeAuthority()
            self.authority = authority
            var options = ProxyOptions()
            options.port = port
            options.inspects = ProxyOptions.inspectsMobile
            let server = ProxyServer(authority: authority, options: options) { [weak self] flow in
                Task { @MainActor in self?.receive(flow) }
            }
            try server.start()
            self.server = server
            state = .running(port: server.port)
            if routeMac {
                try await systemProxy.enable(port: server.port)
                isRoutingMac = true
            }
        } catch {
            server?.stop()
            server = nil
            state = .failed(String(describing: error))
        }
    }

    public func stop() async {
        server?.stop()
        server = nil
        if isRoutingMac || systemProxy.hasPendingBackup {
            try? await systemProxy.restore()
            isRoutingMac = false
        }
        for device in configuredAndroid.values {
            if let authority { try? await DeviceProxySetup(runner: runner, sdk: locateSDK(), authority: authority).disableAndroidProxy(on: device, port: port) }
        }
        configuredAndroid = [:]
        if isRunning { state = .stopped }
    }

    public func clear() {
        flows = []
        indexById = [:]
        appCounts = [:]
        visible = []
        totalCount = 0
        apps = []
        selectedFlowId = nil
    }

    /// Restores the macOS proxy a crashed run left switched on. Call once at launch.
    public func recoverSystemProxy() async {
        if systemProxy.hasPendingBackup { try? await systemProxy.restore() }
    }

    /// For quitting: the macOS proxy must not stay pointed at a proxy that is gone.
    public nonisolated static func restoreSystemProxyForQuit() {
        SystemProxy().restoreNow()
    }

    // MARK: Device

    public func select(_ device: Device) async {
        if self.device?.id != device.id {
            self.device = nil
            filter = savedFilters[device.id] ?? HTTPFilter()
        }
        self.device = device
        setupMessage = nil
        await refreshDeviceState()
        refilterNow()
    }

    public func refreshDeviceState() async {
        guard let device, let authority else { deviceState = DeviceProxyState(); return }
        let setup = DeviceProxySetup(runner: runner, sdk: locateSDK(), authority: authority)
        var state = DeviceProxyState(certificateInstalled: setup.isCertificateInstalled(on: device))
        switch (device.platform, device.isPhysical) {
        case (.ios, false): state.proxyConfigured = isRoutingMac
        case (.android, _): state.proxyConfigured = await setup.isAndroidProxyEnabled(on: device, port: port)
        case (.ios, true): break
        }
        deviceState = state
    }

    /// Does what the device needs: trust the certificate, and for Android point it at the proxy.
    public func setUp(_ device: Device) async {
        guard !isWorking else { return }
        isWorking = true
        setupMessage = nil
        defer { isWorking = false }
        if !isRunning { await start(routeMac: device.platform == .ios) }
        guard isRunning, let authority else { return }
        let setup = DeviceProxySetup(runner: runner, sdk: locateSDK(), authority: authority)
        do {
            if !setup.isCertificateInstalled(on: device) { setupMessage = try await setup.installCertificate(on: device) }
            if device.platform == .android {
                try await setup.enableAndroidProxy(on: device, port: port)
                configuredAndroid[device.id] = device
            } else if !isRoutingMac {
                try await systemProxy.enable(port: port)
                isRoutingMac = true
            }
        } catch {
            setupMessage = ErrorMessage.friendly(error)
        }
        await refreshDeviceState()
    }

    public func installCertificate(on device: Device) async {
        guard let authority = authority ?? (try? makeAuthority()) else { return }
        self.authority = authority
        isWorking = true
        defer { isWorking = false }
        do {
            setupMessage = try await DeviceProxySetup(runner: runner, sdk: locateSDK(), authority: authority).installCertificate(on: device)
        } catch {
            setupMessage = ErrorMessage.friendly(error)
        }
        await refreshDeviceState()
    }

    public func stopRouting(_ device: Device) async {
        if device.platform == .android, let authority {
            try? await DeviceProxySetup(runner: runner, sdk: locateSDK(), authority: authority).disableAndroidProxy(on: device, port: port)
            configuredAndroid[device.id] = nil
        } else if isRoutingMac {
            try? await systemProxy.restore()
            isRoutingMac = false
        }
        await refreshDeviceState()
    }

    // MARK: Flows

    func receive(_ flow: HTTPFlow) {
        pendingFlows.append(flow)
        guard !flushScheduled else { return }
        flushScheduled = true
        // flows update several times each, so changes are applied in batches
        Task { [debounce] in
            try? await Task.sleep(for: min(debounce, .milliseconds(80)))
            flushPending()
        }
    }

    func flushPending() {
        flushScheduled = false
        let batch = pendingFlows
        pendingFlows = []
        guard !isPaused || !batch.isEmpty else { return }
        for flow in batch { apply(flow) }
        if flows.count > capacity {
            let drop = flows.count - capacity + capacity / 10
            flows.removeFirst(drop)
            indexById = Dictionary(uniqueKeysWithValues: flows.enumerated().map { ($1.id, $0) })
            appCounts = flows.reduce(into: [:]) { $0[$1.appName, default: 0] += 1 }
            refilterNow()
        }
        totalCount = flows.count
        apps = appCounts.map { AppCount(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }

    private func apply(_ flow: HTTPFlow) {
        if let index = indexById[flow.id] {
            flows[index] = flow
            if let position = visible.firstIndex(where: { $0.id == flow.id }) {
                if matches(flow) { visible[position] = flow } else { visible.remove(at: position) }
            } else if matches(flow) {
                insertVisible(flow)
            }
        } else {
            indexById[flow.id] = flows.count
            flows.append(flow)
            appCounts[flow.appName, default: 0] += 1
            if matches(flow) { visible.append(flow) }
        }
    }

    private func insertVisible(_ flow: HTTPFlow) {
        let position = visible.firstIndex { $0.id > flow.id } ?? visible.endIndex
        visible.insert(flow, at: position)
    }

    private func matches(_ flow: HTTPFlow) -> Bool {
        if limitsToDevice, let device, device.platform == .ios, !device.isPhysical {
            guard flow.client.deviceId == device.id else { return false }
        }
        if limitsToDevice, let device, device.platform == .android {
            guard flow.client.app == "Android (adb)" || flow.client.app == "Android emulator" else { return false }
        }
        return matcher.matches(flow)
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
        visible = flows.filter(matches)
    }

    private func persistFilters() {
        guard let defaults, let data = try? JSONEncoder().encode(savedFilters) else { return }
        defaults.set(data, forKey: Self.filtersKey)
    }
}
