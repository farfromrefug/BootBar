import AVFoundation
import AppKit
import SwiftUI

struct MirrorView: NSViewRepresentable {
    let controller: MirrorController

    func makeNSView(context: Context) -> MirrorHostView {
        let view = MirrorHostView(displayLayer: controller.displayLayer)
        controller.rotationAnimator = { [weak view] clockwise, rotation in view?.animateRotation(clockwise: clockwise, contentRotation: rotation) }
        view.onPointer = { phase, point in controller.pointer(phase, at: point) }
        view.onKey = { event in controller.handleKey(event) }
        return view
    }

    func updateNSView(_ view: MirrorHostView, context: Context) {
        view.contentRotation = controller.contentRotation
        view.frameSize = controller.displaySize
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
    /// How much the video is turned to be upright (a simulator held in landscape), counterclockwise in radians.
    var contentRotation: CGFloat = 0 { didSet { if contentRotation != oldValue { needsLayout = true } } }

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

    /// The new picture turns into place, the way the screen of a phone does, instead of jumping. `contentRotation` is
    /// the new turn of a simulator's picture, applied here so that it and the animation start together.
    func animateRotation(clockwise: Bool, contentRotation newRotation: CGFloat?) {
        if let newRotation {
            contentRotation = newRotation
            layoutSubtreeIfNeeded()
        }
        let shrink = min(bounds.width / max(bounds.height, 1), bounds.height / max(bounds.width, 1))
        let extra = CATransform3DConcat(CATransform3DMakeScale(shrink, shrink, 1),
                                        CATransform3DMakeRotation(clockwise ? .pi / 2 : -.pi / 2, 0, 0, 1))
        let turn = CABasicAnimation(keyPath: "transform")
        turn.fromValue = CATransform3DConcat(displayLayer.transform, extra)
        turn.toValue = displayLayer.transform
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        let group = CAAnimationGroup()
        group.animations = [turn, fade]
        group.duration = 0.38
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        displayLayer.add(group, forKey: "rotation")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // a simulator's stream is its native portrait picture: lay the layer out on its side and turn it upright
        if contentRotation == 0 {
            displayLayer.transform = CATransform3DIdentity
            displayLayer.frame = bounds
        } else {
            displayLayer.transform = CATransform3DIdentity
            displayLayer.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            displayLayer.transform = CATransform3DMakeRotation(contentRotation, 0, 0, 1)
        }
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
