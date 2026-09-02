import AppKit

/// A flat, guaranteed-dark background for chrome surfaces (window root, tab bars) — matching
/// the editor's own near-black tone exactly, no vibrancy/material involved. An earlier version
/// of this used an NSVisualEffectView (.hudWindow, translucent) for a "glass" look, but that
/// material's actual rendered brightness turned out to still read as too light next to the
/// editor's explicit solid color, and isn't something reliably tunable without live visual
/// verification — a plain solid fill removes that ambiguity entirely.
enum ChromeBackground {
    static let color = DS.Color.chrome

    static func install(in view: NSView) {
        let fill = NSView()
        fill.wantsLayer = true
        fill.bindLayerBackground(color)
        fill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fill, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: view.topAnchor),
            fill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fill.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
