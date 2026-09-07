import SwiftUI

/// iOS-native bottom tab bar. Agents tab = the roster (Slack-style team list) →
/// tap an agent → its chat thread. Settings tab = pairing + gateway config.
struct RootTabView: View {
    @Bindable var app: AppModel
    @State private var tab = Tab.agents
    @Environment(\.scenePhase) private var scenePhase

    enum Tab: Hashable { case agents, board, settings }

    var body: some View {
        TabView(selection: $tab) {
            AgentsListView(app: app)
                .tabItem { Label("Agents", systemImage: "person.2.fill") }
                .tag(Tab.agents)

            BoardView(app: app)
                .tabItem { Label("Board", systemImage: "square.stack.3d.up.fill") }
                .tag(Tab.board)

            NavigationStack {
                SettingsView(settings: app.settings)
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the socket seconds after backgrounding; coming back means
            // reconnecting and re-reading rather than trusting what is on screen.
            if phase == .active { app.refreshOnForeground() }
        }
        #if DEBUG
        .onAppear {
            // QA hook: the simulator can't tap, so let a launch arg open the Board.
            if ProcessInfo.processInfo.arguments.contains("--open-board") { tab = .board }
        }
        #endif
    }
}
