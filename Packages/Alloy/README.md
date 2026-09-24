# Alloy

Alloy is the editing engine behind [Side](https://github.com/gazishahi/side-releases)'s Make
stage: a document model built for large files and agents that edit alongside you, with a
GPU renderer to follow.

**Status: pre-release, under construction.** `AlloyCore` is built; `AlloyRender` (Metal) and
`AlloyAppKit` (the view) are next. The design is Side's `SIDE_RFC_ALLOY.md`.

## AlloyCore

- **`Rope`**: text as a persistent balanced tree of chunks. Every node caches its UTF-8, UTF-16
  and line-break counts, so lines and offsets resolve in O(log n), and copying is free (undo
  snapshots and background work share the tree).
- **`TextBuffer`**: editing with multiple selections, grouped undo and redo, and change events
  that replay exactly (for incremental parsers and language servers).

Offsets are UTF-16, the unit AppKit and LSP use; UTF-8 conversions are there for tree-sitter.

## Development

```sh
swift test
swift run -c release AlloyBenchmarks
```

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
