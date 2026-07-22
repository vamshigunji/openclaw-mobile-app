import Foundation

/// The multi-device sync seam (PRD-handshake Path E / seam toward Path D).
///
/// Abstracts **history load + subscribe** away from any single transport so the
/// Chat view model never talks to `GatewayClient` (or a future BFF) directly for
/// fan-in. In Path A this is backed by the gateway's protocol-v4 WS RPC
/// (`GatewayWSSyncSource`); in a future Path D the *same* protocol is backed by a
/// backend-for-frontend — the UI, optimistic-send, and cache logic do not change
/// across that swap.
///
/// Deliberately does **not** abstract *sending*: per PRD-handshake §5 the send path
/// stays on the WS write path with a client idempotency key (see
/// `GatewayWSSyncSource.send`). Whether a future BFF should also own batching/queued
/// sends is left open until Path D is scoped.
///
/// It consumes an already-authenticated session — pairing / challenge-signing /
/// Secure-Enclave is owned by `.docs/protocol.md` and is NOT
/// re-implemented here.
protocol SyncSource: Sendable {
    /// Snapshot/replay backfill for a session (Path A: `sessions.messages.list`).
    /// Returns oldest-first. Errors surface as `GatewayError`.
    func loadHistory(sessionId: String) async throws -> [ChatMessage]

    /// Live fan-in: yields every `session.message` the gateway broadcasts for this
    /// session, including turns originating on *other* paired devices. The stream
    /// finishes when the subscription closes; failures throw `GatewayError`.
    func subscribe(sessionId: String) -> AsyncThrowingStream<ChatMessage, Error>
}

/// Demo-backed conformer: a single standalone device with no peers and no gateway.
/// Keeps the app usable/screenshottable with no host configured (CLAUDE.md: the
/// demo path must be preserved). History is empty and there is nothing to fan in,
/// so `subscribe` finishes immediately — the demo reply is produced locally by
/// `GatewayClient.demoStream`, unchanged.
struct DemoSyncSource: SyncSource {
    func loadHistory(sessionId: String) async throws -> [ChatMessage] { [] }

    func subscribe(sessionId: String) -> AsyncThrowingStream<ChatMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish() // no remote peers in demo mode
        }
    }
}
