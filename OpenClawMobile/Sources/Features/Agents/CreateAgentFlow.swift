import Foundation

/// What the "+" form collects. The app can't call `agents.create` (operator.admin),
/// so it compiles these fields into a structured instruction and hands it to the
/// main agent — which holds admin — over `chat.send`. See
/// `designs/2026-07-22-multi-agent-research.md`.
struct CreateAgentRequest {
    var name: String
    var emoji: String = ""
    var model: String = ""
    var behavior: String = ""

    /// Gateway agent ids are lowercase ASCII kebab. "Résumé Bot" → "resume-bot".
    var normalizedId: String {
        // Fold accents to ASCII so ids stay portable (é → e).
        let ascii = name.folding(options: .diacriticInsensitive, locale: .current)
        let lowered = ascii.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        // collapse runs of "-" and trim
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed
    }

    /// The structured request the main agent executes. Mirrors the live-verified
    /// PoC (2026-07-22): agents.create for the shell, agents.files.set to provision
    /// behavior, and a machine-checkable `CREATED <id>` done signal.
    var instruction: String {
        let id = normalizedId
        var lines = [
            "NEW-AGENT REQUEST (from the OpenClaw Mobile \"+\" form).",
            "Create a registered OpenClaw agent and confirm it in agents.list.",
            "id: \(id)",
            "displayName: \(name.trimmingCharacters(in: .whitespaces))",
        ]
        let emojiTrim = emoji.trimmingCharacters(in: .whitespaces)
        if !emojiTrim.isEmpty { lines.append("emoji: \(emojiTrim)") }
        let modelTrim = model.trimmingCharacters(in: .whitespaces)
        if !modelTrim.isEmpty { lines.append("model: \(modelTrim)") }
        let behaviorTrim = behavior.trimmingCharacters(in: .whitespaces)
        lines.append("")
        lines.append("Behavior to provision into the agent's workspace instructions "
                     + "(AGENTS.md / system prompt): \(behaviorTrim.isEmpty ? "a helpful assistant." : behaviorTrim)")
        lines.append("")
        lines.append("Use agents.create for the shell, then agents.files.set (or the "
                     + "workspace AGENTS.md) to make the behavior stick. Pick a sensible "
                     + "workspace path under the agents dir. When it is fully done AND "
                     + "verified in agents.list, reply with exactly one line: CREATED \(id)")
        return lines.joined(separator: "\n")
    }
}

/// Pure helpers for the create flow (delta detection, kept out of the view model
/// so they're unit-testable without a gateway).
enum CreateAgentFlow {
    /// The agent that appeared since `before`. When several appear at once, prefer
    /// the one whose id matches what we asked for (`preferId`); otherwise the first
    /// new one. Detecting the DELTA avoids guessing exactly how the main agent
    /// named it.
    static func newAgent(before: Set<String>, after: [AgentSummary],
                         preferId: String? = nil) -> AgentSummary? {
        let fresh = after.filter { !before.contains($0.id) }
        if let preferId, let match = fresh.first(where: { $0.id == preferId }) {
            return match
        }
        return fresh.first
    }
}
