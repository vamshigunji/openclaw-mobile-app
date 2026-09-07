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
    /// False while the socket is down — the Board says so rather than showing stale rows as live.
    private(set) var isConnected = true

    private let sync: SyncSource
    private let isConfigured: Bool
    private var sessions: [SessionSummary] = []
    private var tasks: [TaskSummary] = []
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?

    init(sync: SyncSource, isConfigured: Bool) {
        self.sync = sync
        self.isConfigured = isConfigured
    }

    deinit {
        watchTask?.cancel()
        stateTask?.cancel()
    }

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
        stateTask?.cancel()
        stateTask = Task { [weak self, sync] in
            for await up in sync.connectionState() {
                guard let self, !Task.isCancelled else { break }
                let wasConnected = self.isConnected
                self.isConnected = up
                if up, !wasConnected { await self.load() }   // re-read what we missed
            }
        }
    }

    /// Re-read after the app comes back to the foreground (iOS suspends the socket).
    func refreshOnForeground() async {
        await load()
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

    /// Lane names already on the board, for the "move to project" menu.
    var laneNames: [String] { board.lanes.map(\.key) }

    // MARK: - Actions (design §5.5) — each is exactly one write

    /// Archive or restore a card. Archiving a running session cancels its work, so the view
    /// confirms first.
    func archive(_ card: BoardCard, archived: Bool) async {
        await write(optimistic: { $0.archived = archived }, on: card) { [sync] session in
            try await sync.patchSession(key: session.key, expectedSessionId: session.sessionId,
                                        fields: ["archived": archived])
        }
    }

    /// Move a card to another project lane (`category` is the only field touched).
    func move(_ card: BoardCard, toLane lane: String) async {
        await write(optimistic: { $0.category = lane }, on: card) { [sync] session in
            try await sync.patchSession(key: session.key, expectedSessionId: session.sessionId,
                                        fields: ["category": lane])
        }
    }

    /// Start a backlog card: the card's title is the ask, plus any extra notes.
    func start(_ card: BoardCard, note: String) async {
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = extra.isEmpty ? card.title : "\(card.title)\n\n\(extra)"
        await perform {
            try await self.sync.send(sessionKey: card.session.key, agentId: card.session.agentId,
                                     text: message, idempotencyKey: UUID().uuidString)
        }
    }

    /// Stop the run on a card.
    func stop(_ card: BoardCard) async {
        await perform {
            try await self.sync.abort(sessionKey: card.session.key,
                                      agentId: card.session.agentId, runId: nil)
        }
    }

    /// Cancel one background task.
    func cancel(_ task: TaskSummary) async {
        await perform { try await self.sync.cancelTask(taskId: task.id) }
    }

    /// Create an empty card. It lands in Backlog until someone starts it.
    func createTask(title: String, agentId: String, lane: String?) async {
        await perform {
            try await self.sync.createSession(agentId: agentId, label: title, category: lane)
            await self.load()
        }
    }

    /// Applies a row edit immediately, sends the write, and rolls back if it is rejected.
    private func write(optimistic edit: (inout SessionSummary) -> Void, on card: BoardCard,
                       _ send: @escaping (SessionSummary) async throws -> Void) async {
        guard let index = sessions.firstIndex(where: { $0.key == card.session.key }) else { return }
        let previous = sessions
        edit(&sessions[index])
        rebuild()
        do {
            try await send(card.session)
            error = nil
        } catch {
            sessions = previous
            rebuild()
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A write with nothing to roll back (it changes gateway state, not a row we hold).
    private func perform(_ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The thread a card opens.
    func thread(for card: BoardCard) -> ChatThread {
        ChatThread(sessionKey: card.session.key, agentId: card.session.agentId,
                   title: card.title, emoji: agents.first { $0.id == card.session.agentId }?.emoji)
    }
}
