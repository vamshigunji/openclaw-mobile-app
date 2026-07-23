import SwiftUI

/// iOS-native bottom tab bar. Agents tab = the roster (Slack-style team list) →
/// tap an agent → its chat thread. Settings tab = pairing + gateway config.
struct RootTabView: View {
    @Bindable var app: AppModel

    var body: some View {
        TabView {
            AgentsListView(app: app)
                .tabItem { Label("Agents", systemImage: "person.2.fill") }

            NavigationStack {
                SettingsView(settings: app.settings)
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
