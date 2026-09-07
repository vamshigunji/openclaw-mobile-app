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
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
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
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.text)
                if let m = vm.agent.model {
                    Text(m).font(Theme.Font.monoCaption)
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
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(Theme.Font.label)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(Theme.Font.monoCaption)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(12)
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instructions (AGENTS.md)")
                .font(Theme.Font.label)
                .foregroundStyle(Theme.textMuted)
            if vm.loadingInstructions {
                ProgressView().tint(Theme.accent).padding(.vertical, 8)
            } else {
                Text(vm.instructions ?? "No instructions file found for this agent.")
                    .font(Theme.Font.monoCaption)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
                    .textSelection(.enabled)
            }
        }
    }

    private var deleteButton: some View {
        PrimaryButton(title: "Delete Agent", destructive: true) {
            Task { if await vm.delete() { dismiss() } }
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
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Edit \(req.agentId)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.textMuted)
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
                Text("Instructions (AGENTS.md)")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.textMuted)
                TextEditor(text: $req.instructions)
                    .font(Theme.Font.monoCaption)
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
            }
            Button {
                Task { await vm.saveEdit(req) }
            } label: {
                HStack {
                    if vm.edit == .saving { ProgressView().tint(Theme.bg) }
                    Text(vm.edit == .saving ? "Asking main…" : "Save Changes")
                        .font(Theme.Font.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.brand).foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .disabled(vm.edit == .saving)
            Text("Changes go through your main agent (agents.update / agents.files.set). Takes up to a minute.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func done(_ title: String, _ msg: String, _ color: Color) -> some View {
        VStack(spacing: 12) {
            Text(title).font(Theme.Font.title).foregroundStyle(color)
            Text(msg).font(Theme.Font.caption)
                .foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .font(Theme.Font.body.weight(.semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.brand).foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

}
