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

    init(agent: AgentSummary, sync: SyncSource, isConfigured: Bool) {
        self.agent = agent
        self.sync = sync
        self.isConfigured = isConfigured
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
        let beforeInstructions = instructions
        let outcome = await MainAgentTask.run(
            ws, instruction: req.instruction,
            idempotencyKey: "edit-agent-\(UUID().uuidString)") { [sync, agent, req] () async -> (AgentSummary?, String?)? in
            let after = (try? await sync.listAgents()) ?? []
            let newInstructions = try? await sync.loadInstructions(agentId: agent.id)
            let instructionsChanged = !req.instructions.trimmingCharacters(in: .whitespaces).isEmpty
                && newInstructions != nil && newInstructions != beforeInstructions
            guard AgentProfile.updateApplied(want: req, in: after) || instructionsChanged else { return nil }
            return (after.first(where: { $0.id == agent.id }), newInstructions)
        }
        switch outcome {
        case .done(let (fresh, newInstructions)):
            if let fresh { agent = fresh }
            if let newInstructions { instructions = newInstructions }
            edit = .saved
        case .pending:         edit = .pending
        case .failed(let msg): edit = .failed(msg)
        }
    }

    func delete() async -> Bool {
        guard isConfigured, let ws = sync as? GatewayWSSyncSource else { return false }
        edit = .saving
        let text = "DELETE-AGENT REQUEST (from the profile editor). Delete agent \(agent.id) "
            + "with agents.delete, then confirm it is gone from agents.list. Reply DELETED \(agent.id)."
        let outcome = await MainAgentTask.run(
            ws, instruction: text, idempotencyKey: "delete-agent-\(UUID().uuidString)") { [sync, agent] in
            let after = (try? await sync.listAgents()) ?? []
            return after.contains(where: { $0.id == agent.id }) ? nil : true
        }
        if case .done = outcome { return true }
        edit = .pending
        return false
    }
}
