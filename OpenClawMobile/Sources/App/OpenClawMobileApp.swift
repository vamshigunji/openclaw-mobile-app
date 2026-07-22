import SwiftUI

@main
struct OpenClawMobileApp: App {
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ChatView(settings: settings)
                .preferredColorScheme(.dark)
        }
    }
}
