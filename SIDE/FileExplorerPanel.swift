import AppKit
import SideAgents

final class FileExplorerPanel: NSPanel {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
