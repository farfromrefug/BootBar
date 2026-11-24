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

    /// The port in use while capturing.
    public private(set) var port = 8899
    /// The port the user asked for; nil takes 8899, or a free one when that is taken.
    public var preferredPort: Int?
    /// Listen on the local network too, for iPhones and iPads that cannot use the Mac's loopback.
    public private(set) var allowsNetworkDevices = false
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
            let server = try startServer(authority: authority)
            self.server = server
            port = server.port
            state = .running(port: server.port)
            if routeMac {
                try await systemProxy.enable(port: server.port)
                isRoutingMac = true
            }
            await refreshDeviceState()
        } catch {
            server?.stop()
            server = nil
            state = .failed(String(describing: error))
        }
    }

    /// The preferred port, or when none was chosen 8899 and then any free port.
    private func startServer(authority: CertificateAuthority) throws -> ProxyServer {
        func attempt(port: Int) throws -> ProxyServer {
            var options = ProxyOptions()
            options.port = port
            options.allowsNetworkClients = allowsNetworkDevices
            options.inspects = ProxyOptions.inspectsMobile
            let server = ProxyServer(authority: authority, options: options) { [weak self] flow in
                Task { @MainActor in self?.receive(flow) }
            }
            try server.start()
            return server
        }
        if let preferredPort, preferredPort > 0 { return try attempt(port: preferredPort) }
        do { return try attempt(port: 8899) } catch { return try attempt(port: 0) }
    }

    /// Where an iPhone or iPad on the same network points its proxy setting.
    public var networkAddress: String? { LocalNetwork.ipv4Addresses().first }

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

    public func dismissSetupMessage() {
        setupMessage = nil
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

    /// For quitting: Android devices keep the proxy setting after the app is gone, which would cut their network.
    public func restoreAndroidForQuit() {
        guard let sdk = locateSDK() else { return }
        for device in configuredAndroid.values {
            guard let serial = device.serial else { continue }
            for arguments in [["shell", "settings", "put", "global", "http_proxy", ":0"], ["reverse", "--remove", "tcp:\(port)"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sdk.adbPath)
                process.arguments = ["-s", serial] + arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
        configuredAndroid = [:]
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
        case (.android, _):
            state.proxyConfigured = await setup.isAndroidProxyEnabled(on: device, port: port)
            // a certificate in the user store cannot be seen from here, but decrypted traffic proves it works
            state = merging(state, evidence: trafficEvidence())
        case (.ios, true): state = merging(state, evidence: trafficEvidence())
        }
        deviceState = state
    }

    /// Does what the device needs: trust the certificate, and for Android point it at the proxy.
    public func setUp(_ device: Device) async {
        guard !isWorking else { return }
        isWorking = true
        setupMessage = nil
        defer { isWorking = false }
        if device.platform == .ios, device.isPhysical {
            await setUpPhone()
            await refreshDeviceState()
            return
        }
        if !isRunning { await start(routeMac: device.platform == .ios) }
        guard isRunning, let authority else { return }
        let setup = DeviceProxySetup(runner: runner, sdk: locateSDK(), authority: authority)
        do {
            do {
                if !setup.isCertificateInstalled(on: device) { setupMessage = try await setup.installCertificate(on: device) }
            } catch {
                // the proxy setting is still worth applying: plain HTTP works without the certificate
                setupMessage = ErrorMessage.friendly(error)
            }
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

    /// Phones go over the network: listen there, and say what to do on the phone.
    private func setUpPhone() async {
        if !isRunning || !allowsNetworkDevices {
            await stop()
            allowsNetworkDevices = true
            await start(routeMac: false)
        }
        guard isRunning else { return }
        let address = networkAddress.map { "\($0) port \(port)" } ?? "this Mac's address, port \(port)"
        setupMessage = "On the phone, on the same Wi-Fi: Settings › Wi-Fi › ⓘ › Configure Proxy › Manual, server and port: \(address). "
            + "Then open http://bootbar.proxy in Safari, download the certificate, install it in Settings › Profile Downloaded, "
            + "and turn it on in Settings › General › About › Certificate Trust Settings."
    }

    public func installCertificate(on device: Device) async {
        if device.platform == .ios, device.isPhysical {
            await setUp(device)
            return
        }
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
        if device.platform == .ios, device.isPhysical {
            allowsNetworkDevices = false
            if isRunning {
                await stop()
                await start(routeMac: false)
            }
            setupMessage = nil
            await refreshDeviceState()
            return
        }
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
        if device != nil, !(deviceState.proxyConfigured && deviceState.certificateInstalled) {
            let before = deviceState
            deviceState = merging(deviceState, evidence: trafficEvidence())
            // the manual steps worked: their instructions are no longer needed
            if deviceState != before, deviceState.proxyConfigured, deviceState.certificateInstalled { setupMessage = nil }
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

    /// What the traffic seen so far says about the selected device, for setups that cannot be checked directly:
    /// phones and the user certificate store of Android.
    private func trafficEvidence() -> (seen: Bool, decrypted: Bool) {
        guard let device else { return (false, false) }
        let isDevice: (HTTPFlow) -> Bool
        switch (device.platform, device.isPhysical) {
        case (.ios, true): isDevice = { $0.client.remoteAddress != nil }
        case (.android, _): isDevice = { $0.client.app == "Android (adb)" || $0.client.app == "Android emulator" }
        default: return (false, false)
        }
        let mine = flows.filter(isDevice)
        return (!mine.isEmpty, mine.contains { $0.isHTTPS && !$0.isTunnel && $0.status != nil })
    }

    private func merging(_ state: DeviceProxyState, evidence: (seen: Bool, decrypted: Bool)) -> DeviceProxyState {
        var state = state
        state.proxyConfigured = state.proxyConfigured || evidence.seen
        state.certificateInstalled = state.certificateInstalled || evidence.decrypted
        return state
    }

    private func matches(_ flow: HTTPFlow) -> Bool {
        if limitsToDevice, let device, device.platform == .ios, device.isPhysical {
            guard flow.client.remoteAddress != nil else { return false }
        }
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
