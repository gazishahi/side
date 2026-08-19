import Foundation

/// Turns an approved `ProposedEdit` into an actual change. The only place in Heron that can
/// modify the project, and it is only ever reached from an explicit human Apply — that's the
/// invariant the whole propose/approve design rests on.
struct ProposedEditApplier {
    /// Applies into Make's open tab when the file is open (returns true), so undo/save/dirty
    /// tracking all behave as if the user typed it. Nil-safe: when Make isn't hosting the file,
    /// the applier writes to disk instead.
    let applyIntoOpenTab: (URL, String) -> Bool
    /// Current on-disk-or-buffer content for staleness checking, same source the proposal was
    /// computed against.
    let currentContent: (URL) -> String?

    func apply(_ edit: ProposedEdit) -> ProposedEditOutcome {
        // Between proposal and approval the user may have typed, saved, switched branches, or
        // had a formatter run. Applying a full-file replacement computed against different
        // content would silently destroy whatever happened in between, so refuse instead.
        let existing = currentContent(edit.url)
        if edit.isNewFile {
            if existing != nil { return .staleBase }
        } else {
            guard let existing else { return .staleBase }
            guard existing == edit.baseContent else { return .staleBase }
        }

        if applyIntoOpenTab(edit.url, edit.proposedContent) { return .applied }

        do {
            try FileManager.default.createDirectory(at: edit.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try edit.proposedContent.write(to: edit.url, atomically: true, encoding: .utf8)
            return .applied
        } catch {
            return .writeFailed(error.localizedDescription)
        }
    }
}
