// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "psk-transport-spike",
    platforms: [.macOS(.v15)],
    targets: [
        // Self-test: runs listener + client(s) in one process. Also has --serve mode.
        .executableTarget(name: "psk-spike", path: "Sources/psk-spike"),
        // Client-only half. Single file so it can also be compiled standalone with
        // `xcrun -sdk iphonesimulator swiftc ...` for the iOS simulator.
        .executableTarget(name: "psk-spike-client", path: "Sources/psk-spike-client"),
    ]
)
