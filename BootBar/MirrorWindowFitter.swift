import AppKit

/// Keeps the window in the proportions of the picture while the tools panel is closed, so that dragging an edge makes
/// the picture bigger or smaller instead of leaving empty space beside it. It sits in front of the window's delegate
/// (SwiftUI's) and only answers `windowWillResize`, which AppKit asks during a drag, not when BootBar sets the frame.
final class MirrorWindowFitter: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var original: NSWindowDelegate?

    /// The picture alone fills the window: the tools panel is closed, and a device is shown.
    var isActive = false
    /// Width over height of the picture.
    var aspect: CGFloat = 0.5
    /// The strip of buttons under the picture, which belongs to the column but not to the picture.
    var barHeight: CGFloat = 0
    /// What the window has around the area that holds the picture: the sidebar, the title bar.
    private var chrome = CGSize.zero

    func attach(_ window: NSWindow?) {
        guard let window, window.delegate !== self else { return }
        self.window = window
        original = window.delegate
        window.delegate = self
    }

    /// Call whenever the area that holds the picture changes size.
    func measure(detail: CGSize) {
        guard let window else { return }
        chrome = CGSize(width: window.frame.width - detail.width, height: window.frame.height - detail.height)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        var size = frameSize
        if isActive, aspect > 0, !sender.styleMask.contains(.fullScreen) {
            let current = sender.frame.size
            let widthDrives = abs(frameSize.width - current.width) >= abs(frameSize.height - current.height)
            var pictureWidth = widthDrives ? frameSize.width - chrome.width : (frameSize.height - chrome.height - barHeight) * aspect
            if let visible = sender.screen?.visibleFrame {
                pictureWidth = min(pictureWidth, visible.width - chrome.width,
                                   (visible.height - chrome.height - barHeight) * aspect)
            }
            pictureWidth = max(pictureWidth, 240)
            size = NSSize(width: pictureWidth + chrome.width, height: pictureWidth / aspect + barHeight + chrome.height)
        }
        if let original, original.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))) {
            return original.windowWillResize?(sender, to: size) ?? size
        }
        return size
    }

    // everything else goes to the delegate that was there before
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
