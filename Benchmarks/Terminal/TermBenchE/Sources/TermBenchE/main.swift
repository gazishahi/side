import AlloyTerminal
import AppKit
import Harness
import Metal
import SideTerminal

/// The emulator's screen as AlloyTerminal's grid, as Side's AlloyTerminalSurface maps it.
final class ScreenSource: TerminalGridSource, @unchecked Sendable {
    // @unchecked: used only on the render thread.
    let reader: ScreenReader
    init(terminal: Terminal) { reader = ScreenReader(terminal: terminal) }

    func snapshot(into grid: TerminalGrid) -> Bool {
        guard reader.update() else { return false }
        let columns = grid.columns
        reader.forEachChangedRow { y, cells in
            guard y < grid.rows else { return }
            // A row through one buffer: the grid's subscript checks access and bounds per cell,
            // which was a good part of a frame (Benchmarks/Terminal/results/2026-11-13-tier1).
            let count = min(cells.count, columns)
            grid.cells.withUnsafeMutableBufferPointer { all in
            for x in 0..<count {
                let c = cells[x]
                var style: TerminalCell.Style = []
                if c.style.contains(.bold) { style.insert(.bold) }
                if c.style.contains(.italic) { style.insert(.italic) }
                if c.style.contains(.strikethrough) { style.insert(.strikethrough) }
                if c.style.contains(.wide) { style.insert(.wide) }
                if c.style.contains(.spacer) { style.insert(.spacer) }
                if c.style.contains(.overline) { style.insert(.overline) }
                if c.style.contains(.selected) { style.insert(.selected) }
                if c.style.contains(.blink) { style.insert(.blink) }
                let hidden = c.style.contains(.invisible)
                let underline: TerminalCell.Underline = switch c.underline {
                case .none: .none
                case .single: .single
                case .double: .double
                case .curly: .curly
                case .dotted: .dotted
                case .dashed: .dashed
                }
                all[y * columns + x] = TerminalCell(scalar: hidden ? 0 : c.scalar, cluster: hidden ? nil : c.cluster,
                                                    foreground: c.foreground, background: c.background, style: style,
                                                    underline: underline, underlineColor: c.underlineColor)
            }
            }
            grid.dirty[y] = true
        }
        let cursor = reader.cursor
        let shape: TerminalCursor.Shape = switch cursor.shape {
        case .bar: .bar
        case .underline: .underline
        case .block: .block
        case .hollowBlock: .hollowBlock
        }
        grid.cursor = TerminalCursor(column: cursor.column, row: cursor.row, visible: cursor.visible, shape: shape,
                                     blinking: cursor.blinking, color: reader.cursorColor)
        return true
    }
}

func makeTerminal(_ options: Options) -> Terminal {
    let terminal = try! Terminal(columns: options.cols, rows: options.rows)
    terminal.setDefaultColors(foreground: Theme.foreground, background: Theme.background)
    return terminal
}

let theme: TerminalTheme = {
    let bg = Theme.background
    return TerminalTheme(background: SIMD4(Float((bg >> 16) & 0xFF) / 255, Float((bg >> 8) & 0xFF) / 255, Float(bg & 0xFF) / 255, 1), cursor: Theme.foreground)
}()

@MainActor
func makeView(_ options: Options) -> AlloyTerminalView {
    let font = TerminalFont(name: options.fontName, size: options.fontSize)
    let cell = font.cellSize
    return try! AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: CGFloat(options.cols) * cell.width, height: CGFloat(options.rows) * cell.height),
                                  font: font, theme: theme)
}

@MainActor
func writeShot(_ view: AlloyTerminalView, to path: String) {
    guard let texture = view.renderOffscreen() else { return }
    let width = texture.width, height = texture.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let image = context?.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

@MainActor
final class SetupE {
    var keep: [AnyObject] = []
    let view: AlloyTerminalView
    let terminal: Terminal
    let source: ScreenSource
    init(options: Options) {
        view = makeView(options)
        terminal = makeTerminal(options)
        source = ScreenSource(terminal: terminal)
        view.source = source
        Run.shared.grid = "\(options.cols)x\(options.rows)"
    }
    func start(options: Options) {
        Run.shared.shot = { [view] path in MainActor.assumeIsolated { writeShot(view, to: path) } }
        let pty = PTYProcess(command: options.command, cols: options.cols, rows: options.rows)
        let terminal = self.terminal, view = self.view
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Run.shared.begin(); _ = write(pty.master, "\n", 1) }
        }
        if options.mode == "latency" {
            for _ in 0..<options.load {
                let extra = makeTerminal(options)
                let p = PTYProcess(command: options.loadCommand, cols: options.cols, rows: options.rows)
                p.startReading(consume: { extra.feed($0) }, done: {})
                keep.append(extra)
            }
            let cell = view.cellSize
            // A typed key goes to the PTY as its characters, as Side's surface sends it.
            view.keyHandler = { event in
                guard let text = event.characters, !text.isEmpty else { return false }
                let bytes = Array(text.utf8)
                _ = bytes.withUnsafeBytes { write(pty.master, $0.baseAddress, $0.count) }
                Stages.mark("keySent")
                return true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [view] in
                let row = Latency.echoRow(view: view, cellSize: cell)
                Latency.run(window: view.window!, cell: { _ in row }, send: { _ = write(pty.master, "X", 1) })
            }
        }
        pty.startReading(consume: { Stages.mark("echoRead"); Stages.mark("parse0"); terminal.feed($0); Stages.mark("parse1"); view.setNeedsFrame() }, done: {
            var status: Int32 = 0
            waitpid(pty.pid, &status, 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = view.renderOffscreen()
                    Run.shared.frames = view.frames
                    Run.shared.finish()
                }
            }
        })
    }
}

@MainActor
final class SessionsE {
    let view: AlloyTerminalView
    var terminals: [Terminal] = []
    /// Kept here: the view holds its source weakly, and a source let go of draws nothing.
    let source: ScreenSource
    var exited = 0
    init(options: Options) {
        view = makeView(options)
        terminals = (0..<options.sessions).map { _ in makeTerminal(options) }
        source = ScreenSource(terminal: terminals[0])
        view.source = source
        Run.shared.grid = "\(options.cols)x\(options.rows)"
    }
    func start(options: Options) {
        var ptys: [PTYProcess] = []
        let view = view
        for (i, terminal) in terminals.enumerated() {
            let pty = PTYProcess(command: options.command, cols: options.cols, rows: options.rows)
            ptys.append(pty)
            let shown = i == 0
            pty.startReading(consume: { terminal.feed($0); if shown { view.setNeedsFrame() } }, done: {
                var status: Int32 = 0
                waitpid(pty.pid, &status, 0)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self.exited += 1
                    if self.exited == self.terminals.count { Run.shared.frames = self.view.frames; Run.shared.finish() }
                } }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Run.shared.begin(); for p in ptys { _ = write(p.master, "\n", 1) } }
    }
}

/// A frame's cost: the snapshot into the grid and the renderer's CPU work, and its GPU time,
/// drawn offscreen at 2× as C's and D's are.
@MainActor func frameCost(_ options: Options) {
    let device = MTLCreateSystemDefaultDevice()!
    let font = TerminalFont(name: options.fontName, size: options.fontSize)
    let renderer = try! TerminalRenderer(device: device, font: font, theme: theme)
    let terminal = makeTerminal(options)
    let source = ScreenSource(terminal: terminal)
    let grid = TerminalGrid(columns: options.cols, rows: options.rows, foreground: Theme.foreground)
    let cell = font.cellSize
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(CGFloat(options.cols) * cell.width * 2),
                                                     height: Int(CGFloat(options.rows) * cell.height * 2), mipmapped: false)
    d.usage = [.renderTarget]
    d.storageMode = .private
    let target = device.makeTexture(descriptor: d)!
    // TERMBENCH_SPLIT=1: also the frame's two halves, the snapshot and the drawing (stderr).
    let split = ProcessInfo.processInfo.environment["TERMBENCH_SPLIT"] == "1"
    var snaps: [Double] = [], draws: [Double] = []
    FrameCost.run(options: options, feed: { bytes in terminal.feed(bytes) }, frame: { oneRow in
        let start = Metrics.now()
        _ = source.snapshot(into: grid)
        let mid = Metrics.now()
        let buffer = renderer.draw(grid, scale: 2, into: target)
        if !oneRow {
            snaps.append((mid - start) * 1000); draws.append((Metrics.now() - mid) * 1000)
            if split, snaps.count % 20 == 0 {
                let a = snaps.sorted(), b = draws.sorted()
                FileHandle.standardError.write("SPLIT n=\(a.count) snapshot median \(a[a.count / 2]) ms, draw median \(b[b.count / 2]) ms\n".data(using: .utf8)!)
            }
        }
        let cpu = (Metrics.now() - start) * 1000
        buffer?.waitUntilCompleted()
        let gpu = buffer.map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 } ?? -1
        return (cpu, gpu)
    })
}

let app = NSApplication.shared
Metrics.captureMainThread()
let options = MainActor.assumeIsolated { Run.shared.options }
var keep: AnyObject?
var window: NSWindow?
DispatchQueue.main.async {
    MainActor.assumeIsolated {
        if options.mode == "framecost" { frameCost(options); return }
        if options.mode == "sessions" {
            let e = SessionsE(options: options); keep = e
            window = makeWindow(content: e.view, options: options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { e.start(options: options) }
            return
        }
        let e = SetupE(options: options); keep = e
        window = makeWindow(content: e.view, options: options)
        window?.makeFirstResponder(e.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { e.start(options: options) }
    }
}
app.run()
