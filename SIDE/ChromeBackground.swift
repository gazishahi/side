import AppKit

/// A translucent, dark "glass" background for chrome surfaces (window root, tab bars) — never
/// for the editor's own text-editing surface, which keeps its explicit solid dark color since
/// a surface that guarantees text contrast shouldn't be translucent. `.hudWindow` is Apple's
/// dedicated always-dark, always-translucent material (the look behind Quick Look's HUD,
/// Spotlight, etc.), so this doesn't require forcing the whole app into dark appearance to get
/// a consistent charcoal-glass look regardless of the system's current appearance.
enum ChromeBackground {
    static func install(in view: NSView) {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(effect, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: view.topAnchor),
            effect.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Belt-and-suspenders on top of the vibrancy: without live visual verification
        // available this session, don't leave "still looks too bright" to how dark a given
        // material happens to render — a solid low-alpha black wash guarantees the result
        // reads as unambiguously dark regardless.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tint, positioned: .above, relativeTo: effect)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: view.topAnchor),
            tint.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
