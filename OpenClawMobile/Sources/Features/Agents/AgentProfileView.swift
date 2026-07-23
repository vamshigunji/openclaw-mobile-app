import SwiftUI

/// Distinct nav value for the profile push (AgentSummary already routes to ChatView).
struct ProfileRoute: Hashable { let agent: AgentSummary }

/// Agent profile — reached by tapping the agent name in the chat header. Shows the
/// real identity + behavior (read directly), with Edit and Delete (routed through
/// the main agent).
struct AgentProfileView: View {
    @Bindable var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var vm: AgentProfileViewModel
    @State private var showEdit = false

    init(agent: AgentSummary, app: AppModel) {
        self.app = app
        _vm = State(initialValue: AgentProfileViewModel(
            agent: agent, sync: app.sync, isConfigured: app.settings.isConfigured))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                rows
                instructionsSection
                if vm.canEdit {
                    PrimaryButton(title: "Edit Agent") { showEdit = true }
                    deleteButton
                } else {
                    Text("Editing needs a paired gateway (Settings).")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .sheet(isPresented: $showEdit) {
            AgentEditView(vm: vm, current: currentReq)
        }
    }

    private var currentReq: EditAgentRequest {
        EditAgentRequest(agentId: vm.agent.id, name: vm.agent.displayName,
                         emoji: vm.agent.emoji ?? "", model: vm.agent.model ?? "",
                         instructions: vm.instructions ?? "")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(vm.agent.emoji ?? "🖥").font(.system(size: 44))
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.agent.displayName)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let m = vm.agent.model {
                    Text(m).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            row("ID", vm.agent.id)
            if let w = vm.agent.workspace { row("Workspace", w) }
            if let m = vm.agent.model { row("Model", m) }
        }
        .background(Theme.bgSecondary)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(12)
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INSTRUCTIONS (AGENTS.md)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            if vm.loadingInstructions {
                ProgressView().tint(Theme.accent).padding(.vertical, 8)
            } else {
                Text(vm.instructions ?? "No instructions file found for this agent.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.bgSecondary)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
                    .textSelection(.enabled)
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Task { if await vm.delete() { dismiss() } }
        } label: {
            Text("Delete Agent")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(AgentStatus.failed.color)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(AgentStatus.failed.color.opacity(0.5), lineWidth: Theme.border))
        }
    }

}

/// Edit sheet — routes changes through the main agent (approach B).
struct AgentEditView: View {
    let vm: AgentProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var req: EditAgentRequest

    init(vm: AgentProfileViewModel, current: EditAgentRequest) {
        self.vm = vm
        _req = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch vm.edit {
                    case .idle, .saving: form
                    case .saved:   done("Saved", "The agent has been updated.", AgentStatus.idle.color)
                    case .pending: done("Still working…", "main hasn't confirmed yet — pull to refresh the profile shortly.", AgentStatus.waiting.color)
                    case .failed(let m): done("Failed", m, AgentStatus.failed.color)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .background(Theme.bgPrimary.ignoresSafeArea())
            .navigationTitle("Edit \(req.agentId)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            MonoField(label: "Name", text: $req.name)
            HStack(spacing: 12) {
                MonoField(label: "Emoji", text: $req.emoji).frame(width: 90)
                MonoField(label: "Model", text: $req.model)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("INSTRUCTIONS (AGENTS.md)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                TextEditor(text: $req.instructions)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(Theme.bgSecondary)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
            }
            Button {
                Task { await vm.saveEdit(req) }
            } label: {
                HStack {
                    if vm.edit == .saving { ProgressView().tint(Theme.bgPrimary) }
                    Text(vm.edit == .saving ? "Asking main…" : "Save Changes")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.accent).foregroundStyle(Theme.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .disabled(vm.edit == .saving)
            Text("Changes go through your main agent (agents.update / agents.files.set). Takes up to a minute.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func done(_ title: String, _ msg: String, _ color: Color) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.system(.headline, design: .monospaced)).foregroundStyle(color)
            Text(msg).font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.accent).foregroundStyle(Theme.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

}
