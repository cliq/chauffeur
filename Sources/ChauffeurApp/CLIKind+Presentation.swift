import ChauffeurCore

extension CLIKind {
    /// The team setting's title; OpenCode's folder adds a layer rather than replacing its global one.
    var configurationFolderLabel: String {
        switch self {
        case .claude: "Claude config folder"
        case .opencode: "OpenCode config layer"
        default: "\(displayName) config folder"
        }
    }

    var configurationFolderNote: String? {
        self == .opencode ? "Loaded on top of the global OpenCode configuration (~/.config/opencode)." : nil
    }
}
