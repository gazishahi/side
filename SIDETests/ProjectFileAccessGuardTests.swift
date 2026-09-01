import XCTest
@testable import Side

/// The write and read guards on Side's own directories inside a project.
///
/// The default macOS filesystem is case-insensitive, so `.GIT/hooks/x` *is* `.git/hooks/x`. An
/// exact-string guard let the first spelling through, and a write there is code execution on the
/// next unattended `git status` — found and verified by the 2026-09-01 audit.
final class ProjectFileAccessGuardTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/side-guard-\(UUID().uuidString)")

    private func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func testGitAndSideAreNotWritableInAnyCasing() {
        for path in [".git/config", ".GIT/config", ".Git/hooks/post-checkout", ".gIt/HEAD",
                     ".side/tracks.json", ".SIDE/tracks.json", ".Side/think/index.json"] {
            XCTAssertFalse(ProjectFileAccess.isWritable(url(path), root: root), "writable: \(path)")
        }
    }

    func testOrdinaryFilesAreWritable() {
        for path in ["src/main.swift", "README.md", ".gitignore", ".github/workflows/ci.yml", "gitlab/x"] {
            XCTAssertTrue(ProjectFileAccess.isWritable(url(path), root: root), "not writable: \(path)")
        }
    }

    func testTheRootItselfIsNotWritable() {
        XCTAssertFalse(ProjectFileAccess.isWritable(root, root: root))
    }

    func testConversationStateIsNotReadableInAnyCasing() {
        // `.git/side/` holds every track's conversation. Readable, it is a cross-track leak.
        for path in [".git/side/think/index.json", ".GIT/side/think/index.json", ".git/Side/x",
                     ".side/tracks.json", ".SIDE/tracks.json"] {
            XCTAssertFalse(ProjectFileAccess.isReadable(url(path), root: root), "readable: \(path)")
        }
    }

    func testTheRestOfGitIsStillReadable() {
        // Only Side's own state is hidden — HEAD and refs are ordinary read targets.
        XCTAssertTrue(ProjectFileAccess.isReadable(url(".git/HEAD"), root: root))
        XCTAssertTrue(ProjectFileAccess.isReadable(url("src/a.swift"), root: root))
    }
}
