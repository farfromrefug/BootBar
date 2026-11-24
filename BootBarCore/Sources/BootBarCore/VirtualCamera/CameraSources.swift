@preconcurrency import AVFoundation
import CoreImage
import Foundation

public enum CameraSource: Equatable, Sendable {
    case webcam(deviceUID: String)
    case image(path: String)
    case video(path: String)
}

public struct WebcamInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    /// Cameras attached to this Mac. Nothing touches the camera, so this does not ask for permission.
    public static func available() -> [WebcamInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        let fallback = AVCaptureDevice.default(for: .video)?.uniqueID
        return session.devices.map { WebcamInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == fallback) }
    }
}

/// Anything that can produce camera frames.
public protocol CameraFrameProducing: Sendable {
    func start(onFrame: @escaping @Sendable (CIImage) -> Void) async throws
    func stop()
}

public enum CameraSourceError: LocalizedError, CustomStringConvertible {
    case unreadableImage(String)
    case noVideoTrack(String)
    case cameraDenied
    case cameraMissing

    public var description: String {
        switch self {
        case .unreadableImage(let name): "\(name) is not an image BootBar can read"
        case .noVideoTrack(let name): "\(name) has no video track"
        case .cameraDenied: "Allow camera access for BootBar in System Settings → Privacy & Security → Camera"
        case .cameraMissing: "That camera is no longer connected"
        }
    }
}

public enum CameraProducers {
    public static func make(_ source: CameraSource) -> any CameraFrameProducing {
        switch source {
        case .webcam(let uid): WebcamProducer(deviceUID: uid)
        case .image(let path): ImageProducer(path: path)
        case .video(let path): VideoProducer(path: path)
        }
    }
}

/// A still, re-sent about 30 times a second: the simulator side shows "No camera signal" when frames stop advancing.
final class ImageProducer: CameraFrameProducing, @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(path: String) {
        self.path = path
    }

    func start(onFrame: @escaping @Sendable (CIImage) -> Void) async throws {
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else {
            throw CameraSourceError.unreadableImage((path as NSString).lastPathComponent)
        }
        lock.withLock {
            task = Task {
                while !Task.isCancelled {
                    onFrame(image)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
    }

    func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }
}

private struct MediaBox: @unchecked Sendable {
    let asset: AVAsset
    let track: AVAssetTrack
}

/// A clip decoded with `AVAssetReader`, paced by its own timestamps and looped.
final class VideoProducer: CameraFrameProducing, @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(path: String) {
        self.path = path
    }

    func start(onFrame: @escaping @Sendable (CIImage) -> Void) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CameraSourceError.noVideoTrack((path as NSString).lastPathComponent)
        }
        let orientation = Self.orientation(of: try await track.load(.preferredTransform))
        let media = MediaBox(asset: asset, track: track)
        lock.withLock {
            task = Task.detached {
                while !Task.isCancelled {
                    let played = Self.playOnce(asset: media.asset, track: media.track, orientation: orientation, onFrame: onFrame)
                    if !played { try? await Task.sleep(for: .milliseconds(250)) }
                }
            }
        }
    }

    func stop() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    /// Plays the clip once; false when it could not be read at all.
    private static func playOnce(asset: AVAsset, track: AVAssetTrack, orientation: CGImagePropertyOrientation,
                                 onFrame: @Sendable (CIImage) -> Void) -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }

        let start = ContinuousClock.now
        var first: CMTime?
        while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            first = first ?? time
            let offset = max(0, CMTimeGetSeconds(time - (first ?? time)))
            let wait = Duration.seconds(offset) - (ContinuousClock.now - start)
            if wait > .zero { Thread.sleep(forTimeInterval: Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18) }
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                onFrame(CIImage(cvPixelBuffer: buffer).oriented(orientation))
            }
        }
        return true
    }

    /// Phone videos carry a rotation instead of rotated pixels.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}

/// A camera attached to this Mac, through `AVCaptureSession`.
final class WebcamProducer: NSObject, CameraFrameProducing, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deviceUID: String
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "bootbar.webcam")
    private let lock = NSLock()
    private var handler: (@Sendable (CIImage) -> Void)?

    init(deviceUID: String) {
        self.deviceUID = deviceUID
    }

    func start(onFrame: @escaping @Sendable (CIImage) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraSourceError.cameraDenied }
        guard let device = AVCaptureDevice(uniqueID: deviceUID) else { throw CameraSourceError.cameraMissing }
        lock.withLock { handler = onFrame }
        session.beginConfiguration()
        session.addInput(try AVCaptureDeviceInput(device: device))
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
        let session = session
        queue.async { session.startRunning() }
    }

    func stop() {
        lock.withLock { handler = nil }
        let session = session
        queue.async { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let handler = lock.withLock({ handler }) else { return }
        handler(CIImage(cvPixelBuffer: buffer))
    }
}

/// Scales frames to fit the shared buffer's 1280×1280 canvas and paints them into it.
public final class FrameRenderer: @unchecked Sendable {
    private let buffer: SharedFrameBuffer
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var currentFlags: CameraFlags
    private var rendered = 0

    public init(buffer: SharedFrameBuffer, flags: CameraFlags = CameraFlags()) {
        self.buffer = buffer
        currentFlags = flags
    }

    public var flags: CameraFlags {
        get { lock.withLock { currentFlags } }
        set { lock.withLock { currentFlags = newValue } }
    }

    /// Frames painted since the last call; the caller divides by elapsed time for a rate.
    public func takeFrameCount() -> Int {
        lock.withLock {
            defer { rendered = 0 }
            return rendered
        }
    }

    public func render(_ image: CIImage) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return }
        let scale = min(1, CGFloat(SharedFrameLayout.maxWidth) / extent.width, CGFloat(SharedFrameLayout.maxHeight) / extent.height)
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        buffer.write(width: width, height: height, flags: flags) { pixels, rowBytes in
            context.render(placed, toBitmap: pixels, rowBytes: rowBytes, bounds: bounds, format: .BGRA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        lock.withLock { rendered += 1 }
    }
}

extension CameraSourceError {
    public var errorDescription: String? { description }
}
