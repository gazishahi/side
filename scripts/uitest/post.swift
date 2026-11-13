import Foundation
// A moment between commands: several posted at once sometimes reached Side as fewer (a
// "stage make" "open …" pair lost the open, 2026-11-06).
for (index, command) in CommandLine.arguments.dropFirst().enumerated() {
    if index > 0 { usleep(60_000) }
    // The build's own channel (uitest.sh sets SIDE_UIT_CHANNEL from its folder).
    let channel = ProcessInfo.processInfo.environment["SIDE_UIT_CHANNEL"].map { $0.isEmpty ? "" : "." + $0 } ?? ""
    DistributedNotificationCenter.default().postNotificationName(.init("side.uitesting.command" + channel), object: command, userInfo: nil, deliverImmediately: true)
}
