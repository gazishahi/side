import Foundation

/// Each language's line comment, for Toggle Comment. Languages with only block comments (CSS,
/// HTML, Markdown, JSON) have none.
enum LineComments {
    static func token(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "swift", "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm",
             "java", "kt", "kts", "cs", "go", "rs", "php", "scss", "less", "jsonc", "zig", "dart", "scala", "groovy", "proto":
            return "//"
        case "py", "pyi", "rb", "sh", "bash", "zsh", "command", "yaml", "yml", "toml", "dockerfile", "mk", "make", "r", "pl", "ex", "exs",
             "nim", "cmake", "conf", "ini", "gitignore", "env":
            return "#"
        case "lua", "sql", "hs", "elm":
            return "--"
        case "vim":
            return "\""
        case "lisp", "clj", "el", "scm":
            return ";"
        default:
            return nil
        }
    }
}
