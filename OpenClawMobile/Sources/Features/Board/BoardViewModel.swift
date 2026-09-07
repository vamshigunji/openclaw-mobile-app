import Foundation
import Observation

/// The Board tab: every agent's work as a Kanban, refreshed from real gateway state.
@MainActor
@Observable
final class BoardViewModel {
    private(set) var board = Board(lanes: [])
    private(set) var loading = false
    var error: String?
    /// Show only one agent's cards; nil = every agent.
    var agentFilter: String? { didSet { rebuild() } }
    /// Agents seen on the board, for the filter menu.
    private(set) var agents: [AgentSummary] = []

    private let sync: SyncSource
    private let isConfigured: Bool
    private var sessions: [SessionSummary] = []
    private var tasks: [TaskSummary] = []
    @ObservationIgnored private var watchTask: Task<Void, Never>?

    init(sync: SyncSource, isConfigured: Bool) {
        self.sync = sync
        self.isConfigured = isConfigured
    }

    deinit { watchTask?.cancel() }

    /// Load once, then follow `sessions.changed`.
    func start() {
        Task { await load() }
        watchTask?.cancel()
        watchTask = Task { [weak self, sync] in
            for await _ in sync.sessionChanges() {
                guard let self, !Task.isCancelled else { break }
                await self.load()
            }
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            async let rows = sync.listSessions()
            async let ledger = sync.listTasks()
            async let roster = sync.listAgents()
            (sessions, tasks, agents) = try await (rows, ledger, roster)
            error = nil
        } catch {
            // Keep the board on screen; a refresh failure is not a reason to blank it.
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        rebuild()
    }

    private func rebuild() {
        let rows = agentFilter.map { id in sessions.filter { $0.agentId == id } } ?? sessions
        board = Board.make(sessions: rows, tasks: tasks, agents: agents)
    }

    /// The thread a card opens.
    func thread(for card: BoardCard) -> ChatThread {
        ChatThread(sessionKey: card.session.key, agentId: card.session.agentId,
                   title: card.title, emoji: agents.first { $0.id == card.session.agentId }?.emoji)
    }
}
