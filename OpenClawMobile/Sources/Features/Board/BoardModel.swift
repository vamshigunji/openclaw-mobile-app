import Foundation

// MARK: - Wire rows (gateway `sessions.list` / `tasks.list`)

/// Run status of a session (`SessionRunStatusSchema`). Unknown strings decode as nil so a
/// newer gateway never crashes the board.
enum SessionRunStatus: String, Codable, Sendable {
    case queued, running, done, failed, killed, timeout
}

/// One row of `sessions.list` — only the fields the board reads. Unknown keys are ignored.
struct SessionSummary: Decodable, Identifiable, Sendable {
    struct Worktree: Decodable, Sendable {
        var id: String?
        var branch: String?
        var repoRoot: String?
    }

    var key: String
    var sessionId: String?
    var agentId: String
    var kind: String?
    var label: String?
    var displayName: String?
    var derivedTitle: String?
    var lastMessagePreview: String?
    var status: SessionRunStatus?
    var lastRunError: String?
    var hasActiveRun: Bool?
    var unread = false
    var archived = false
    var pinned = false
    var isMain = false
    var isBackground = false
    var spawnedBy: String?
    var childSessions: [String] = []
    var lastActivityAt: Double?
    var lastReadAt: Double?
    var updatedAt: Double?
    var worktree: Worktree?
    var execCwd: String?
    var spawnedCwd: String?
    var category: String?
    var model: String?
    var estimatedCostUsd: Double?

    var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case key, sessionId, agentId, kind, label, displayName, derivedTitle, lastMessagePreview
        case status, lastRunError, hasActiveRun, unread, archived, pinned, isMain, isBackground
        case spawnedBy, childSessions, lastActivityAt, lastReadAt, updatedAt, worktree
        case execCwd, spawnedCwd, category, model, estimatedCostUsd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        agentId = try c.decode(String.self, forKey: .agentId)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        derivedTitle = try c.decodeIfPresent(String.self, forKey: .derivedTitle)
        lastMessagePreview = try c.decodeIfPresent(String.self, forKey: .lastMessagePreview)
        // An unrecognized status must not fail the whole row.
        status = (try? c.decodeIfPresent(SessionRunStatus.self, forKey: .status)) ?? nil
        lastRunError = try c.decodeIfPresent(String.self, forKey: .lastRunError)
        hasActiveRun = try c.decodeIfPresent(Bool.self, forKey: .hasActiveRun)
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        isBackground = try c.decodeIfPresent(Bool.self, forKey: .isBackground) ?? false
        spawnedBy = try c.decodeIfPresent(String.self, forKey: .spawnedBy)
        childSessions = try c.decodeIfPresent([String].self, forKey: .childSessions) ?? []
        lastActivityAt = try c.decodeIfPresent(Double.self, forKey: .lastActivityAt)
        lastReadAt = try c.decodeIfPresent(Double.self, forKey: .lastReadAt)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        worktree = try c.decodeIfPresent(Worktree.self, forKey: .worktree)
        execCwd = try c.decodeIfPresent(String.self, forKey: .execCwd)
        spawnedCwd = try c.decodeIfPresent(String.self, forKey: .spawnedCwd)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        estimatedCostUsd = try c.decodeIfPresent(Double.self, forKey: .estimatedCostUsd)
    }
}

struct SessionListResponse: Decodable, Sendable {
    var sessions: [SessionSummary]
}

/// Task ledger status (`TaskLedgerStatusSchema`).
enum TaskStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled
    case timedOut = "timed_out"
}

/// One row of `tasks.list` — the background work linked to a session.
struct TaskSummary: Decodable, Identifiable, Sendable {
    struct DiffStat: Decodable, Sendable {
        var files: Int?
        var added: Int?
        var removed: Int?
    }

    var taskId: String?
    var runtime: String?
    var status: TaskStatus?
    var title: String?
    var agentId: String?
    var sessionKey: String?
    var childSessionKey: String?
    var lastToolName: String?
    var progressSummary: String?
    var terminalSummary: String?
    var error: String?
    var diffStat: DiffStat?
    var updatedAt: Double?

    var id: String { taskId ?? UUID().uuidString }

    /// "+41 −8 · 2 files" when the task reports a diff.
    var diffLabel: String? {
        guard let d = diffStat, (d.added ?? 0) + (d.removed ?? 0) > 0 else { return nil }
        var parts = ["+\(d.added ?? 0) −\(d.removed ?? 0)"]
        if let files = d.files, files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

struct TaskListResponse: Decodable, Sendable {
    var tasks: [TaskSummary]
}

// MARK: - Board rules

/// The four board columns (design §5.2).
enum BoardColumn: String, CaseIterable, Sendable {
    case backlog, running, needsYou, done

    var title: String {
        switch self {
        case .backlog:  "Backlog"
        case .running:  "Running"
        case .needsYou: "Needs you"
        case .done:     "Done"
        }
    }

    var symbol: String {
        switch self {
        case .backlog:  "tray"
        case .running:  "bolt.fill"
        case .needsYou: "hand.raised.fill"
        case .done:     "checkmark.circle.fill"
        }
    }

    /// Which column a session belongs in. Order matters — first match wins.
    static func `for`(_ s: SessionSummary) -> BoardColumn {
        if s.archived { return .done }
        if s.hasActiveRun == true { return .running }
        switch s.status {
        case .running, .queued:          return .running
        case .failed, .killed, .timeout: return .needsYou
        case .done:                      return s.unread ? .needsYou : .done
        case nil:                        break
        }
        if s.unread { return .needsYou }
        return s.lastActivityAt == nil ? .backlog : .done
    }
}

/// A project lane. Derived, never guessed (design §5.3).
enum ProjectLane {
    static func key(for s: SessionSummary, agents: [AgentSummary]) -> String {
        if let category = s.category?.trimmed, !category.isEmpty { return category }
        if let root = s.worktree?.repoRoot?.trimmed, !root.isEmpty { return lastComponent(root) }
        if let cwd = (s.execCwd ?? s.spawnedCwd)?.trimmed, !cwd.isEmpty { return lastComponent(cwd) }
        let agent = agents.first { $0.id == s.agentId }
        if let workspace = agent?.workspace?.trimmed, !workspace.isEmpty { return lastComponent(workspace) }
        return agent?.displayName ?? s.agentId
    }

    private static func lastComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}

/// One card: a session, its background tasks, and any sessions it spawned.
struct BoardCard: Identifiable, Sendable {
    var session: SessionSummary
    var tasks: [TaskSummary]
    var children: [SessionSummary]

    var id: String { session.key }
    var column: BoardColumn { BoardColumn.for(session) }

    var title: String {
        for candidate in [session.label, session.derivedTitle, session.displayName,
                          session.lastMessagePreview?.split(separator: "\n").first.map(String.init)] {
            if let text = candidate?.trimmed, !text.isEmpty { return text }
        }
        return session.key
    }

    /// "1 running · 1 done", or nil when the card has no background work.
    var taskSummary: String? {
        guard !tasks.isEmpty else { return nil }
        var counts: [(String, Int)] = []
        let running = tasks.filter { $0.status == .running || $0.status == .queued }.count
        let failed = tasks.filter { $0.status == .failed || $0.status == .timedOut }.count
        let done = tasks.filter { $0.status == .completed }.count
        if running > 0 { counts.append(("running", running)) }
        if failed > 0 { counts.append(("failed", failed)) }
        if done > 0 { counts.append(("done", done)) }
        return counts.map { "\($0.1) \($0.0)" }.joined(separator: " · ")
    }

    /// What the card shows under its title: the running task's progress, or the last error.
    var detail: String? {
        if let running = tasks.first(where: { $0.status == .running }) {
            return running.progressSummary ?? running.lastToolName
        }
        if let error = session.lastRunError?.trimmed, !error.isEmpty { return error }
        return tasks.compactMap(\.diffLabel).first
    }
}

struct ProjectLaneGroup: Identifiable, Sendable {
    var key: String
    var columns: [BoardColumn: [BoardCard]]

    var id: String { key }
    var cards: [BoardCard] { BoardColumn.allCases.flatMap { columns[$0] ?? [] } }
}

/// The assembled board: lanes of columns of cards.
struct Board: Sendable {
    var lanes: [ProjectLaneGroup]

    func card(_ key: String) -> BoardCard? {
        lanes.lazy.flatMap(\.cards).first { $0.id == key }
    }

    var isEmpty: Bool { lanes.allSatisfy { $0.cards.isEmpty } }

    /// Board work only: main threads live on the Agents tab, and non-agent sessions
    /// (global/unknown) are not work. Spawned children fold into their parent card.
    static func make(sessions: [SessionSummary], tasks: [TaskSummary], agents: [AgentSummary]) -> Board {
        let visible = sessions.filter { !$0.isMain && ($0.kind ?? "agent") == "agent" }
        let byKey = Dictionary(uniqueKeysWithValues: visible.map { ($0.key, $0) })
        let parents = visible.filter { row in
            guard let parent = row.spawnedBy else { return true }
            return byKey[parent] == nil // orphan: its parent is not on the board
        }
        let childrenByParent = Dictionary(grouping: visible.filter {
            guard let parent = $0.spawnedBy else { return false }
            return byKey[parent] != nil
        }, by: { $0.spawnedBy! })
        let tasksBySession = Dictionary(grouping: tasks.filter { $0.sessionKey != nil }, by: { $0.sessionKey! })

        let cards = parents.map { session in
            BoardCard(session: session,
                      tasks: tasksBySession[session.key] ?? [],
                      children: childrenByParent[session.key] ?? [])
        }

        let grouped = Dictionary(grouping: cards) { ProjectLane.key(for: $0.session, agents: agents) }
        let lanes = grouped.map { key, cards in
            ProjectLaneGroup(key: key, columns: Dictionary(grouping: cards.sorted(by: cardOrder), by: \.column))
        }
        return Board(lanes: lanes.sorted(by: laneOrder))
    }

    /// Pinned first, then most recently active.
    private static func cardOrder(_ a: BoardCard, _ b: BoardCard) -> Bool {
        if a.session.pinned != b.session.pinned { return a.session.pinned }
        return (a.session.lastActivityAt ?? 0) > (b.session.lastActivityAt ?? 0)
    }

    /// Lanes with running work first, then most recently active.
    private static func laneOrder(_ a: ProjectLaneGroup, _ b: ProjectLaneGroup) -> Bool {
        let aRunning = !(a.columns[.running] ?? []).isEmpty
        let bRunning = !(b.columns[.running] ?? []).isEmpty
        if aRunning != bRunning { return aRunning }
        let aActive = a.cards.compactMap(\.session.lastActivityAt).max() ?? 0
        let bActive = b.cards.compactMap(\.session.lastActivityAt).max() ?? 0
        if aActive != bActive { return aActive > bActive }
        return a.key < b.key
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
