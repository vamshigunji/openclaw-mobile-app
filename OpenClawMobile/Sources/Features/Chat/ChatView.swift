import SwiftUI

struct ChatView: View {
    @State private var vm: ChatViewModel
    @Bindable var settings: SettingsStore
    @State private var showSettings = false

    init(settings: SettingsStore) {
        self.settings = settings
        _vm = State(initialValue: ChatViewModel(settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.borderColor)
            messageList
            ChatInputBar(text: $vm.draft, canSend: vm.canSend, onSend: vm.send)
        }
        .background(Theme.bgPrimary.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
        .onAppear {
            vm.start()
            if ProcessInfo.processInfo.arguments.contains("--seed-demo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { vm.seedDemo() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.accent).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("agent-01")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Text(settings.isConfigured ? settings.host : "demo mode")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            StatusBadge(status: vm.isStreaming ? .working : .idle)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.bgPrimary)
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
