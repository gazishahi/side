import Foundation

/// How a language server is installed, if Side can offer to.
enum LanguageInstall: Sendable, Equatable {
    case brew(String)
    case npm(String)
    case gem(String)
    case dotnet(String)
    /// A Go module, `go install`ed (the binary lands in `$(go env GOPATH)/bin`).
    case go(String)

    /// What runs in a login shell (so the person's PATH, nvm and rbenv apply).
    var command: String {
        switch self {
        case .brew(let name): return "brew install \(name)"
        case .npm(let name): return "npm install -g \(name)"
        case .gem(let name): return "gem install \(name)"
        case .dotnet(let name): return "dotnet tool install -g \(name)"
        case .go(let module): return "go install \(module)@latest"
        }
    }

    /// The tool doing it, for the words around the button.
    var tool: String {
        switch self {
        case .brew: return "Homebrew"
        case .npm: return "npm"
        case .gem: return "RubyGems"
        case .dotnet: return ".NET"
        case .go: return "Go"
        }
    }

    /// The installer's own command, which must be there first, and where to get it.
    var requirement: (binary: String, hint: String) {
        switch self {
        case .brew: return ("brew", "Homebrew, from brew.sh")
        case .npm: return ("npm", "Node.js (brew install node)")
        case .gem: return ("gem", "Ruby (it comes with macOS; or brew install ruby)")
        case .dotnet: return ("dotnet", "the .NET SDK (brew install --cask dotnet-sdk)")
        case .go: return ("go", "Go (brew install go)")
        }
    }

    /// Homebrew's name, for finding a keg-only formula's binary (`brew --prefix`).
    var brewFormula: String? { if case .brew(let name) = self { return name } else { return nil } }
}

/// A language server Side knows how to run.
struct ServerPreset: Sendable, Equatable {
    let id: String
    let name: String
    let binary: String
    let arguments: [String]
    let install: LanguageInstall?
}

/// A language Side knows: its file extensions (each with the id servers expect), and the
/// servers it can use, the first the default.
struct LanguagePreset: Sendable, Equatable {
    let id: String
    let name: String
    /// Extension → LSP language id.
    let extensions: [(ext: String, languageId: String)]
    let servers: [ServerPreset]
    /// Whether a missing server shows "not installed" on the file's chip. Only for the
    /// languages that did before this list grew; the rest wait to be installed in Settings, so
    /// opening a YAML file doesn't nag.
    let asksToInstall: Bool

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// What the person changed about a language (nil: the preset's default).
struct LanguageChoice: Codable, Equatable, Sendable {
    var enabled: Bool?
    var serverID: String?
    /// A command of one's own instead of a preset: the binary, then its arguments.
    var customCommand: [String]?
    /// Settings the server reads (`workspace/configuration`), as JSON.
    var settingsJSON: String?
    /// nil: the project's formatter if it has one (Side's behavior before this setting).
    var formatOnSave: Bool?
}

/// A language Side doesn't know, added by the person.
struct CustomLanguage: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var extensions: [String]
    var languageId: String
    var command: [String]
}

/// Side's languages and the person's choices about them (Settings → Languages,
/// SIDE_RFC_IDE_ESSENTIALS.md, L4). Thread-safe: servers are resolved off the main thread.
final class LanguageSettings: @unchecked Sendable {
    static let shared = LanguageSettings()
    static let didChangeNotification = Notification.Name("SideLanguageSettingsDidChange")
    private static let choicesKey = "SideLanguageChoices"
    private static let customKey = "SideCustomLanguages"

    /// Under tests and UI testing, a suite of their own, as Make's preferences.
    nonisolated(unsafe) static var defaults: UserDefaults = NSClassFromString("XCTestCase") == nil
        ? .standard : UserDefaults(suiteName: "side.tests.languages.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard

    private let lock = NSLock()
    private var choices: [String: LanguageChoice] = [:]
    private var custom: [CustomLanguage] = []
    private var loaded = false

    private func load() {
        guard !loaded else { return }
        loaded = true
        let defaults = Self.defaults
        if let data = defaults.data(forKey: Self.choicesKey), let decoded = try? JSONDecoder().decode([String: LanguageChoice].self, from: data) { choices = decoded }
        if let data = defaults.data(forKey: Self.customKey), let decoded = try? JSONDecoder().decode([CustomLanguage].self, from: data) { custom = decoded }
    }

    private func save() {
        let defaults = Self.defaults
        defaults.set(try? JSONEncoder().encode(choices), forKey: Self.choicesKey)
        defaults.set(try? JSONEncoder().encode(custom), forKey: Self.customKey)
    }

    /// Forgets what was read, after a test swaps `defaults`.
    func reload() { lock.withLock { loaded = false; choices = [:]; custom = [] } }

    func choice(_ languageID: String) -> LanguageChoice {
        lock.withLock { load(); return choices[languageID] ?? LanguageChoice() }
    }

    func setChoice(_ choice: LanguageChoice, for languageID: String) {
        lock.withLock { load(); choices[languageID] = choice == LanguageChoice() ? nil : choice; save() }
        announce()
    }

    var customLanguages: [CustomLanguage] { lock.withLock { load(); return custom } }

    func setCustomLanguages(_ languages: [CustomLanguage]) {
        lock.withLock { load(); custom = languages; save() }
        announce()
    }

    private func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
    }

    /// The server for a file extension, as the person has it: nil when the language is off, or
    /// isn't one Side knows.
    func entry(forExtension ext: String) -> LanguageServerRegistry.Entry? {
        let ext = ext.lowercased()
        guard !ext.isEmpty else { return nil }
        if let language = customLanguages.first(where: { $0.extensions.contains(ext) }), let binary = language.command.first {
            return LanguageServerRegistry.Entry(languageId: language.languageId, binaryName: binary, arguments: Array(language.command.dropFirst()),
                                                install: nil, languageKey: language.id, asksToInstall: true)
        }
        guard let preset = Self.presets.first(where: { $0.extensions.contains { $0.ext == ext } }),
              let languageId = preset.extensions.first(where: { $0.ext == ext })?.languageId else { return nil }
        let choice = self.choice(preset.id)
        guard choice.enabled ?? true else { return nil }
        if let command = choice.customCommand, let binary = command.first {
            return LanguageServerRegistry.Entry(languageId: languageId, binaryName: binary, arguments: Array(command.dropFirst()),
                                                install: nil, languageKey: preset.id, asksToInstall: true)
        }
        let server = preset.servers.first { $0.id == choice.serverID } ?? preset.servers[0]
        return LanguageServerRegistry.Entry(languageId: languageId, binaryName: server.binary, arguments: server.arguments,
                                            install: server.install, languageKey: preset.id,
                                            asksToInstall: preset.asksToInstall || choice.serverID != nil || choice.enabled == true)
    }

    /// What a server asked about in `workspace/configuration`: for each section, that part of
    /// the language's settings (all of them for an empty section), or null.
    func configuration(languageKey: String, sections: [String?]) -> [LSPValue] {
        let json = choice(languageKey).settingsJSON ?? ""
        guard let data = json.data(using: .utf8), !json.isEmpty, let object = try? JSONSerialization.jsonObject(with: data) else {
            return sections.map { _ in .null }
        }
        return sections.map { section in
            guard let section, !section.isEmpty else { return LSPValue(any: object) }
            var current: Any? = object
            // Both shapes: {"a": {"b": 1}} and {"a.b": 1}.
            if let flat = (object as? [String: Any])?[section] { return LSPValue(any: flat) }
            for part in section.split(separator: ".") { current = (current as? [String: Any])?[String(part)] }
            return LSPValue(any: current)
        }
    }

    /// Whether to format on save: nil means as before (the project's formatter, if any).
    func formatOnSave(forExtension ext: String) -> Bool? {
        guard let preset = Self.presets.first(where: { $0.extensions.contains { $0.ext == ext.lowercased() } }) else { return nil }
        return choice(preset.id).formatOnSave
    }

    static func preset(forExtension ext: String) -> LanguagePreset? {
        presets.first { $0.extensions.contains { $0.ext == ext.lowercased() } }
    }

    // MARK: The languages

    private static func s(_ id: String, _ name: String, _ binary: String, _ args: [String] = [], _ install: LanguageInstall?) -> ServerPreset {
        ServerPreset(id: id, name: name, binary: binary, arguments: args, install: install)
    }

    static let presets: [LanguagePreset] = [
        LanguagePreset(id: "typescript", name: "TypeScript and JavaScript",
                       extensions: [("ts", "typescript"), ("mts", "typescript"), ("cts", "typescript"), ("tsx", "typescriptreact"),
                                    ("js", "javascript"), ("mjs", "javascript"), ("cjs", "javascript"), ("jsx", "javascriptreact")],
                       servers: [s("typescript-language-server", "TypeScript Language Server", "typescript-language-server", ["--stdio"], .brew("typescript-language-server")),
                                 s("vtsls", "vtsls", "vtsls", ["--stdio"], .npm("@vtsls/language-server"))],
                       asksToInstall: true),
        LanguagePreset(id: "python", name: "Python", extensions: [("py", "python"), ("pyi", "python")],
                       servers: [s("pyright", "Pyright", "pyright-langserver", ["--stdio"], .brew("pyright")),
                                 s("basedpyright", "basedpyright", "basedpyright-langserver", ["--stdio"], .brew("basedpyright"))],
                       asksToInstall: true),
        LanguagePreset(id: "swift", name: "Swift", extensions: [("swift", "swift")],
                       servers: [s("sourcekit-lsp", "SourceKit-LSP (with Xcode)", "sourcekit-lsp", [], nil)], asksToInstall: true),
        LanguagePreset(id: "rust", name: "Rust", extensions: [("rs", "rust")],
                       servers: [s("rust-analyzer", "rust-analyzer", "rust-analyzer", [], .brew("rust-analyzer"))], asksToInstall: true),
        LanguagePreset(id: "go", name: "Go", extensions: [("go", "go")],
                       servers: [s("gopls", "gopls", "gopls", [], .brew("gopls"))], asksToInstall: true),
        LanguagePreset(id: "lua", name: "Lua", extensions: [("lua", "lua")],
                       servers: [s("lua-language-server", "Lua Language Server", "lua-language-server", [], .brew("lua-language-server"))], asksToInstall: true),
        LanguagePreset(id: "c", name: "C and C++",
                       extensions: [("c", "c"), ("h", "c"), ("cpp", "cpp"), ("cc", "cpp"), ("cxx", "cpp"), ("hpp", "cpp"), ("hh", "cpp"), ("m", "objective-c"), ("mm", "objective-cpp")],
                       servers: [s("clangd", "clangd", "clangd", [], .brew("llvm"))], asksToInstall: true),
        LanguagePreset(id: "sql", name: "SQL", extensions: [("sql", "sql")],
                       // sql-language-server (npm) exits on current Node versions; sqls is maintained.
                       servers: [s("sqls", "sqls", "sqls", [], .go("github.com/sqls-server/sqls"))], asksToInstall: false),
        LanguagePreset(id: "yaml", name: "YAML", extensions: [("yaml", "yaml"), ("yml", "yaml")],
                       servers: [s("yaml-language-server", "YAML Language Server", "yaml-language-server", ["--stdio"], .brew("yaml-language-server"))], asksToInstall: false),
        LanguagePreset(id: "toml", name: "TOML", extensions: [("toml", "toml")],
                       servers: [s("taplo", "Taplo", "taplo", ["lsp", "stdio"], .brew("taplo"))], asksToInstall: false),
        LanguagePreset(id: "html", name: "HTML", extensions: [("html", "html"), ("htm", "html")],
                       servers: [s("vscode-html", "VS Code's HTML server", "vscode-html-language-server", ["--stdio"], .npm("vscode-langservers-extracted"))], asksToInstall: false),
        LanguagePreset(id: "css", name: "CSS, SCSS and Less", extensions: [("css", "css"), ("scss", "scss"), ("less", "less")],
                       servers: [s("vscode-css", "VS Code's CSS server", "vscode-css-language-server", ["--stdio"], .npm("vscode-langservers-extracted"))], asksToInstall: false),
        LanguagePreset(id: "json", name: "JSON", extensions: [("json", "json"), ("jsonc", "jsonc")],
                       servers: [s("vscode-json", "VS Code's JSON server", "vscode-json-language-server", ["--stdio"], .npm("vscode-langservers-extracted"))], asksToInstall: false),
        LanguagePreset(id: "shell", name: "Shell", extensions: [("sh", "shellscript"), ("bash", "shellscript"), ("zsh", "shellscript")],
                       servers: [s("bash-language-server", "Bash Language Server", "bash-language-server", ["start"], .brew("bash-language-server"))], asksToInstall: false),
        LanguagePreset(id: "ruby", name: "Ruby", extensions: [("rb", "ruby")],
                       servers: [s("ruby-lsp", "Ruby LSP", "ruby-lsp", [], .gem("ruby-lsp")),
                                 s("solargraph", "Solargraph", "solargraph", ["stdio"], .gem("solargraph"))], asksToInstall: false),
        LanguagePreset(id: "java", name: "Java", extensions: [("java", "java")],
                       servers: [s("jdtls", "Eclipse JDT Language Server", "jdtls", [], .brew("jdtls"))], asksToInstall: false),
        LanguagePreset(id: "kotlin", name: "Kotlin", extensions: [("kt", "kotlin"), ("kts", "kotlin")],
                       servers: [s("kotlin-language-server", "Kotlin Language Server", "kotlin-language-server", [], .brew("kotlin-language-server"))], asksToInstall: false),
        LanguagePreset(id: "csharp", name: "C#", extensions: [("cs", "csharp")],
                       servers: [s("csharp-ls", "csharp-ls", "csharp-ls", [], .dotnet("csharp-ls"))], asksToInstall: false),
        LanguagePreset(id: "php", name: "PHP", extensions: [("php", "php")],
                       servers: [s("intelephense", "Intelephense", "intelephense", ["--stdio"], .npm("intelephense"))], asksToInstall: false),
        LanguagePreset(id: "dockerfile", name: "Dockerfile", extensions: [("dockerfile", "dockerfile")],
                       servers: [s("docker-langserver", "Dockerfile Language Server", "docker-langserver", ["--stdio"], .npm("dockerfile-language-server-nodejs"))], asksToInstall: false),
        LanguagePreset(id: "markdown", name: "Markdown", extensions: [("md", "markdown"), ("markdown", "markdown")],
                       servers: [s("marksman", "Marksman", "marksman", ["server"], .brew("marksman"))], asksToInstall: false),
    ]
}
