// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Chauffeur",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ChauffeurCore", targets: ["ChauffeurCore"]),
        .library(name: "ChauffeurRuntimeKit", targets: ["ChauffeurRuntimeKit"]),
        .executable(name: "ChauffeurRuntime", targets: ["ChauffeurRuntime"]),
        .executable(name: "ChauffeurNotifications", targets: ["ChauffeurNotifications"]),
        .executable(name: "chauffeurctl", targets: ["ChauffeurCtl"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0")
    ],
    targets: [
        .target(name: "ChauffeurCore", dependencies: ["CChauffeur"], resources: [.copy("Resources/Skills")]),
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CChauffeur", publicHeadersPath: "include"),
        .target(name: "ChauffeurRuntimeKit", dependencies: ["ChauffeurCore", "CSQLite", "CChauffeur", .product(name: "Hummingbird", package: "hummingbird")]),
        .executableTarget(name: "ChauffeurRuntime", dependencies: ["ChauffeurRuntimeKit"]),
        .executableTarget(name: "ChauffeurNotifications", dependencies: ["ChauffeurCore"]),
        .executableTarget(name: "ChauffeurCtl", dependencies: ["ChauffeurCore", "CChauffeur"]),
        .testTarget(name: "ChauffeurCoreTests", dependencies: ["ChauffeurCore"]),
        .testTarget(name: "ChauffeurRuntimeTests", dependencies: ["ChauffeurRuntimeKit"])
    ]
)
