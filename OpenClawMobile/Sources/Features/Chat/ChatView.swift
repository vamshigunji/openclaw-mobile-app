import SwiftUI

struct ChatView: View {
    @State private var vm: ChatViewModel
    private let agent: AgentSummary
    private let app: AppModel
    private let isConfigured: Bool

    /// One thread, sharing the app-wide connection. Defaults to the agent's main thread;
    /// pass `thread` to open another session of the same agent (a Board card).
    init(agent: AgentSummary, app: AppModel, thread: ChatThread? = nil) {
        self.agent = agent
        self.app = app
        self.isConfigured = app.settings.isConfigured
        let t = thread ?? ChatThread.main(for: agent)
        _vm = State(initialValue: ChatViewModel(thread: t, sync: app.sync, settings: app.settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            ChatInputBar(text: $vm.draft, canSend: vm.canSend, onSend: vm.send,
                         canStop: vm.canStop, onStop: { Task { await vm.stop() } },
                         attachments: vm.pendingAttachments,
                         hint: vm.attachmentHint ?? vm.dictation.hint,
                         isDictating: vm.dictation.isListening,
                         onRemoveAttachment: vm.removeAttachment,
                         onPhotos: { items in Task { await vm.addPhotos(items) } },
                         onCameraImage: vm.addCameraImage,
                         onFiles: vm.addFiles,
                         onMic: vm.toggleDictation)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(vm.thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink(value: ProfileRoute(agent: agent)) {
                    VStack(spacing: 1) {
                        HStack(spacing: 6) {
                            Text(vm.thread.emoji ?? "🖥")
                            Text(vm.thread.title)
                                .font(Theme.Font.title)
                                .foregroundStyle(Theme.text)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(Theme.textMuted)
                        }
                        ActivityLine(activity: vm.activity)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .toolbarBackground(Theme.bg, for: .navigationBar)
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
                        MessageBubble(message: msg, agentName: agent.displayName, agentEmoji: agent.emoji,
                                      onRetry: { Task { await vm.retry(msg) } })
                            .id(msg.id)
                    }
                    if !vm.timeline.entries.isEmpty {
                        ToolTimelineView(timeline: vm.timeline)
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
