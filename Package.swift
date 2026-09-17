// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Chauffeur",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "ChauffeurCore", targets: ["ChauffeurCore"]),
        .library(name: "ChauffeurRuntimeKit", targets: ["ChauffeurRuntimeKit"]),
        // Portable (iOS + macOS) modules. They must not depend on ChauffeurCore, CChauffeur, or CSQLite.
        .library(name: "ChauffeurRemoteProtocol", targets: ["ChauffeurRemoteProtocol"]),
        .library(name: "ChauffeurRemoteClient", targets: ["ChauffeurRemoteClient"]),
        .library(name: "ChauffeurTerminalInterface", targets: ["ChauffeurTerminalInterface"]),
        .library(name: "ChauffeurTerminalSwiftTerm", targets: ["ChauffeurTerminalSwiftTerm"]),
        .library(name: "ChauffeurTerminalTesting", targets: ["ChauffeurTerminalTesting"]),
        .executable(name: "ChauffeurRuntime", targets: ["ChauffeurRuntime"]),
        .executable(name: "ChauffeurNotifications", targets: ["ChauffeurNotifications"]),
        .executable(name: "chauffeurctl", targets: ["ChauffeurCtl"]),
        .executable(name: "chauffeur", targets: ["ChauffeurLauncher"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0")
    ],
    targets: [
        .target(name: "ChauffeurCore", dependencies: ["CChauffeur"], resources: [.copy("Resources/Skills")]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CChauffeur", publicHeadersPath: "include"),
        .target(name: "ChauffeurRuntimeKit", dependencies: ["ChauffeurCore", "ChauffeurRemoteProtocol", "CSQLite", "CChauffeur", .product(name: "Hummingbird", package: "hummingbird")]),
        // Portable modules
        .target(name: "ChauffeurRemoteProtocol"),
        .target(name: "ChauffeurTerminalInterface"),
        .target(name: "ChauffeurTerminalTesting", dependencies: ["ChauffeurTerminalInterface"]),
        .target(name: "ChauffeurTerminalSwiftTerm", dependencies: ["ChauffeurTerminalInterface", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "ChauffeurRemoteClient", dependencies: ["ChauffeurRemoteProtocol", "ChauffeurTerminalInterface"]),
        .executableTarget(name: "ChauffeurRuntime", dependencies: ["ChauffeurRuntimeKit"]),
        .executableTarget(name: "ChauffeurNotifications", dependencies: ["ChauffeurCore"]),
        .executableTarget(name: "ChauffeurCtl", dependencies: ["ChauffeurCore", "CChauffeur"]),
        .executableTarget(name: "ChauffeurLauncher", dependencies: ["ChauffeurCore"]),
        .testTarget(name: "ChauffeurCoreTests", dependencies: ["ChauffeurCore"]),
        .testTarget(name: "ChauffeurRuntimeTests", dependencies: ["ChauffeurRuntimeKit", "ChauffeurRemoteProtocol"]),
        .testTarget(name: "ChauffeurRemoteProtocolTests", dependencies: ["ChauffeurRemoteProtocol"]),
        .testTarget(name: "ChauffeurTerminalInterfaceTests", dependencies: ["ChauffeurTerminalInterface", "ChauffeurTerminalTesting"]),
        .testTarget(name: "ChauffeurRemoteClientTests", dependencies: ["ChauffeurRemoteClient", "ChauffeurRemoteProtocol", "ChauffeurTerminalInterface", "ChauffeurTerminalTesting"])
    ]
)
