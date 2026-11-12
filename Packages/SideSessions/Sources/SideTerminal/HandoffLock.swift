import Foundation
import Synchronization

/// The terminal's lock, fair to the renderer. A plain lock let a reader parsing a flood of output
/// take it back the instant it let go, so a frame waited until the flood ended and the screen
/// froze meanwhile. Here a waiting frame makes the reader step aside before its next slice, until
/// that frame is done (or 4 ms pass). Ghostty's IO thread hands its lock off the same way.
final class HandoffLock: @unchecked Sendable {
    // @unchecked: an NSLock and atomics.
    private let lock = NSLock()
    private let frameWaiting = Atomic<Bool>(false)
    private let readerWaiting = Atomic<Bool>(false)
    /// Signalled when a frame has had its turn; the reader blocks on it rather than spinning.
    private let frameDone = DispatchSemaphore(value: 0)

    /// The reader's side: one slice of parsing.
    func write<T>(_ body: () -> T) -> T {
        if frameWaiting.load(ordering: .acquiring) {
            readerWaiting.store(true, ordering: .releasing)
            // Checked again after announcing: the frame may have finished in between.
            if frameWaiting.load(ordering: .acquiring) { _ = frameDone.wait(timeout: .now() + .milliseconds(4)) }
            readerWaiting.store(false, ordering: .releasing)
        }
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Everyone else: a frame's update, a resize, a question about the terminal.
    func read<T>(_ body: () -> T) -> T {
        frameWaiting.store(true, ordering: .releasing)
        lock.lock()
        frameWaiting.store(false, ordering: .releasing)
        let result = body()
        lock.unlock()
        // Only a reader that is waiting is woken: signals don't pile up.
        if readerWaiting.load(ordering: .acquiring) { frameDone.signal() }
        return result
    }
}
