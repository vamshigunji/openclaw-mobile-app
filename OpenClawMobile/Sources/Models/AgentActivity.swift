import Foundation

/// What an agent is doing right now, in verb-ing style. Every case maps to a REAL
/// signal from OpenClaw's event stream (verified on the live wire 2026-07-22):
/// `session.tool` (data.name/phase), `agent` (stream/data.phase), `chat` (state).
/// Unknown signals fall back to `.working` — the indicator never invents a verb.
enum AgentActivity: Equatable {
    case idle
    case working            // active, but no more specific signal (honest fallback)
    case thinking
    case planning
    case typing
    case searchingWeb
    case browsing
    case runningCommand
    case readingFiles
    case searchingFiles
    case editingFiles
    case checkingMemory
    case usingSkill
    case delegating
    case waitingApproval

    var isActive: Bool { self != .idle }

    /// Verb-ing label for the chat header. `idle` shows nothing.
    var label: String? {
        switch self {
        case .idle:            nil
        case .working:         "Working…"
        case .thinking:        "Thinking…"
        case .planning:        "Planning…"
        case .typing:          "Typing…"
        case .searchingWeb:    "Searching the web"
        case .browsing:        "Browsing"
        case .runningCommand:  "Running a command"
        case .readingFiles:    "Reading files"
        case .searchingFiles:  "Searching files"
        case .editingFiles:    "Editing files"
        case .checkingMemory:  "Checking memory"
        case .usingSkill:      "Using a skill"
        case .delegating:      "Delegating"
        case .waitingApproval: "Waiting for approval"
        }
    }

    /// Map a live event to an activity. Returns nil for events that carry no
    /// activity signal (health/tick/presence/session.message) so the caller keeps
    /// the current state unchanged.
    static func from(_ env: InboundEnvelope) -> AgentActivity? {
        switch env.eventKind {
        case "session.tool":
            guard let data = env.payload?.data else { return .working }
            // A finished tool call returns to generic working; the next signal refines.
            if data.phase == "result" || data.phase == "end" { return .working }
            guard let name = data.name else { return .working }
            return forTool(name)

        case "agent":
            switch env.payload?.stream {
            case "thinking", "thought":              return .thinking
            case "assistant", "assistant_text_stream": return .typing
            case "plan":                             return .planning
            case "approval":                         return .waitingApproval
            case "command_output", "stdout", "stderr", "output": return .runningCommand
            case "patch":                            return .editingFiles
            case "compaction":                       return .working
            case "lifecycle":
                switch env.payload?.data?.phase {
                case "end", "error":                 return .idle
                default:                             return .working
                }
            default:
                return .working // active agent event, unknown stream → honest fallback
            }

        case "skill_expansion":
            return .usingSkill

        case "chat":
            switch env.payload?.state {
            case "delta":                    return .typing
            case "final", "aborted", "error": return .idle
            default:                         return nil
            }

        default:
            return nil // not an activity signal — leave current state as-is
        }
    }

    /// Tool name → verb. Keys on the LIVE claude-cli tool names (WebSearch, Bash …),
    /// case-insensitive. Unknown tools → `.working` (never a fabricated verb).
    static func forTool(_ rawName: String) -> AgentActivity {
        switch rawName.lowercased() {
        case "websearch":                                    return .searchingWeb
        case "webfetch", "browser", "browse":                return .browsing
        case "bash", "shell", "run_command":                 return .runningCommand
        case "read", "ls", "notebookread", "view", "cat":    return .readingFiles
        case "grep", "glob", "find", "search":               return .searchingFiles
        case "edit", "multiedit", "write", "notebookedit",
             "apply_patch", "str_replace":                   return .editingFiles
        case "todowrite", "update_plan", "todoread":         return .planning
        case "task":                                         return .delegating
        case "skill", "skills", "skill_workshop":            return .usingSkill
        default:
            if rawName.lowercased().hasPrefix("memory") { return .checkingMemory }
            return .working
        }
    }
}
