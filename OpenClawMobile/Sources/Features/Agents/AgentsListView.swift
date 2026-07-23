import SwiftUI

/// Agents tab — the Slack/WhatsApp-style team list. Each row is an agent; tapping
/// pushes that agent's chat thread. All threads share the one connection in AppModel.
struct AgentsListView: View {
    @Bindable var app: AppModel
    @State private var roster: AgentRosterViewModel
    @State private var showSettings = false
    @State private var showCreate = false
    @State private var path: [AgentSummary] = []

    init(app: AppModel) {
        self.app = app
        _roster = State(initialValue: AgentRosterViewModel(
            sync: app.sync, isConfigured: app.settings.isConfigured))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if roster.loading && roster.agents.isEmpty {
                    ProgressView().tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !app.settings.isConfigured { demoBanner.listRowSeparator(.hidden) }
                        ForEach(roster.agents) { agent in
                            NavigationLink(value: agent) { AgentRow(agent: agent) }
                                .listRowBackground(Theme.bgPrimary)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bgPrimary.ignoresSafeArea())
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AgentSummary.self) { agent in
                ChatView(agent: agent, app: app)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").foregroundStyle(Theme.textSecondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus").font(.body.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .accessibilityLabel("New agent")
                }
            }
            .refreshable { await roster.load() }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) { SettingsView(settings: app.settings) }
        .sheet(isPresented: $showCreate) {
            CreateAgentView(app: app) { created in
                // Refresh the roster, then open the new agent's thread.
                Task {
                    await roster.load()
                    if !roster.agents.contains(where: { $0.id == created.id }) {
                        roster.agents.append(created)
                    }
                    path = [created]
                }
            }
        }
        .task {
            await roster.load()
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            // QA: auto-open the first agent's thread for a live round-trip test.
            if args.contains("--seed-demo"), let first = roster.agents.first, path.isEmpty {
                path = [first]
            }
            if args.contains("--open-create") { showCreate = true }
            #endif
        }
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(AgentStatus.waiting.color).frame(width: 7, height: 7)
            Text("Demo agents — pair your gateway in Settings for the real roster")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AgentStatus.waiting.color)
            Spacer()
        }
        .padding(.vertical, 4)
        .listRowBackground(Theme.bgPrimary)
    }
}

/// One agent row: emoji/avatar chip, name, model + workspace subtitle.
struct AgentRow: View {
    let agent: AgentSummary
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(Theme.bgSecondary)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                        .stroke(Theme.borderColor, lineWidth: Theme.border))
                    .frame(width: 40, height: 40)
                Text(agent.emoji ?? "🖥")
                    .font(.system(size: 20))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.displayName)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent \(agent.displayName)")
    }

    private var subtitle: String? {
        [agent.model, agent.workspace].compactMap { $0 }.first
    }
}
