import SwiftUI

struct ChatView: View {
    @State private var vm: ChatViewModel
    private let agent: AgentSummary
    private let app: AppModel
    private let isConfigured: Bool

    /// One thread for one agent, sharing the app-wide connection.
    init(agent: AgentSummary, app: AppModel) {
        self.agent = agent
        self.app = app
        self.isConfigured = app.settings.isConfigured
        _vm = State(initialValue: ChatViewModel(agent: agent, sync: app.sync, settings: app.settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            ChatInputBar(text: $vm.draft, canSend: vm.canSend, onSend: vm.send)
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .navigationTitle(agent.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink(value: ProfileRoute(agent: agent)) {
                    VStack(spacing: 1) {
                        HStack(spacing: 6) {
                            Text(agent.emoji ?? "🖥")
                            Text(agent.displayName)
                                .font(.system(.headline, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                        ActivityLine(activity: vm.activity)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .toolbarBackground(Theme.bgPrimary, for: .navigationBar)
        .onAppear {
            vm.start()
            if ProcessInfo.processInfo.arguments.contains("--seed-demo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { vm.seedDemo() }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg).id(msg.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: vm.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}
