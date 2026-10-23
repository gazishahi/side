# SwiftMath, vendored

[SwiftMath](https://github.com/mgriebling/SwiftMath) 1.7.3 (MIT, see LICENSE), which typesets
LaTeX math natively, for Side's Markdown preview.

Changed from upstream:

- Only the Latin Modern math font ships (`latinmodern-math.otf`, GUST Font License, beside it):
  upstream bundles twelve, about 7.5 MB. `MathFont` and `MTFontManager` name only Latin Modern.
- The font registration's debug logging is removed.

To update: copy upstream's `Sources/SwiftMath/MathBundle` and `MathRender`, then make the same
two changes.
