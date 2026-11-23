import AlloyTerminal
import AppKit
import Harness
import Metal
import SideTerminal
import Synchronization

/// The emulator's screen as AlloyTerminal's grid, as Side's AlloyTerminalSurface maps it.
/// Where setup E's CPU goes in sessions mode (TERMBENCH_THREADS=1): thread CPU around each kind of
/// work, in nanoseconds. The reader threads are dedicated, so their total is their CPU clock at
/// their last batch.
enum Account {
    static let parseShown = Atomic<UInt64>(0), parseHidden = Atomic<UInt64>(0), snapshot = Atomic<UInt64>(0)
    static let mainHop = Atomic<UInt64>(0), readers = Mutex<[ObjectIdentifier: UInt64]>([:])
    static var on: Bool { ProcessInfo.processInfo.environment["TERMBENCH_THREADS"] != nil }
    static func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    @discardableResult static func time<T>(_ into: borrowing Atomic<UInt64>, _ body: () -> T) -> T {
        let start = cpu(); defer { into.add(cpu() - start, ordering: .relaxed) }
        return body()
    }
    static func report(processCPU: Double, mainCPU: Double) {
        let s = { (v: UInt64) in String(format: "%.3f", Double(v) / 1e9) }
        let reader = readers.withLock { $0.values.reduce(0, +) }
        let known = Double(parseShown.load(ordering: .relaxed) + parseHidden.load(ordering: .relaxed) + snapshot.load(ordering: .relaxed) + reader) / 1e9 + mainCPU
        print("{\"account\":{\"readers\":\(s(reader)),\"parseShown\":\(s(parseShown.load(ordering: .relaxed))),\"parseHidden\":\(s(parseHidden.load(ordering: .relaxed))),\"snapshot\":\(s(snapshot.load(ordering: .relaxed))),\"main\":\(String(format: "%.3f", mainCPU)),\"mainHop\":\(s(mainHop.load(ordering: .relaxed))),\"rest\":\(String(format: "%.3f", processCPU - known))}}")
        fflush(stdout)
    }
}

final class ScreenSource: TerminalGridSource, @unchecked Sendable {
    // @unchecked: used only on the render thread.
    let reader: ScreenReader
    init(terminal: Terminal) { reader = ScreenReader(terminal: terminal) }

    func snapshot(into grid: TerminalGrid) -> Bool {
        Account.time(Account.snapshot) { snapshotTimed(into: grid) }
    }

    private func snapshotTimed(into grid: TerminalGrid) -> Bool {
        guard reader.update() else { return false }
        Self.copyImages(reader, into: grid)
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
                if c.style.contains(.cluster), !hidden { style.insert(.cluster) }
                let underline: TerminalCell.Underline = switch c.underline {
                case .none: .none
                case .single: .single
                case .double: .double
                case .curly: .curly
                case .dotted: .dotted
                case .dashed: .dashed
                }
                all[y * columns + x] = TerminalCell(scalar: hidden ? 0 : c.scalar,
                                                    foreground: c.foreground, background: c.background, style: style,
                                                    underline: underline, underlineColor: c.underlineColor)
            }
            }
            // The row's clusters, as the reader holds them while it hands the row over.
            let clusters = reader.rowClusters
            if !clusters.isEmpty || !grid.rowClusters[y].isEmpty { grid.rowClusters[y] = clusters }
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

    /// The reader's images, in cells, and their new pixels, for the renderer.
    static func copyImages(_ reader: ScreenReader, into grid: TerminalGrid) {
        if !reader.newImagePixels.isEmpty {
            grid.newImagePixels += reader.newImagePixels.map {
                TerminalImage.Pixels(key: .init(id: $0.key.id, generation: $0.key.generation), width: $0.width, height: $0.height, rgba: $0.rgba)
            }
        }
        guard reader.imagesChanged else { return }
        let unit = (width: Double(reader.imageCellSize.width), height: Double(reader.imageCellSize.height))
        grid.images = reader.images.map { image in
            let layer: TerminalImage.Layer = switch image.layer {
            case .belowBackground: .belowBackground
            case .belowText: .belowText
            case .aboveText: .aboveText
            }
            return TerminalImage(key: .init(id: image.key.id, generation: image.key.generation), layer: layer, z: image.z,
                                 x: Double(image.column) + Double(image.offsetX) / unit.width,
                                 y: Double(image.row) + Double(image.offsetY) / unit.height,
                                 width: Double(image.width) / unit.width, height: Double(image.height) / unit.height,
                                 sourceX: Double(image.sourceX), sourceY: Double(image.sourceY),
                                 sourceWidth: Double(image.sourceWidth), sourceHeight: Double(image.sourceHeight))
        }
    }
}

func makeTerminal(_ options: Options) -> Terminal {
    // TERMBENCH_SCROLLBACK=<lines>: another scrollback than Side's 10,000 lines.
    let lines = Int(ProcessInfo.processInfo.environment["TERMBENCH_SCROLLBACK"] ?? "") ?? 10_000
    let terminal = try! Terminal(columns: options.cols, rows: options.rows, scrollbackLines: lines)
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
        // Side's own reader (PseudoTerminalProcess, bridged as Ghostty's is), fed as Side's surface
        // feeds it; TERMBENCH_E_READER=harness: the harness's blocking reader, as before 2026-11-20.
        if ProcessInfo.processInfo.environment["TERMBENCH_E_READER"] != "harness" {
            startWithSidesReader(options: options)
            return
        }
        Run.shared.shot = { [view] path in MainActor.assumeIsolated { writeShot(view, to: path) } }
        let pty = PTYProcess(command: options.command, cols: options.cols, rows: options.rows)
        let terminal = self.terminal, view = self.view
        // The viewport's state (--view), set once the first 400 KB is shown, before the clock.
        if !options.view.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                switch options.view {
                case "selected": let s = TerminalSelection(terminal: terminal); s.selectAll(); keep.append(s)
                case "scrolled": terminal.scroll(byRows: -options.rows)
                default: print("view: \(options.view) unknown")
                }
                view.setNeedsFrame()
            }
        }
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + (options.view.isEmpty ? 0.3 : 1.3)) {
                Run.shared.begin()
                if options.view.isEmpty { _ = write(pty.master, "\n", 1) } else { Options.go() }
            }
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
        // TERMBENCH_NODRAW=1: parse only, no frames (the reader and parser's own ceiling).
        let draws = ProcessInfo.processInfo.environment["TERMBENCH_NODRAW"] != "1"
        pty.startReading(consume: { Stages.mark("echoRead"); Stages.mark("parse0"); terminal.feed($0); Stages.mark("parse1"); if draws { view.setNeedsFrame() } }, done: {
            var status: Int32 = 0
            waitpid(pty.pid, &status, 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = view.renderOffscreen()
                    Run.shared.frames = view.frames
                    if !Run.shared.options.view.isEmpty {
                        let bar = terminal.scrollbar
                        print("VIEW scrollbar total \(bar.total) offset \(bar.offset) length \(bar.length) scrolledBack \(bar.isScrolledBack)")
                    }
                    Run.shared.finish()
                }
            }
        })
    }
}

extension SetupE {
    /// As AlloyTerminalSurface.startProcess: output from the reader's thread to the main thread,
    /// then to a parse queue; the reader told whether batches are still on their way.
    func startWithSidesReader(options: Options) {
        Run.shared.shot = { [view] path in MainActor.assumeIsolated { writeShot(view, to: path) } }
        let terminal = self.terminal, view = self.view
        final class Count: Sendable { let value = Atomic<Int>(0) }
        let inFlight = Count()
        let parseQueue = DispatchQueue(label: "termbench.e.parse", qos: .userInteractive)
        let draws = ProcessInfo.processInfo.environment["TERMBENCH_NODRAW"] != "1"
        let process = PseudoTerminalProcess()
        keep.append(process)
        process.isConsumerBusy = { inFlight.value.load(ordering: .relaxed) > 0 }
        process.onOutput = { bytes in
            Stages.mark("echoRead")
            let copy = Array(bytes)
            inFlight.value.add(1, ordering: .relaxed)
            DispatchQueue.main.async {
                let again = Array(copy) // the surface's display copies once more
                parseQueue.async {
                    Stages.mark("parse0")
                    terminal.feed(again)
                    Stages.mark("parse1")
                    if draws { view.setNeedsFrame() }
                    inFlight.value.subtract(1, ordering: .relaxed)
                }
            }
        }
        process.onExit = { _ in
            // After the output already on its way: the main thread's queue, then the parse queue's.
            DispatchQueue.main.async {
                parseQueue.async {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = view.renderOffscreen()
                            Run.shared.frames = view.frames
                            if !Run.shared.options.view.isEmpty {
                                let bar = terminal.scrollbar
                                print("VIEW scrollbar total \(bar.total) offset \(bar.offset) length \(bar.length) scrolledBack \(bar.isScrolledBack)")
                            }
                            Run.shared.finish()
                        }
                    }
                }
            }
        }
        if !options.view.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                switch options.view {
                case "selected": let s = TerminalSelection(terminal: terminal); s.selectAll(); keep.append(s)
                case "scrolled": terminal.scroll(byRows: -options.rows)
                default: print("view: \(options.view) unknown")
                }
                view.setNeedsFrame()
            }
        }
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        if options.mode == "latency" {
            // Hidden sessions streaming meanwhile, each its own terminal read through Side's reader.
            for _ in 0..<options.load {
                let extra = makeTerminal(options)
                let queue = DispatchQueue(label: "termbench.e.load", qos: .userInteractive)
                let loader = PseudoTerminalProcess()
                loader.onOutput = { bytes in let copy = Array(bytes); queue.async { extra.feed(copy) } }
                loader.start(executable: options.loadCommand[0], arguments: Array(options.loadCommand.dropFirst()), environment: environment,
                             directory: nil, columns: options.cols, rows: options.rows)
                keep.append(extra); keep.append(loader)
            }
            let cell = view.cellSize
            // A typed key goes to the program as its characters, through process.write as Side's surface sends it.
            view.keyHandler = { event in
                guard let text = event.characters, !text.isEmpty else { return false }
                process.write(ArraySlice(Array(text.utf8)))
                Stages.mark("keySent")
                return true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [view] in
                let row = Latency.echoRow(view: view, cellSize: cell)
                Latency.run(window: view.window!, cell: { _ in row }, send: { process.write(ArraySlice(Array("X".utf8))) })
            }
        }
        guard process.start(executable: options.command[0], arguments: Array(options.command.dropFirst()), environment: environment,
                            directory: nil, columns: options.cols, rows: options.rows) else { print("couldn't start"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (options.view.isEmpty ? 0.3 : 1.3)) {
            Run.shared.begin()
            if options.view.isEmpty { process.write(ArraySlice(Array("\n".utf8))) } else { Options.go() }
        }
    }
}

@MainActor
final class SessionsE {
    let view: AlloyTerminalView
    var terminals: [Terminal] = []
    /// Kept here: the view holds its source weakly, and a source let go of draws nothing.
    let source: ScreenSource
    var exited = 0
    /// Side's readers, kept for the run.
    var keepAlive: [AnyObject] = []
    init(options: Options) {
        view = makeView(options)
        terminals = (0..<options.sessions).map { _ in makeTerminal(options) }
        source = ScreenSource(terminal: terminals[0])
        view.source = source
        Run.shared.grid = "\(options.cols)x\(options.rows)"
    }
    func start(options: Options) {
        // Side's own reader for every session, fed as Side's surfaces feed theirs (each tab is a
        // surface, on screen or not); TERMBENCH_E_READER=harness: the harness's reader, as before.
        if ProcessInfo.processInfo.environment["TERMBENCH_E_READER"] != "harness" {
            startWithSidesReader(options: options)
            return
        }
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

extension SessionsE {
    func startWithSidesReader(options: Options) {
        final class Count: Sendable { let value = Atomic<Int>(0) }
        let view = view
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var processes: [PseudoTerminalProcess] = []
        // TERMBENCH_NODRAW=1: nothing drawn, so the rest of the work can be told from drawing.
        let draws = ProcessInfo.processInfo.environment["TERMBENCH_NODRAW"] != "1"
        for (i, terminal) in terminals.enumerated() {
            let shown = i == 0 && draws
            let inFlight = Count()
            let parseQueue = DispatchQueue(label: "termbench.e.parse.\(i)", qos: .userInteractive)
            let process = PseudoTerminalProcess()
            process.isConsumerBusy = { inFlight.value.load(ordering: .relaxed) > 0 }
            let readerID = ObjectIdentifier(inFlight)
            process.onOutput = { bytes in
                let copy = Array(bytes)
                inFlight.value.add(1, ordering: .relaxed)
                let readerCPU = Account.cpu()
                Account.readers.withLock { $0[readerID] = readerCPU }
                DispatchQueue.main.async {
                    let hop = Account.cpu()
                    let again = Array(copy) // the surface's display copies once more
                    parseQueue.async {
                        if shown { Account.time(Account.parseShown) { terminal.feed(again) } } else { Account.time(Account.parseHidden) { terminal.feed(again) } }
                        if shown { view.setNeedsFrame() }
                        inFlight.value.subtract(1, ordering: .relaxed)
                    }
                    Account.mainHop.add(Account.cpu() - hop, ordering: .relaxed)
                }
            }
            process.onExit = { _ in
                // After the output already on its way: the main thread's queue, then the parse queue's.
                DispatchQueue.main.async {
                    parseQueue.async {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self.exited += 1
                                if self.exited == self.terminals.count { Run.shared.frames = self.view.frames; Run.shared.finish() }
                            }
                        }
                    }
                }
            }
            guard process.start(executable: options.command[0], arguments: Array(options.command.dropFirst()), environment: environment,
                                directory: nil, columns: options.cols, rows: options.rows) else { print("couldn't start"); exit(1) }
            processes.append(process)
        }
        keepAlive = processes
        if Account.on { Run.onReport = { Account.report(processCPU: $0, mainCPU: $1) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Run.shared.begin()
            for p in processes { p.write(ArraySlice(Array("\n".utf8))) }
        }
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
