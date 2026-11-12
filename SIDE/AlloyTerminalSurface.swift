import AlloyTerminal
import AppKit
import Metal
import SideSessionsKit
import SideTerminal

/// The terminal engine of docs/SIDE_RFC_TERMINAL_ENGINE.md behind `TerminalSurface`: libghostty-vt
/// (SideTerminal) parses on a queue of its own, Alloy (AlloyTerminal) draws on a render thread of
/// its own, and keys go through libghostty-vt's encoder, translated from NSEvent the way
/// Ghostty's macOS app does. Not yet: selection and copy, links, scrolling back, IME preedit,
/// mouse reporting (the RFC's step 4).
final class AlloyTerminalSurface: NSView, TerminalSurface {
    weak var surfaceDelegate: TerminalSurfaceDelegate?
    var keeper: KeeperLink? { didSet { syncKeeperSize() } }

    var onBell: (() -> Void)?
    var onFileLinkRequested: ((String) -> Bool)?
    var onLineSubmitted: ((String) -> Void)?
    var onDataReceived: (() -> Void)?
    var onRawDataReceived: ((ArraySlice<UInt8>) -> Void)?
    var onInputWithoutKeeper: (() -> Bool)?
    var onAgentReport: (([String]) -> Void)?
    var isDarkBackground: () -> Bool = { true }
    var programListensForColorScheme: () -> Bool = { false }

    var font: NSFont {
        didSet { if font != oldValue { replaceScreen() } }
    }

    private let terminal: Terminal
    private let keys: KeyEncoder
    private let source: ScreenSource
    private var screen: AlloyTerminalView
    /// Output is parsed here, off the main thread, in arrival order.
    private let parseQueue = DispatchQueue(label: "side.terminal.parse", qos: .userInteractive)
    private var process: PseudoTerminalProcess?
    private var colorScheme = ColorSchemeReports()
    private var lines = SubmittedLineTracker()
    private var agentReports = OSCWatcher(code: 6973)
    private var theme: TerminalSurfaceTheme?
    /// While a key is being translated: what the input system typed for it.
    private var typedForKey: [String]?

    override init(frame: NSRect) {
        let font = DS.Text.Fonts.font(.terminal, size: DS.Text.CodeSize.terminal)
        self.font = font
        let relay = EventRelay()
        var events = Terminal.Events()
        events.reply = { bytes in DispatchQueue.main.async { relay.surface?.send(bytes: bytes[...]) } }
        events.title = { title in DispatchQueue.main.async { relay.surface.map { $0.surfaceDelegate?.terminalSurface($0, titleChanged: title) } } }
        events.workingDirectory = { url in DispatchQueue.main.async { relay.surface.map { $0.surfaceDelegate?.terminalSurface($0, directoryChanged: url) } } }
        events.bell = { DispatchQueue.main.async { relay.surface?.onBell?() } }
        let cell = TerminalFont(font as CTFont).cellSize
        // Force-unwrapped: creating a terminal fails only when libghostty-vt can't allocate.
        terminal = try! Terminal(columns: max(2, Int(frame.width / cell.width)), rows: max(2, Int(frame.height / cell.height)), events: events)
        keys = KeyEncoder(terminal: terminal)
        source = ScreenSource(reader: ScreenReader(terminal: terminal))
        screen = Self.makeScreen(frame: NSRect(origin: .zero, size: frame.size), font: font)
        super.init(frame: frame)
        relay.surface = self
        install(screen)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private static func makeScreen(frame: NSRect, font: NSFont) -> AlloyTerminalView {
        // Force-unwrapped: fails only on a Mac without Metal, which Side doesn't run on.
        try! AlloyTerminalView(frame: frame, font: TerminalFont(font as CTFont), theme: TerminalTheme(background: SIMD4(0, 0, 0, 1), cursor: 0xFFFFFF))
    }

    private func install(_ view: AlloyTerminalView) {
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        view.source = source
        view.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        view.onText = { [weak self] text in
            guard let self else { return }
            if self.typedForKey != nil { self.typedForKey?.append(text) } else { self.send(text: text) }
        }
        view.onGridResize = { [weak self] columns, rows in self?.gridResized(columns: columns, rows: rows) }
        addSubview(view)
        if let theme { applyTheme(theme) }
        gridResized(columns: view.columns, rows: view.rows)
    }

    /// A new font is a new renderer (its atlas and metrics are the font's).
    private func replaceScreen() {
        let wasFirstResponder = window?.firstResponder === screen
        screen.removeFromSuperview()
        screen = Self.makeScreen(frame: bounds, font: font)
        install(screen)
        if wasFirstResponder { window?.makeFirstResponder(screen) }
    }

    private func gridResized(columns: Int, rows: Int) {
        terminal.resize(columns: columns, rows: rows, cellWidth: Int(screen.cellSize.width.rounded()), cellHeight: Int(screen.cellSize.height.rounded()))
        process?.resize(columns: columns, rows: rows)
        syncKeeperSize()
        screen.setNeedsFrame()
    }

    // MARK: Session

    func syncKeeperSize() { keeper?.resize(cols: columns, rows: rows) }
    var columns: Int { screen.columns }
    var rows: Int { screen.rows }
    var scrollbackLines: Int { 10_000 }

    // MARK: Output and input

    func receive(_ bytes: ArraySlice<UInt8>) {
        onDataReceived?()
        onRawDataReceived?(bytes)
        for event in colorScheme.consume(bytes) where event == .query { send(text: SideTerminalView.colorSchemeReport(dark: isDarkBackground())) }
        for report in agentReports.consume(bytes) {
            onAgentReport?(report.split(separator: ";", omittingEmptySubsequences: false).map(String.init))
        }
        display(bytes)
        scheduleAccessibilityValueUpdate()
    }

    func display(_ bytes: ArraySlice<UInt8>) {
        let copy = Array(bytes), terminal = terminal, screen = screen
        parseQueue.async {
            terminal.feed(copy)
            screen.setNeedsFrame()
        }
    }

    func send(text: String) { send(bytes: ArraySlice(Array(text.utf8))) }

    func send(bytes: ArraySlice<UInt8>) {
        for line in lines.consume(bytes) { onLineSubmitted?(line) }
        if let keeper {
            keeper.input(bytes)
        } else if onInputWithoutKeeper?() != true {
            process?.write(bytes)
        }
    }

    func paste(text: String) {
        send(text: terminal.isModeSet(2004) ? "\u{1B}[200~" + text + "\u{1B}[201~" : text)
    }

    func insertText(_ string: Any, replacementRange: NSRange) { screen.insertText(string, replacementRange: replacementRange) }

    // MARK: Keys

    /// A typed key, as Ghostty's macOS app handles one (SurfaceView_AppKit.keyDown): translated
    /// with the modifiers the encoder says (option as Meta or not), run through the input system
    /// for the text it types, then encoded by the terminal's modes. Command keys are left to the
    /// menus.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        if flags.contains(.command) { return false }
        let modifiers = Self.modifiers(flags)
        let translation = keys.translationModifiers(for: modifiers)
        var translationFlags = flags
        for (flag, modifier) in [(NSEvent.ModifierFlags.shift, KeyInput.Modifiers.shift), (.control, .control), (.option, .option)] {
            if translation.contains(modifier) { translationFlags.insert(flag) } else { translationFlags.remove(flag) }
        }
        let translationEvent = translationFlags == flags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationFlags, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: translationFlags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        typedForKey = []
        screen.interpretKeyEvents([translationEvent])
        let typed = typedForKey ?? []
        typedForKey = nil

        // Control and command never take part in producing text; the rest are taken as used up.
        let consumed = Self.modifiers(translationFlags.subtracting([.control, .command]))
        let text = typed.isEmpty ? Self.keyText(translationEvent) : typed.joined()
        var unshifted: UInt32 = 0
        if let characters = event.characters(byApplyingModifiers: []), let first = characters.unicodeScalars.first { unshifted = first.value }
        let key = KeyInput(action: event.isARepeat ? .repeat : .press, keycode: event.keyCode, modifiers: modifiers, consumed: consumed,
                           text: text, unshifted: unshifted)
        let bytes = keys.encode(key)
        if !bytes.isEmpty { send(bytes: bytes[...]) }
        return true
    }

    /// The text for a key that the input system didn't type: none for a function key (the
    /// private-use range AppKit gives arrows and F-keys), and a control character's key without
    /// control (the encoder makes the control character itself).
    private static func keyText(_ event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        if characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyInput.Modifiers {
        var modifiers: KeyInput.Modifiers = []
        let raw = flags.rawValue
        if flags.contains(.shift) { modifiers.insert(.shift); if raw & 0x04 != 0 { modifiers.insert(.rightShift) } }
        if flags.contains(.control) { modifiers.insert(.control); if raw & 0x2000 != 0 { modifiers.insert(.rightControl) } }
        if flags.contains(.option) { modifiers.insert(.option); if raw & 0x40 != 0 { modifiers.insert(.rightOption) } }
        if flags.contains(.command) { modifiers.insert(.command); if raw & 0x10 != 0 { modifiers.insert(.rightCommand) } }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        return modifiers
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(screen) ?? false }

    // MARK: A process of its own

    func startProcess(executable: String, arguments: [String], environment: [String], currentDirectory: String?) {
        let process = PseudoTerminalProcess()
        process.onOutput = { [weak self] bytes in
            let copy = Array(bytes)
            DispatchQueue.main.async { self?.receive(copy[...]) }
        }
        process.onExit = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.surfaceDelegate?.terminalSurface(self, processTerminated: status)
            }
        }
        self.process = process
        process.start(executable: executable, arguments: arguments, environment: environment, directory: currentDirectory, columns: columns, rows: rows)
    }

    var processID: pid_t { process?.pid ?? 0 }
    var processTerminalDescriptor: Int32 { process?.master ?? -1 }
    func terminateProcess() { process?.terminate() }

    // MARK: Appearance

    func applyTheme(_ theme: TerminalSurfaceTheme) {
        self.theme = theme
        let foreground = Self.rgb(theme.foreground), background = Self.rgb(theme.background)
        terminal.setDefaultColors(foreground: foreground, background: background)
        terminal.setPalette(theme.palette.map(Self.rgb))
        let bg = theme.background.usingColorSpace(.sRGB) ?? theme.background
        screen.theme = TerminalTheme(background: SIMD4(Float(bg.redComponent), Float(bg.greenComponent), Float(bg.blueComponent), Float(theme.backgroundOpacity)),
                                     cursor: foreground)
        screen.setNeedsFrame()
    }

    var backgroundColor: NSColor {
        let color = theme?.background ?? .black
        return color.usingColorSpace(.sRGB) ?? color
    }

    func colorSchemeChanged() {
        guard colorScheme.enabled || programListensForColorScheme() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.send(text: SideTerminalView.colorSchemeReport(dark: self.isDarkBackground()))
        }
    }

    var reportsColorSchemeForTesting: Bool { colorScheme.enabled }

    private static func rgb(_ color: NSColor) -> UInt32 {
        let c = color.usingColorSpace(.sRGB) ?? color
        func channel(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return channel(c.redComponent) << 16 | channel(c.greenComponent) << 8 | channel(c.blueComponent)
    }

    // MARK: Reading

    func visibleText() -> String { terminal.text() }
    func bufferText() -> String { terminal.text(scrollback: true) }

    func snapshotImage() -> NSImage? {
        guard let texture = screen.renderOffscreen() else { return nil }
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }

    // MARK: Drops (as SideTerminalView)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        SideTerminalView.canDrop(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = SideTerminalView.droppedPaths(sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        window?.makeFirstResponder(self)
        paste(text: paths.map(SideTerminalView.shellEscaped).joined(separator: " ") + " ")
        return true
    }

    // MARK: Accessibility (as SideTerminalView: one text area, the visible screen)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityHelp() -> String? { "Terminal output. Type to send input to the shell." }
    override func accessibilityValue() -> Any? { visibleText() }
    override func accessibilityNumberOfCharacters() -> Int { visibleText().count }

    private var accessibilityUpdate: DispatchWorkItem?

    private func scheduleAccessibilityValueUpdate() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        accessibilityUpdate?.cancel()
        let update = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        accessibilityUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: update)
    }
}

/// Terminal events arrive on the parse queue, before the surface exists to capture: they reach
/// it through this.
private final class EventRelay: @unchecked Sendable {
    // @unchecked: read only on the main thread, set once there.
    weak var surface: AlloyTerminalSurface?
}

/// The render thread's copy of the screen, from libghostty-vt's render state into Alloy's grid.
private final class ScreenSource: TerminalGridSource, @unchecked Sendable {
    // @unchecked: used only on the render thread.
    private let reader: ScreenReader

    init(reader: ScreenReader) { self.reader = reader }

    func snapshot(into grid: TerminalGrid) -> Bool {
        guard reader.update() else { return false }
        reader.forEachChangedRow { y, cells in
            guard y < grid.rows else { return }
            for x in 0..<min(cells.count, grid.columns) {
                let c = cells[x]
                var style: TerminalCell.Style = []
                if c.style.contains(.bold) { style.insert(.bold) }
                if c.style.contains(.italic) { style.insert(.italic) }
                if c.style.contains(.strikethrough) { style.insert(.strikethrough) }
                if c.style.contains(.wide) { style.insert(.wide) }
                if c.style.contains(.spacer) { style.insert(.spacer) }
                if c.underline != .none { style.insert(.underline) }
                let hidden = c.style.contains(.invisible)
                grid[x, y] = TerminalCell(scalar: hidden ? 0 : c.scalar, cluster: hidden ? nil : c.cluster,
                                          foreground: c.foreground, background: c.background, style: style)
            }
            grid.dirty[y] = true
        }
        let cursor = reader.cursor
        let shape: TerminalCursor.Shape = switch cursor.shape {
        case .bar: .bar
        case .underline: .underline
        case .block, .hollowBlock: .block
        }
        grid.cursor = TerminalCursor(column: cursor.column, row: cursor.row, visible: cursor.visible, shape: shape)
        return true
    }
}

/// OSC sequences of one code in a byte stream, across reads: `ESC ] <code> ; <payload>` ended by
/// BEL or ESC \.
struct OSCWatcher {
    let prefix: [UInt8]
    private var matched = 0
    private var payload: [UInt8]?
    private var sawEscape = false

    init(code: Int) { prefix = Array("\u{1B}]\(code);".utf8) }

    mutating func consume<Bytes: Sequence>(_ bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        var found: [String] = []
        for byte in bytes {
            if payload != nil {
                if byte == 0x07 || (sawEscape && byte == UInt8(ascii: "\\")) {
                    found.append(String(decoding: payload!, as: UTF8.self))
                    payload = nil
                    sawEscape = false
                } else if byte == 0x1B {
                    sawEscape = true
                } else {
                    if sawEscape { payload = nil; sawEscape = false; matched = 0; continue }
                    payload!.append(byte)
                    if payload!.count > 4096 { payload = nil }
                }
                continue
            }
            if byte == prefix[matched] {
                matched += 1
                if matched == prefix.count { payload = []; matched = 0 }
            } else {
                matched = byte == prefix[0] ? 1 : 0
            }
        }
        return found
    }
}
