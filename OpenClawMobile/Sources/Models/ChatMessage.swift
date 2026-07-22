import Foundation

/// A single message in a conversation with an agent.
struct ChatMessage: Identifiable, Codable, Hashable {
    let id: UUID
    var role: Role
    var text: String
    let createdAt: Date
    var isStreaming: Bool
    var failed: Bool
    /// Client-generated idempotency key for the send that produced this message.
    /// Lets the sender reconcile the gateway's broadcast echo against the optimistic
    /// bubble and de-duplicate it (PRD-handshake P3/P5). Nil for demo/local messages.
    var clientMessageId: String?

    enum Role: String, Codable { case user, assistant }

    init(id: UUID = UUID(),
         role: Role,
         text: String,
         createdAt: Date = Date(),
         isStreaming: Bool = false,
         failed: Bool = false,
         clientMessageId: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.failed = failed
        self.clientMessageId = clientMessageId
    }
}
