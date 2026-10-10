// swift-tools-version: 6.2
import PackageDescription

/// CryptoKit's API on Linux. Apple platforms use CryptoKit itself.
let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))

#if os(Linux)
/// The remote-access listener: TLS 1.2 PSK over the system OpenSSL, as Network.framework is unavailable.
let remoteTLS: [Target.Dependency] = ["CChauffeurTLS"]
#else
let remoteTLS: [Target.Dependency] = []
#endif

// The headless runtime and its command-line helpers build on macOS and Linux.
var products: [Product] = [
    .library(name: "ChauffeurCore", targets: ["ChauffeurCore"]),
    .library(name: "ChauffeurRuntimeKit", targets: ["ChauffeurRuntimeKit"]),
    // Portable (iOS + macOS) modules. They must not depend on ChauffeurCore, CChauffeur, or CSQLite.
    .library(name: "ChauffeurRemoteProtocol", targets: ["ChauffeurRemoteProtocol"]),
    .executable(name: "ChauffeurRuntime", targets: ["ChauffeurRuntime"]),
    .executable(name: "chauffeurctl", targets: ["ChauffeurCtl"])
]
var targets: [Target] = [
    .target(name: "ChauffeurCore", dependencies: ["CChauffeur", "ChauffeurRemoteProtocol", crypto], resources: [.copy("Resources/Skills"), .copy("Resources/Plugins")]),
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "CChauffeur", publicHeadersPath: "include"),
    .target(name: "ChauffeurRuntimeKit", dependencies: ["ChauffeurCore", "ChauffeurRemoteProtocol", "CSQLite", "CChauffeur", crypto, .product(name: "Hummingbird", package: "hummingbird"), .product(name: "TOMLKit", package: "TOMLKit")] + remoteTLS),
    .target(name: "ChauffeurRemoteProtocol", dependencies: [crypto]),
    .executableTarget(name: "ChauffeurRuntime", dependencies: ["ChauffeurRuntimeKit"]),
    .executableTarget(name: "ChauffeurCtl", dependencies: ["ChauffeurCore", "CChauffeur"]),
    .testTarget(name: "ChauffeurCoreTests", dependencies: ["ChauffeurCore"]),
    .testTarget(name: "ChauffeurRemoteProtocolTests", dependencies: ["ChauffeurRemoteProtocol"])
]

#if os(Linux)
targets += [
    .target(name: "CChauffeurTLS", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto")]),
    // The excluded suites drive the runtime through the Apple-only remote client.
    .testTarget(name: "ChauffeurRuntimeTests", dependencies: ["ChauffeurRuntimeKit", "ChauffeurRemoteProtocol"], exclude: ["RemoteAccessServiceTests.swift", "RemoteEndToEndTests.swift"])
]
#else
// The desktop app's helpers, the iOS client and the terminal engines are Apple-only.
products += [
    .library(name: "ChauffeurRemoteClient", targets: ["ChauffeurRemoteClient"]),
    .library(name: "ChauffeurTerminalInterface", targets: ["ChauffeurTerminalInterface"]),
    .library(name: "ChauffeurTerminalSwiftTerm", targets: ["ChauffeurTerminalSwiftTerm"]),
    // macOS only: the desktop's Ghostty engine. The iOS client keeps SwiftTerm.
    .library(name: "ChauffeurTerminalGhostty", targets: ["ChauffeurTerminalGhostty"]),
    .library(name: "ChauffeurTerminalTesting", targets: ["ChauffeurTerminalTesting"]),
    .executable(name: "ChauffeurSessions", targets: ["ChauffeurSessions"]),
    .executable(name: "ChauffeurNotifications", targets: ["ChauffeurNotifications"]),
    .executable(name: "chauffeur", targets: ["ChauffeurLauncher"])
]
targets += [
    .target(name: "ChauffeurTerminalInterface"),
    .target(name: "ChauffeurTerminalTesting", dependencies: ["ChauffeurTerminalInterface"]),
    .target(name: "ChauffeurTerminalSwiftTerm", dependencies: ["ChauffeurTerminalInterface", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    .target(name: "ChauffeurTerminalGhostty", dependencies: ["ChauffeurTerminalInterface", .product(name: "GhosttyKit", package: "libghostty-spm")]),
    .target(name: "ChauffeurRemoteClient", dependencies: ["ChauffeurRemoteProtocol", "ChauffeurTerminalInterface"]),
    .executableTarget(name: "ChauffeurSessions", dependencies: ["ChauffeurCore"]),
    .executableTarget(name: "ChauffeurNotifications", dependencies: ["ChauffeurCore"]),
    .executableTarget(name: "ChauffeurLauncher", dependencies: ["ChauffeurCore"]),
    .testTarget(name: "ChauffeurRuntimeTests", dependencies: ["ChauffeurRuntimeKit", "ChauffeurRemoteProtocol", "ChauffeurRemoteClient", "ChauffeurTerminalTesting"]),
    .testTarget(name: "ChauffeurTerminalGhosttyTests", dependencies: ["ChauffeurTerminalGhostty", "ChauffeurTerminalInterface"]),
    .testTarget(name: "ChauffeurTerminalInterfaceTests", dependencies: ["ChauffeurTerminalInterface", "ChauffeurTerminalTesting"]),
    .testTarget(name: "ChauffeurRemoteClientTests", dependencies: ["ChauffeurRemoteClient", "ChauffeurRemoteProtocol", "ChauffeurTerminalInterface", "ChauffeurTerminalTesting"])
]
#endif

let package = Package(
    name: "Chauffeur",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: products,
    // Declared on every platform so Package.resolved is the same everywhere; Linux
    // builds no target that uses SwiftTerm or Ghostty.
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260922"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")
    ],
    targets: targets
)
