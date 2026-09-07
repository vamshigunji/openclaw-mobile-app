import SwiftUI

/// The "+" new-agent form. Collects fields, then asks the main agent to create it
/// (approach B — the app can't call agents.create directly). Honest about the
/// mechanism: a request to your main agent, not an instant action.
struct CreateAgentView: View {
    @Bindable var app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Called with the created agent so the roster can refresh/append + navigate.
    var onCreated: (AgentSummary) -> Void
    @State private var vm: CreateAgentViewModel

    init(app: AppModel, onCreated: @escaping (AgentSummary) -> Void) {
        self.app = app
        self.onCreated = onCreated
        _vm = State(initialValue: CreateAgentViewModel(
            sync: app.sync, isConfigured: app.settings.isConfigured))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch vm.phase {
                    case .editing:            form
                    case .asking:             asking
                    case .created(let a):     created(a)
                    case .pending:            pending
                    case .failed(let m):      failed(m)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Theme.textMuted)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            #if DEBUG
            // QA: prefill + auto-submit to exercise the live send+poll path.
            let env = ProcessInfo.processInfo.environment
            if let name = env["SEED_AGENT_NAME"] {
                vm.req.name = name
                vm.req.emoji = env["SEED_AGENT_EMOJI"] ?? ""
                vm.req.behavior = env["SEED_AGENT_BEHAVIOR"] ?? "a helpful assistant"
                await vm.submit()
            }
            #endif
        }
    }

    // MARK: - Editing

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            MonoField(label: "Name", placeholder: "Indian Timer", text: $vm.req.name)
            HStack(spacing: 12) {
                MonoField(label: "Emoji", placeholder: "🇮🇳", text: $vm.req.emoji).frame(width: 90)
                MonoField(label: "Model (optional)", placeholder: "haiku", text: $vm.req.model)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What should it do?")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.textMuted)
                TextEditor(text: $vm.req.behavior)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
                if vm.req.behavior.isEmpty {
                    Text("e.g. \"For any message, only reply the current time in India (IST). Read the real clock each time.\"")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            PrimaryButton(title: "Create Agent", disabled: !vm.canSubmit) {
                Task { await vm.submit(); finishIfDone() }
            }
            Text(app.settings.isConfigured
                 ? "The app asks your main agent to create this. It runs agents.create with its own admin rights — takes up to a minute, and isn't instant."
                 : "Demo mode — this adds a local agent so you can see the flow. Pair your gateway to create real ones.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: - Phases

    private var asking: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.accent)
            Text("Asking main to set up “\(vm.req.name)”…")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("main is running agents.create with its own admin rights. \(vm.elapsed)s elapsed.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func created(_ a: AgentSummary) -> some View {
        VStack(spacing: 14) {
            Text(a.emoji ?? "✅").font(.system(size: 40))
            Text("Created \(a.displayName)")
                .font(Theme.Font.title)
                .foregroundStyle(Theme.accent)
            Text("It's in your Agents list now.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textMuted)
            PrimaryButton(title: "Open \(a.displayName) →") { onCreated(a); dismiss() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var pending: some View {
        VStack(spacing: 14) {
            Text("⏳").font(.system(size: 40))
            Text("Still working…")
                .font(Theme.Font.title)
                .foregroundStyle(AgentStatus.waiting.color)
            Text("main hasn't finished within \(vm.elapsed)s. It may still complete — pull to refresh the Agents list in a moment, or check main directly.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Done") { dismiss() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text("✗").font(.system(size: 40)).foregroundStyle(AgentStatus.failed.color)
            Text("Couldn't reach main")
                .font(Theme.Font.title)
                .foregroundStyle(AgentStatus.failed.color)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func finishIfDone() {
        // created/pending/failed are terminal; the buttons drive dismissal.
    }

    // MARK: - Components (Theme tokens only)


}
