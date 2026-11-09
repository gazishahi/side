import AppKit
import SideAgents

/// A flat, guaranteed-dark background for chrome surfaces (window root, tab bars) — matching
/// the editor's own near-black tone exactly, no vibrancy/material involved. An earlier version
/// of this used an NSVisualEffectView (.hudWindow, translucent) for a "glass" look, but that
/// material's actual rendered brightness turned out to still read as too light next to the
/// editor's explicit solid color, and isn't something reliably tunable without live visual
/// verification — a plain solid fill removes that ambiguity entirely.
///
/// Translucent background (DS.Translucency) is the one exception, and it's the person's choice:
/// the window's own backdrop (`backdrop`, the shell's) blurs what's behind the window and lays
/// the canvas tone over it; a stage's fill goes clear so that tone is laid once.
enum ChromeBackground {
    static let color = DS.Color.canvas

    @discardableResult
    static func install(in view: NSView, backdrop: Bool = false) -> NSView {
        let fill = backdrop ? WindowBackdrop() : NSView()
        fill.wantsLayer = true
        if !backdrop { fill.bindLayerBackground(DS.Translucency.under(color)) }
        fill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fill, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: view.topAnchor),
            fill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fill.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return fill
    }
}

/// The window's backdrop: the canvas, or, translucent, the desktop blurred behind the window
/// under the canvas tone. Keeps its window's opacity in step (DS.Translucency.apply).
final class WindowBackdrop: NSView {
    private let blur = NSVisualEffectView()
    private let tintView = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Behind the window, and active whether or not the window is key: an inactive window
        // going grey would read as a different surface, not a background window.
        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        blur.state = .active
        tintView.wantsLayer = true
        for view in [blur, tintView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        NotificationCenter.default.addObserver(self, selector: #selector(apply), name: DS.Appearance.didChangeNotification, object: nil)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    @objc private func apply() {
        let translucent = DS.Translucency.isOn
        blur.isHidden = !translucent
        tintView.bindLayerBackground(translucent ? DS.Translucency.tint : ChromeBackground.color)
        if let window { DS.Translucency.apply(to: window) }
    }
}
