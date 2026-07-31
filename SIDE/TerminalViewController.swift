import AppKit
import SwiftTerm

final class TerminalViewController: NSViewController {
    private let terminalView = LocalProcessTerminalView(frame: .zero)
    private var didStart = false
    var workingDirectory: String?

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let nerdFont = NSFont(name: "MesloLGS-NF-Regular", size: 13) {
            terminalView.font = nerdFont
        }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func activate() {
        if didStart {
            view.window?.makeFirstResponder(terminalView)
            return
        }
        didStart = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminalView.startProcess(executable: shell, args: ["-l"], currentDirectory: workingDirectory)
        view.window?.makeFirstResponder(terminalView)
    }
}
