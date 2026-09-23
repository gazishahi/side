import AppKit
import Heron

/// Search as its own circular glass button beside the floating bar (or a plain icon in the top
/// row) — a component, placement-agnostic like the rest.
final class GlassCircleButton: NSView {
    let button = PressButton()
    private let diameter: CGFloat

    init(symbol: String, accessibilityLabel: String, diameter: CGFloat = 40) {
        self.diameter = diameter
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter), heightAnchor.constraint(equalToConstant: diameter),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Puts a glass disc behind the icon. Off in the top row, where it is a plain toolbar icon.
    func setGlass(_ on: Bool) {
        subviews.filter { $0 !== button }.forEach { $0.removeFromSuperview() }
        guard on else { return }
        let glass = DS.makeGlass(cornerRadius: diameter / 2)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass, positioned: .below, relativeTo: button)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// A borderless button that tells its container about the press, so the whole glass piece
/// swells and springs back rather than only the glyph.
final class PressButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        let target = superview ?? self
        target.wantsLayer = true
        DS.Motion.press(target, down: true)
        super.mouseDown(with: event)  // tracks until the mouse is released
        DS.Motion.press(target, down: false)
    }
    override var mouseDownCanMoveWindow: Bool { false }
}
