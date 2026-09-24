import Foundation

/// A conversation an agent CLI recorded for a checkout, read from the
/// provider's own transcripts. It outlives the Chauffeur session that ran it.
public struct RecentConversation: Codable, Equatable, Sendable, Identifiable {
    /// The provider's native conversation ID.
    public var id: String
    public var kind: CLIKind
    /// The provider's title for the conversation, else its first prompt.
    public var title: String
    /// The first prompt the user typed, when the provider recorded one.
    public var prompt: String?
    public var startedAt: Date?
    public var updatedAt: Date
    /// The configuration directory that holds the transcript. OpenCode keeps
    /// one shared database, so its conversations have none.
    public var configurationDirectory: String?
    /// The transcript file, when the provider keeps one per conversation.
    public var transcriptPath: String?
    public init(id: String, kind: CLIKind, title: String, prompt: String? = nil, startedAt: Date? = nil, updatedAt: Date, configurationDirectory: String? = nil, transcriptPath: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.prompt = prompt
        self.startedAt = startedAt; self.updatedAt = updatedAt
        self.configurationDirectory = configurationDirectory; self.transcriptPath = transcriptPath
    }
}
