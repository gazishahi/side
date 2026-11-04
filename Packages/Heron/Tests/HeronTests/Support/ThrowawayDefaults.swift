import XCTest
import SideAgents

extension XCTestCase {
    /// A settings store of this test's own, in memory (`InMemoryDefaults`): stores made with a
    /// suite name per test had piled up in ~/Library/Preferences (2,443 files by 2026-10-01).
    func throwawayDefaults() -> UserDefaults { InMemoryDefaults() }
}
