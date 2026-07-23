import Foundation

/// The shared "ask the main agent to do an admin thing, then poll to confirm"
/// flow (approach B) behind create / edit / delete. The app can't call the
/// admin RPCs, so it sends a structured instruction to `main` and polls until
/// `check` reports done.
@MainActor
enum MainAgentTask {
    static let orchestratorId = "main"
    private static let pollInterval: Duration = .seconds(6)
    private static let maxPolls = 20

    enum Outcome<T> {
        case done(T)      // `check` reported completion
        case pending      // window elapsed; main may still be working
        case failed(String)
    }

    /// Send `instruction` to main, then poll `check` each interval until it returns
    /// a non-nil value (done) or the window elapses (pending). `onPoll` fires with
    /// elapsed seconds for progress UI.
    static func run<T>(
        _ ws: GatewayWSSyncSource,
        instruction: String,
        idempotencyKey: String,
        onPoll: ((Int) -> Void)? = nil,
        check: () async -> T?
    ) async -> Outcome<T> {
        do {
            try await ws.send(agentId: orchestratorId, text: instruction, idempotencyKey: idempotencyKey)
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        for attempt in 1...maxPolls {
            try? await Task.sleep(for: pollInterval)
            onPoll?(attempt * Int(pollInterval.components.seconds))
            if let done = await check() { return .done(done) }
        }
        return .pending
    }
}
