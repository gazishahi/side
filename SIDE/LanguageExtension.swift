import AlloySyntax
import Foundation

extension URL {
    /// The extension Side knows a file's language by: its own, lowercased, or one standing for
    /// its whole name (`Dockerfile`, `Makefile`, `.zshrc`), for colors and its language server.
    var languageExtension: String { SyntaxLanguage.languageExtension(forFileName: lastPathComponent) }
}
