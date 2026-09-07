import SwiftUI

/// The Board tab: one page per column, project lanes inside. Read-only in this cut —
/// tapping a card opens its thread.
struct BoardView: View {
    @Bindable var app: AppModel
    @State private var vm: BoardViewModel
    @State private var column: BoardColumn = .running
    @State private var confirmArchive: BoardCard?
    @State private var starting: BoardCard?
    @State private var startNote = ""
    @State private var movingLane: BoardCard?
    @State private var showNewTask = false

    init(app: AppModel) {
        self.app = app
        _vm = State(initialValue: BoardViewModel(sync: app.sync, isConfigured: app.settings.isConfigured))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                columnPicker
                if let error = vm.error {
                    Label(error, systemImage: AgentStatus.failed.symbol)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                TabView(selection: $column) {
                    ForEach(BoardColumn.allCases, id: \.self) { column in
                        page(for: column).tag(column)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(Theme.bg)
            .navigationTitle("Board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { agentMenu }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showNewTask = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New task")
                }
            }
            .refreshable { await vm.load() }
            .confirmationDialog(archiveTitle, isPresented: archiveBinding, presenting: confirmArchive) { card in
                Button("Archive", role: .destructive) { Task { await vm.archive(card, archived: true) } }
                Button("Cancel", role: .cancel) {}
            } message: { card in
                Text(card.column == .running
                     ? "This session is running. Archiving it cancels the work in progress."
                     : "It moves to Done. You can restore it from there.")
            }
            .sheet(item: $starting) { card in
                StartCardSheet(title: card.title, note: $startNote) {
                    Task { await vm.start(card, note: startNote); startNote = "" }
                }
            }
            .sheet(item: $movingLane) { card in
                LanePickerSheet(lanes: vm.laneNames, current: laneKey(of: card)) { lane in
                    Task { await vm.move(card, toLane: lane) }
                }
            }
            .sheet(isPresented: $showNewTask) {
                NewTaskSheet(agents: vm.agents, lanes: vm.laneNames) { title, agentId, lane in
                    Task { await vm.createTask(title: title, agentId: agentId, lane: lane) }
                }
            }
        }
        .onAppear { vm.start() }
    }

    private var columnPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BoardColumn.allCases, id: \.self) { c in
                    let count = cards(in: c).count
                    Button { withAnimation(.easeOut(duration: 0.2)) { column = c } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: c.symbol).font(Theme.Font.label)
                            Text(c.title).font(Theme.Font.label)
                            if count > 0 {
                                Text("\(count)")
                                    .font(Theme.Font.label)
                                    .foregroundStyle(column == c ? Theme.accent : Theme.textMuted)
                            }
                        }
                        .foregroundStyle(column == c ? Theme.accent : Theme.textMuted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(column == c ? Theme.accentSubtle : Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius)
                                .stroke(column == c ? Theme.accent : Theme.borderColor, lineWidth: Theme.border)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var agentMenu: some View {
        Menu {
            Button { vm.agentFilter = nil } label: {
                Label("All agents", systemImage: vm.agentFilter == nil ? "checkmark" : "person.2")
            }
            ForEach(vm.agents) { agent in
                Button { vm.agentFilter = agent.id } label: {
                    Label(agent.displayName, systemImage: vm.agentFilter == agent.id ? "checkmark" : "person")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(vm.agentFilter == nil ? Theme.textMuted : Theme.accent)
        }
        .accessibilityLabel("Filter by agent")
    }

    private func cards(in column: BoardColumn) -> [BoardCard] {
        vm.board.lanes.flatMap { $0.columns[column] ?? [] }
    }

    @ViewBuilder
    private func page(for column: BoardColumn) -> some View {
        let lanes = vm.board.lanes.filter { !($0.columns[column] ?? []).isEmpty }
        if lanes.isEmpty {
            emptyState(for: column)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lanes) { lane in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lane.key.uppercased())
                                .font(Theme.Font.label)
                                .foregroundStyle(Theme.textMuted)
                            ForEach(lane.columns[column] ?? []) { card in
                                NavigationLink {
                                    ChatView(agent: agent(for: card), app: app, thread: vm.thread(for: card))
                                } label: {
                                    BoardCardView(card: card)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { menu(for: card) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private var archiveTitle: String { confirmArchive?.column == .running ? "Stop and archive?" : "Archive this card?" }

    private var archiveBinding: Binding<Bool> {
        Binding(get: { confirmArchive != nil }, set: { if !$0 { confirmArchive = nil } })
    }

    private func laneKey(of card: BoardCard) -> String {
        ProjectLane.key(for: card.session, agents: vm.agents)
    }

    @ViewBuilder
    private func menu(for card: BoardCard) -> some View {
        if card.column == .backlog {
            Button { starting = card } label: { Label("Start work", systemImage: "play.fill") }
        }
        if card.column == .running {
            Button { Task { await vm.stop(card) } } label: { Label("Stop run", systemImage: "stop.fill") }
        }
        Button { movingLane = card } label: { Label("Move to project…", systemImage: "folder") }
        ForEach(card.tasks.filter { $0.status == .running || $0.status == .queued }) { task in
            Button(role: .destructive) { Task { await vm.cancel(task) } } label: {
                Label("Cancel \(task.title ?? "task")", systemImage: "xmark.circle")
            }
        }
        if card.session.archived {
            Button { Task { await vm.archive(card, archived: false) } } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
        } else {
            Button(role: .destructive) { confirmArchive = card } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    private func agent(for card: BoardCard) -> AgentSummary {
        vm.agents.first { $0.id == card.session.agentId }
            ?? AgentSummary(id: card.session.agentId, name: card.session.agentId)
    }

    private func emptyState(for column: BoardColumn) -> some View {
        VStack(spacing: 8) {
            Image(systemName: column.symbol).font(.title2).foregroundStyle(Theme.textMuted)
            Text(emptyMessage(for: column)).font(Theme.Font.caption).foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyMessage(for column: BoardColumn) -> String {
        switch column {
        case .backlog:  "Nothing queued up."
        case .running:  vm.loading ? "Loading…" : "No agent is working right now."
        case .needsYou: "Nothing waiting on you."
        case .done:     "Finished work shows up here."
        }
    }
}

/// One card: title, status, live detail, and its sub-tasks.
struct BoardCardView: View {
    let card: BoardCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: status.symbol).font(Theme.Font.label).foregroundStyle(status.color)
                Text(card.title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if card.session.pinned {
                    Image(systemName: "pin.fill").font(Theme.Font.label).foregroundStyle(Theme.textMuted)
                }
            }
            if let detail = card.detail {
                Text(detail).font(Theme.Font.monoCaption).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            HStack(spacing: 8) {
                if let summary = card.taskSummary {
                    Text(summary).font(Theme.Font.caption).foregroundStyle(Theme.textMuted)
                }
                if !card.children.isEmpty {
                    Label("\(card.children.count)", systemImage: "arrow.turn.down.right")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
                if let when = card.session.lastActivityAt {
                    Text(Self.relative(when)).font(Theme.Font.caption).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .stroke(Theme.borderColor, lineWidth: Theme.border)
        )
    }

    private var status: AgentStatus {
        switch card.column {
        case .running:  .working
        case .needsYou: card.session.status == .failed ? .failed : .waiting
        case .done:     .done
        case .backlog:  .idle
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relative(_ millis: Double) -> String {
        formatter.localizedString(for: Date(timeIntervalSince1970: millis / 1000), relativeTo: Date())
    }
}

/// "Start work" on a backlog card: the title is the ask, plus optional extra instructions.
private struct StartCardSheet: View {
    let title: String
    @Binding var note: String
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(Theme.Font.title).foregroundStyle(Theme.text)
                MonoField(label: "Anything to add?", placeholder: "optional", text: $note)
                PrimaryButton(title: "Start") { onStart(); dismiss() }
                Spacer()
            }
            .padding(16)
            .background(Theme.bg)
            .navigationTitle("Start work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// Move a card to another project lane, or type a new one.
private struct LanePickerSheet: View {
    let lanes: [String]
    let current: String
    let onPick: (String) -> Void
    @State private var newLane = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lanes, id: \.self) { lane in
                        Button { onPick(lane); dismiss() } label: {
                            HStack {
                                Text(lane).foregroundStyle(Theme.text)
                                Spacer()
                                if lane == current { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                }
                Section("New project") {
                    MonoField(label: "Name", placeholder: "Website redesign", text: $newLane)
                    PrimaryButton(title: "Move here", disabled: newLane.trimmingCharacters(in: .whitespaces).isEmpty) {
                        onPick(newLane.trimmingCharacters(in: .whitespaces)); dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Move to project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A new card. It lands in Backlog until someone starts it.
private struct NewTaskSheet: View {
    let agents: [AgentSummary]
    let lanes: [String]
    let onCreate: (String, String, String?) -> Void
    @State private var title = ""
    @State private var agentId = ""
    @State private var lane = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                MonoField(label: "Task", placeholder: "Audit the keychain code", text: $title)
                Picker("Agent", selection: $agentId) {
                    ForEach(agents) { agent in Text(agent.displayName).tag(agent.id) }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                Picker("Project", selection: $lane) {
                    Text("None").tag("")
                    ForEach(lanes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)
                PrimaryButton(title: "Create", disabled: title.trimmingCharacters(in: .whitespaces).isEmpty) {
                    onCreate(title.trimmingCharacters(in: .whitespaces), agentId, lane.isEmpty ? nil : lane)
                    dismiss()
                }
                Spacer()
            }
            .padding(16)
            .background(Theme.bg)
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .onAppear { if agentId.isEmpty { agentId = agents.first?.id ?? "main" } }
        }
        .presentationDetents([.medium])
    }
}
