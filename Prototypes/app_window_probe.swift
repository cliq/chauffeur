import AppKit
import CoreGraphics
import Foundation

// Inspect our exact app path without UI automation or sending it any input.
let expected = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
var report: [String: Any] = [:]
var ready = false
for _ in 0..<100 {
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.resolvingSymlinksInPath() == expected }) {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = all.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) && ($0[kCGWindowLayer as String] as? Int) == 0 }
        report = ["pid": Int(app.processIdentifier), "finishedLaunching": app.isFinishedLaunching,
                  "regularApplication": app.activationPolicy == .regular,
                  "visibleWindows": windows.map { ["id": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:]] }]
        ready = !windows.isEmpty && app.isFinishedLaunching && app.activationPolicy == .regular
        if ready { break }
    }
    // NSWorkspace's launch state is refreshed on the run loop. Sleeping here
    // can leave isFinishedLaunching cached as false for the entire deadline.
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
}
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
exit(ready ? 0 : 1)
