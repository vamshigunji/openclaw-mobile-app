import Foundation

/// Edit request for an existing agent. The app can't call `agents.update` /
/// `agents.files.set` (operator.admin) so — like create — it compiles a structured
/// instruction and sends it to the main agent. Only non-empty fields are changed.
struct EditAgentRequest {
    let agentId: String
    var name: String = ""
    var emoji: String = ""
    var model: String = ""
    var instructions: String = ""

    private func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    var instruction: String {
        var lines = [
            "EDIT-AGENT REQUEST (from the OpenClaw Mobile profile editor).",
            "Update the existing agent and confirm in agents.list.",
            "agentId: \(agentId)",
        ]
        if !t(name).isEmpty { lines.append("set displayName: \(t(name))") }
        if !t(emoji).isEmpty { lines.append("set emoji: \(t(emoji))") }
        if !t(model).isEmpty { lines.append("set model: \(t(model))") }
        var usesFiles = false
        if !t(instructions).isEmpty {
            usesFiles = true
            lines.append("")
            lines.append("set the agent's instructions (write AGENTS.md in its workspace) to EXACTLY:")
            lines.append("---")
            lines.append(t(instructions))
            lines.append("---")
        }
        lines.append("")
        let tools = usesFiles ? "agents.update for identity fields and agents.files.set for AGENTS.md"
                              : "agents.update"
        lines.append("Use \(tools). When done AND verified, reply with exactly one line: UPDATED \(agentId)")
        return lines.joined(separator: "\n")
    }
}

/// Pure helpers for the profile page.
enum AgentProfile {
    /// The workspace file that holds the agent's behavior. AGENTS.md is the primary
    /// instructions file (LIVE-verified); otherwise the first markdown file.
    static func instructionsFile(from files: [String]) -> String? {
        if let agents = files.first(where: { $0.caseInsensitiveCompare("AGENTS.md") == .orderedSame }) {
            return agents
        }
        return files.first { $0.lowercased().hasSuffix(".md") }
    }

    /// True when the roster now reflects the requested identity change (name/emoji/
    /// model). Returns false for instructions-only edits — those aren't visible in
    /// agents.list, so confirm those by re-reading the file instead.
    static func updateApplied(want: EditAgentRequest, in agents: [AgentSummary]) -> Bool {
        guard let a = agents.first(where: { $0.id == want.agentId }) else { return false }
        let identityFields = !want.name.isEmpty || !want.emoji.isEmpty || !want.model.isEmpty
        guard identityFields else { return false } // instructions-only: not visible here
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        if !want.name.isEmpty && a.name != t(want.name) { return false }
        if !want.emoji.isEmpty && a.emoji != t(want.emoji) { return false }
        if !want.model.isEmpty && a.model != t(want.model) { return false }
        return true
    }
}
