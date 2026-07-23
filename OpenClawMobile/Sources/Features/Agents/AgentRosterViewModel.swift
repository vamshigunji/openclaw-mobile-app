import Observation
import SwiftUI

/// Fetches the agent roster (`agents.list`) for the Agents tab. Never leaves the
/// list empty: demo mode returns canned agents, and a real gateway with zero
/// agents falls back to the default `main` row so the user always has a thread.
@MainActor
@Observable
final class AgentRosterViewModel {
    var agents: [AgentSummary] = []
    var loading = false
    var error: String?

    private let sync: SyncSource
    private let isConfigured: Bool

    init(sync: SyncSource, isConfigured: Bool) {
        self.sync = sync
        self.isConfigured = isConfigured
    }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let fetched = try await sync.listAgents()
            agents = fetched.isEmpty ? [AgentSummary(id: "main", name: "main")] : fetched
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Keep a usable default so the roster is never a dead end.
            if agents.isEmpty { agents = [AgentSummary(id: "main", name: "main")] }
        }
    }
}
