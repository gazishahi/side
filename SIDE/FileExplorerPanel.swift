import AppKit
import SideAgents

/// The explorer in the window: it takes the clicks it covers, and a press on it never drags the
/// window.
final class ExplorerHost: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
}

final class ExplorerOutlineView: NSOutlineView {
    var onEscape: (() -> Void)?
    var onEnter: (() -> Void)?
    var onTrash: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()
        case 36: onEnter?()
        case 51 where event.modifierFlags.contains(.command): onTrash?()  // ⌘⌫, as in Finder
        default: super.keyDown(with: event)
        }
    }
}
