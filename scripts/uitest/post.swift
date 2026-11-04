import Foundation
for command in CommandLine.arguments.dropFirst() {
    DistributedNotificationCenter.default().postNotificationName(.init("side.uitesting.command"), object: command, userInfo: nil, deliverImmediately: true)
}
