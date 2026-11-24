import Foundation
import Observation

/// What is armed right now, kept where the quit handler can reach it without the main actor.
final class ArmedCamera: @unchecked Sendable {
    static let shared = ArmedCamera()

    private let lock = NSLock()
    private var entry: (udid: String, dylib: String, injection: SimulatorInjection)?

    func set(_ udid: String, _ dylib: String, _ injection: SimulatorInjection) {
        lock.withLock { entry = (udid, dylib, injection) }
    }

    func clear() {
        lock.withLock { entry = nil }
    }

    /// Returns false when disarming failed, so the caller can keep the owner and report it.
    @discardableResult
    func disarm() -> Bool {
        guard let entry = lock.withLock({ entry }) else { return true }
        do {
            try entry.injection.disarm(entry.dylib, on: entry.udid)
            clear()
            return true
        } catch {
            return false
        }
    }
}

/// Feeds a Mac webcam, a still or a looping video into the iOS apps of one simulator.
///
/// The camera only exists for apps launched after `start`: dyld honours the injected library at exec time.
@MainActor
@Observable
public final class VirtualCameraViewModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case streaming
    }

    public private(set) var phase: Phase = .idle
    public private(set) var activeDeviceId: String?
    public private(set) var source: CameraSource?
    public private(set) var framesPerSecond: Double = 0
    public private(set) var error: String?
    /// A stop that failed: the simulator may still inject the library, so another start is refused until it succeeds.
    public private(set) var cleanupRequired = false
    public private(set) var webcams: [WebcamInfo] = []
    public private(set) var isLibraryAvailable: Bool

    public var flags = CameraFlags() {
        didSet { renderer?.flags = flags }
    }

    private let dylib: VirtualCameraDylib
    private let injection: SimulatorInjection
    private let bufferPath: String
    private let makeProducer: @Sendable (CameraSource) -> any CameraFrameProducing
    private let listWebcams: @Sendable () -> [WebcamInfo]
    private var producer: (any CameraFrameProducing)?
    private var buffer: SharedFrameBuffer?
    private var renderer: FrameRenderer?
    private var armedDylib: String?
    private var rateTask: Task<Void, Never>?

    public init(dylib: VirtualCameraDylib = VirtualCameraDylib(),
                injection: SimulatorInjection = SimulatorInjection(),
                bufferPath: String = SharedFrameLayout.path,
                makeProducer: @escaping @Sendable (CameraSource) -> any CameraFrameProducing = CameraProducers.make,
                listWebcams: @escaping @Sendable () -> [WebcamInfo] = WebcamInfo.available) {
        self.dylib = dylib
        self.injection = injection
        self.bufferPath = bufferPath
        self.makeProducer = makeProducer
        self.listWebcams = listWebcams
        isLibraryAvailable = dylib.isAvailable
    }

    public func refreshAvailability() {
        isLibraryAvailable = dylib.isAvailable
    }

    /// Fills the camera picker. Called only when the Camera section opens.
    public func loadWebcams() {
        webcams = listWebcams()
    }

    public func isActive(on device: Device) -> Bool {
        activeDeviceId == device.id && phase != .idle
    }

    public func start(on device: Device, source: CameraSource) async {
        guard phase == .idle, !cleanupRequired else {
            error = cleanupRequired ? "The last camera could not be stopped. Stop it again first." : "A camera is already running"
            return
        }
        guard device.platform == .ios, !device.isPhysical, device.state == .running else {
            error = "Start an iOS simulator first"
            return
        }
        phase = .starting
        error = nil
        activeDeviceId = device.id
        self.source = source
        do {
            let library = try dylib.install()
            let buffer = try SharedFrameBuffer(path: bufferPath)
            self.buffer = buffer
            let renderer = FrameRenderer(buffer: buffer, flags: flags)
            self.renderer = renderer
            try await Task.detached { [injection] in try injection.arm(library, on: device.id) }.value
            armedDylib = library
            ArmedCamera.shared.set(device.id, library, injection)

            let producer = makeProducer(source)
            self.producer = producer
            try await producer.start { image in renderer.render(image) }
            phase = .streaming
            startRateLoop(renderer)
        } catch {
            self.error = ErrorMessage.friendly(error)
            await stop()
        }
    }

    public func stop() async {
        let failure = error
        rateTask?.cancel()
        rateTask = nil
        producer?.stop()
        producer = nil
        renderer = nil
        buffer?.close()
        buffer = nil
        framesPerSecond = 0

        var cleanupError: String?
        if let library = armedDylib, let udid = activeDeviceId {
            let injection = injection
            do {
                try await Task.detached { try injection.disarm(library, on: udid) }.value
                ArmedCamera.shared.clear()
                armedDylib = nil
            } catch {
                cleanupError = "Could not remove the camera from the simulator: \(ErrorMessage.friendly(error)). Stop again to retry."
            }
        }
        if let cleanupError {
            cleanupRequired = true
            error = cleanupError
        } else {
            cleanupRequired = false
            error = failure
            activeDeviceId = nil
            source = nil
        }
        phase = .idle
    }

    /// For quitting the app: removes the injection even though no run loop is left to await anything.
    public nonisolated static func disarmForQuit() {
        ArmedCamera.shared.disarm()
    }

    private func startRateLoop(_ renderer: FrameRenderer) {
        rateTask = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = ContinuousClock.now
                let seconds = Double((now - last).components.seconds) + Double((now - last).components.attoseconds) / 1e18
                last = now
                self?.framesPerSecond = Double(renderer.takeFrameCount()) / max(seconds, 0.001)
            }
        }
    }
}
