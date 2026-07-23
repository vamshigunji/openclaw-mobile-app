import Observation
import SwiftUI

/// Backs the profile page: READS identity + instructions directly (operator.read),
/// and routes EDIT/DELETE through the main agent (operator.admin, approach B) with
/// a poll to confirm.
@MainActor
@Observable
final class AgentProfileViewModel {
    enum Edit: Equatable { case idle, saving, saved, pending, failed(String) }

    private(set) var agent: AgentSummary
    private(set) var instructions: String?
    private(set) var loadingInstructions = true
    private(set) var edit: Edit = .idle

    private let sync: SyncSource
    private let isConfigured: Bool
    private let pollInterval: Duration
    private let maxPolls: Int
    private let orchestratorId = "main"

    init(agent: AgentSummary, sync: SyncSource, isConfigured: Bool,
         pollInterval: Duration = .seconds(6), maxPolls: Int = 20) {
        self.agent = agent
        self.sync = sync
        self.isConfigured = isConfigured
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    func load() async {
        loadingInstructions = true
        instructions = try? await sync.loadInstructions(agentId: agent.id)
        loadingInstructions = false
        // refresh identity in case it changed
        if let fresh = try? await sync.listAgents().first(where: { $0.id == agent.id }) {
            agent = fresh
        }
    }

    var canEdit: Bool { isConfigured }

    func saveEdit(_ req: EditAgentRequest) async {
        guard isConfigured, let ws = sync as? GatewayWSSyncSource else {
            edit = .failed("Editing needs a paired gateway.")
            return
        }
        edit = .saving
        do {
            try await ws.send(agentId: orchestratorId, text: req.instruction,
                              idempotencyKey: "edit-agent-\(UUID().uuidString)")
        } catch {
            edit = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        let beforeInstructions = instructions
        for _ in 1...maxPolls {
            try? await Task.sleep(for: pollInterval)
            let after = (try? await sync.listAgents()) ?? []
            let identityDone = AgentProfile.updateApplied(want: req, in: after)
            let newInstructions = try? await sync.loadInstructions(agentId: agent.id)
            let instructionsDone = !req.instructions.trimmingCharacters(in: .whitespaces).isEmpty
                && newInstructions != nil && newInstructions != beforeInstructions
            if identityDone || instructionsDone {
                if let fresh = after.first(where: { $0.id == agent.id }) { agent = fresh }
                if let ni = newInstructions { instructions = ni }
                edit = .saved
                return
            }
        }
        edit = .pending
    }

    func delete() async -> Bool {
        guard isConfigured, let ws = sync as? GatewayWSSyncSource else { return false }
        edit = .saving
        let text = "DELETE-AGENT REQUEST (from the profile editor). Delete agent \(agent.id) "
            + "with agents.delete, then confirm it is gone from agents.list. Reply DELETED \(agent.id)."
        try? await ws.send(agentId: orchestratorId, text: text,
                           idempotencyKey: "delete-agent-\(UUID().uuidString)")
        for _ in 1...maxPolls {
            try? await Task.sleep(for: pollInterval)
            let after = (try? await sync.listAgents()) ?? []
            if !after.contains(where: { $0.id == agent.id }) { return true }
        }
        edit = .pending
        return false
    }
}
