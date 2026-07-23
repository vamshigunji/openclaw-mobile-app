import Observation
import SwiftUI

/// Drives the "+" create flow (approach B). Sends the compiled instruction to the
/// main agent (which holds admin), then polls agents.list for the newly-appeared
/// agent. Honest about the model: this is a REQUEST to an LLM agent, not a direct
/// RPC — it takes tens of seconds and may not fully provision behavior first try.
@MainActor
@Observable
final class CreateAgentViewModel {
    enum Phase: Equatable {
        case editing
        case asking           // instruction sent, waiting for main to act
        case created(AgentSummary)
        case pending          // timed out waiting; main may still be working
        case failed(String)
    }

    var req = CreateAgentRequest(name: "", behavior: "")
    private(set) var phase: Phase = .editing
    private(set) var elapsed = 0

    private let sync: SyncSource
    private let isConfigured: Bool

    init(sync: SyncSource, isConfigured: Bool) {
        self.sync = sync
        self.isConfigured = isConfigured
    }

    var canSubmit: Bool {
        !req.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !req.behavior.trimmingCharacters(in: .whitespaces).isEmpty
            && phase == .editing
    }

    func submit() async {
        guard canSubmit else { return }

        // Demo mode: no gateway to ask — add the agent client-side so the flow is
        // demoable. It won't persist on any gateway.
        guard isConfigured, let ws = sync as? GatewayWSSyncSource else {
            let demo = AgentSummary(id: req.normalizedId,
                                    name: req.name.trimmingCharacters(in: .whitespaces),
                                    emoji: req.emoji.isEmpty ? "✨" : req.emoji,
                                    model: req.model.isEmpty ? "demo" : req.model)
            phase = .created(demo)
            return
        }

        phase = .asking
        let before = Set((try? await sync.listAgents())?.map(\.id) ?? [])
        let outcome = await MainAgentTask.run(
            ws, instruction: req.instruction,
            idempotencyKey: "create-agent-\(UUID().uuidString)",
            onPoll: { self.elapsed = $0 }) { [sync, req] () async -> AgentSummary? in
            guard let after = try? await sync.listAgents() else { return nil }
            return CreateAgentFlow.newAgent(before: before, after: after, preferId: req.normalizedId)
        }
        switch outcome {
        case .done(let created): phase = .created(created)
        case .pending:           phase = .pending
        case .failed(let msg):   phase = .failed(msg)
        }
    }
}
