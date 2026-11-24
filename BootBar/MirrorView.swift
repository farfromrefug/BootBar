import AVFoundation
import AppKit
import SwiftUI

struct MirrorView: NSViewRepresentable {
    let controller: MirrorController

    func makeNSView(context: Context) -> MirrorHostView {
        let view = MirrorHostView(displayLayer: controller.displayLayer)
        view.onPointer = { phase, point in controller.pointer(phase, at: point) }
        view.onKey = { event in controller.handleKey(event) }
        return view
    }

    func updateNSView(_ view: MirrorHostView, context: Context) {
        view.frameSize = controller.frameSize
        view.acceptsInput = controller.supportsInput
        if controller.state == .live, controller.supportsInput { view.takeFocusIfUnclaimed() }
        view.show(controller.content)
    }
}

final class MirrorHostView: NSView {
    var onPointer: ((MirrorController.PointerPhase, CGPoint) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var frameSize: CGSize? { didSet { needsLayout = true } }
    var acceptsInput = false

    private let displayLayer: AVSampleBufferDisplayLayer
    private let imageLayer = CALayer()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentSession: AVCaptureSession?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.isHidden = true
        layer?.addSublayer(displayLayer)
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ content: MirrorController.Content) {
        displayLayer.isHidden = true
        imageLayer.isHidden = true
        previewLayer?.isHidden = true
        switch content {
        case .none:
            break
        case .video:
            displayLayer.isHidden = false
        case .image(let image):
            imageLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            imageLayer.isHidden = false
        case .capture(let session):
            if currentSession !== session {
                previewLayer?.removeFromSuperlayer()
                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspect
                layer?.addSublayer(preview)
                previewLayer = preview
                currentSession = session
            }
            previewLayer?.isHidden = false
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        imageLayer.frame = bounds
        previewLayer?.frame = bounds
        CATransaction.commit()
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var pressed = false

    /// Starts receiving keys once, unless the user is already typing somewhere else.
    private var didClaimFocus = false

    func takeFocusIfUnclaimed() {
        guard !didClaimFocus, let window, !(window.firstResponder is NSTextView) else { return }
        didClaimFocus = true
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        _ = onKey?(event)   // unhandled keys are dropped rather than beeping at every keystroke
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard acceptsInput, let point = normalizedPoint(for: event, clamped: false) else { return }
        pressed = true
        onPointer?(.down, point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed, let point = normalizedPoint(for: event, clamped: true) else { return }
        onPointer?(.move, point)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if let point = normalizedPoint(for: event, clamped: true) { onPointer?(.up, point) }
    }

    /// Maps a click to 0…1 inside the aspect-fitted picture; outside it that is nil, or the nearest edge when clamped.
    private func normalizedPoint(for event: NSEvent, clamped: Bool) -> CGPoint? {
        guard let size = frameSize, size.width > 0, size.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
        let x = (point.x - origin.x) / shown.width
        let y = 1 - (point.y - origin.y) / shown.height
        if clamped { return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)) }
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}
