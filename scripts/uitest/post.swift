import Foundation
// A moment between commands: several posted at once sometimes reached Side as fewer (a
// "stage make" "open …" pair lost the open, 2026-11-06).
for (index, command) in CommandLine.arguments.dropFirst().enumerated() {
    if index > 0 { usleep(60_000) }
    DistributedNotificationCenter.default().postNotificationName(.init("side.uitesting.command"), object: command, userInfo: nil, deliverImmediately: true)
}
