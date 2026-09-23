import AppKit

/// Keeps a panel at a user-adjustable offset from the selected target window.
/// Coordinates are measured from the target's upper-left corner so moving or
/// resizing the target keeps the overlay in the same place relative to it.
@MainActor
final class TargetWindowAnchor {
    private let defaultsKey: String
    private var targetFrame: NSRect?
    private var offset: NSPoint?
    private var applying = false

    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        if let value = UserDefaults.standard.string(forKey: defaultsKey) {
            offset = NSPointFromString(value)
        }
    }

    func follow(_ target: NSRect, window: NSWindow, defaultOffset: (NSRect, NSWindow) -> NSPoint) {
        let position = offset ?? defaultOffset(target, window)
        targetFrame = target
        let origin = NSPoint(
            x: target.minX + position.x,
            y: target.maxY - position.y - window.frame.height
        )
        guard window.frame.origin != origin else { return }
        applying = true
        window.setFrameOrigin(origin)
        applying = false
    }

    func recordMove(of window: NSWindow) {
        guard !applying, let targetFrame else { return }
        let newOffset = NSPoint(
            x: window.frame.minX - targetFrame.minX,
            y: targetFrame.maxY - window.frame.maxY
        )
        offset = newOffset
        UserDefaults.standard.set(NSStringFromPoint(newOffset), forKey: defaultsKey)
    }

    func detach() { targetFrame = nil }
}
