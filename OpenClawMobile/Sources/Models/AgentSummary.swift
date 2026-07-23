import Foundation

/// One agent in the gateway roster (`agents.list`, LIVE-verified schema 2026-07-22).
/// Agent = a Slack-style "team": its own workspace, model, and identity. The chat
/// session key is the agent's bare id — the gateway canonicalizes it to
/// `agent:<id>:main` per-sender (verified: sending to "main" → agent:main:main).
struct AgentSummary: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    var name: String?
    var emoji: String?
    var avatarUrl: String?
    var theme: String?
    var model: String?
    var workspace: String?

    var displayName: String { name ?? id }

    enum CodingKeys: String, CodingKey {
        case id, name, identity, model, workspace
    }
    private struct Identity: Decodable { var emoji: String?; var avatarUrl: String?; var theme: String?; var name: String? }
    private struct Model: Decodable { var primary: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        if let identity = try c.decodeIfPresent(Identity.self, forKey: .identity) {
            emoji = identity.emoji
            avatarUrl = identity.avatarUrl
            theme = identity.theme
            if name == nil { name = identity.name }
        }
        model = (try c.decodeIfPresent(Model.self, forKey: .model))?.primary
    }

    /// Direct init for demo agents / previews.
    init(id: String, name: String? = nil, emoji: String? = nil,
         model: String? = nil, workspace: String? = nil) {
        self.id = id; self.name = name; self.emoji = emoji
        self.model = model; self.workspace = workspace
    }
}

/// `agents.list` result: the default agent id + the roster.
struct AgentsListResult: Decodable, Sendable {
    let defaultId: String
    let agents: [AgentSummary]
}
