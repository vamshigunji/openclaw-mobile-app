import SwiftUI

/// One `session.tool` signal reduced to what a developer wants to see: the tool's real
/// name and, when its args carry one, the thing it acted on. Nothing here is inferred.
struct ToolEvent: Equatable {
    enum Phase: Equatable { case start, result }
    static let summaryLimit = 80

    let name: String
    let summary: String?
    let phase: Phase

    /// nil for anything that is not a `session.tool` frame carrying a tool name.
    static func from(_ env: InboundEnvelope) -> ToolEvent? {
        guard env.eventKind == "session.tool", let data = env.payload?.data, let name = data.name else {
            return nil
        }
        let finished = ["result", "end", "error"].contains(data.phase ?? "")
        return ToolEvent(name: name, summary: summary(from: data.args), phase: finished ? .result : .start)
    }

    /// First non-empty of command | file_path | path | query | pattern | url, cut to 80 chars.
    static func summary(from args: [String: String]?) -> String? {
        guard let args else { return nil }
        for key in ["command", "file_path", "path", "query", "pattern", "url"] {
            guard let v = args[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { continue }
            return v.count > summaryLimit ? String(v.prefix(summaryLimit - 1)) + "…" : v
        }
        return nil
    }
}

/// The tool calls of the current run, in order. A result closes the most recent open entry
/// with the same name; `closeAll` ends the run (chat final/aborted/error, lifecycle end).
struct ToolTimeline: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: Int
        let name: String
        let summary: String?
        var isRunning: Bool
    }

    private(set) var entries: [Entry] = []

    var runningCount: Int { entries.filter(\.isRunning).count }

    mutating func apply(_ event: ToolEvent) {
        switch event.phase {
        case .start:
            entries.append(Entry(id: entries.count, name: event.name, summary: event.summary, isRunning: true))
        case .result:
            if let i = entries.lastIndex(where: { $0.isRunning && $0.name == event.name }) {
                entries[i].isRunning = false
            }
        }
    }

    mutating func closeAll() {
        for i in entries.indices { entries[i].isRunning = false }
    }

    mutating func reset() { entries.removeAll() }
}

/// Collapsed "▸ 5 tool calls · Bash, Edit, Read" row that expands to the run's tool list.
/// Names are the gateway's own; unknown tools show verbatim — nothing is invented.
struct ToolTimelineView: View {
    let timeline: ToolTimeline
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(Theme.Font.label)
                    Text(summaryLine).font(Theme.Font.label)
                    if timeline.runningCount > 0 {
                        Circle().fill(Theme.teal).frame(width: 5, height: 5)
                    }
                }
                .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summaryLine)

            if expanded {
                ForEach(timeline.entries) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.isRunning ? "circle.dotted" : "checkmark.circle")
                            .font(Theme.Font.label)
                            .foregroundStyle(entry.isRunning ? Theme.teal : Theme.textMuted)
                        Text(entry.name).font(Theme.Font.label).foregroundStyle(Theme.text)
                        if let summary = entry.summary {
                            Text(summary).font(Theme.Font.monoCaption).foregroundStyle(Theme.textMuted).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.borderColor, lineWidth: Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
    }

    private var summaryLine: String {
        var seen = Set<String>()
        let names = timeline.entries.map(\.name).filter { seen.insert($0).inserted }
        let n = timeline.entries.count
        return "\(n) tool call\(n == 1 ? "" : "s") · \(names.prefix(3).joined(separator: ", "))"
    }
}
