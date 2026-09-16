import AppKit
import Foundation

// Observe a user-initiated system sleep/wake cycle. This neither requests sleep
// nor changes power settings or assertions. The private log contains no input.
guard CommandLine.arguments.count == 2 else { exit(2) }
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try Data().write(to: destination, options: .withoutOverwriting)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
let output = try FileHandle(forWritingTo: destination)
func record(_ event: String) {
    let entry = ["event": event, "timestamp": ISO8601DateFormatter().string(from: Date())]
    do {
        try output.write(contentsOf: JSONSerialization.data(withJSONObject: entry, options: .sortedKeys) + Data([10]))
        try output.synchronize()
    } catch {
        FileHandle.standardError.write(Data("Unable to record system power event\n".utf8))
        exit(1)
    }
}
let center = NSWorkspace.shared.notificationCenter
let observers = [
    center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in record("willSleep") },
    center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in record("didWake") }
]
record("observerReady")
withExtendedLifetime(observers) { RunLoop.main.run() }
