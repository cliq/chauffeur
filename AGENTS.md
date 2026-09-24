# Repository Guidelines

## Project Structure & Module Organization

Chauffeur is a native macOS app with a background runtime and an iOS remote client.
- `Sources/ChauffeurApp` and `Sources/ChauffeurMobile`: native app interfaces.
- `Sources/ChauffeurCore`: shared macOS models and bundled skills in `Resources/Skills`.
- `Sources/ChauffeurRuntimeKit`: session management, persistence, IPC, and MCP coordination; executable targets provide the runtime and CLI helpers.
- `Sources/ChauffeurRemote*` and `Sources/ChauffeurTerminal*`: portable client, protocol, and terminal modules. Preserve the portable dependency boundaries documented in `Package.swift`.
- `Tests/`: module suites and native UI tests. `Prototypes/` contains integration probes; `Scripts/` contains build and release utilities.
- `Resources/`: branding and helper resources. `docs/`: architecture, validation, and operational guides.

## Build, Test, and Development Commands

Use macOS 15+, Apple Silicon, Xcode 26.3 / Swift 6.2, XcodeGen, Git, and tmux. Copy `Configuration/LocalSigning.xcconfig.example` to `Configuration/LocalSigning.xcconfig` and configure your development team.

- `make build`: generate the Xcode project, build Debug, and verify signing.
- `open 'build/Build/Products/Debug/Chauffeur Debug.app'`: launch locally.
- `make release`: build the optimized app.
- `make test`: run Swift package tests.
- `swift test --no-parallel --filter SkillInstallerTests`: run a focused suite.
- `make test-ui`: build and run native UI tests; requires automation access.
- `make install`: replace the installed Release app, relaunch, and verify its runtime.

Edit `project.yml` for Xcode configuration; regenerate with `make gen`. See `docs/building.md` for integration probes.

## Coding Style & Naming Conventions

Follow nearby Swift code: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` members. Name files after their primary type or responsibility. Preserve actor isolation and module boundaries. No repository-wide formatter or linter configuration is provided.

## Testing Guidelines

Package suites use Swift Testing (`@Test`, `#expect`); native UI tests use XCTest. Use descriptive behavior names in `*Tests.swift`. Run relevant suites for changed behavior; no numeric coverage threshold is configured. Keep runtime fixtures, fake CLIs, and private profiles in temporary directories rather than real user data.

## Commit & Pull Request Guidelines

Use concise imperative commit subjects, matching history: “Rename sessions after launch.” Keep commits focused. PRs should explain the problem, resulting behavior, verification, and limitations; link relevant issues and include screenshots for UI changes. Keep signing overrides, credentials, and private terminal histories out of commits.
