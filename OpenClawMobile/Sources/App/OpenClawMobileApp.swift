import SwiftUI

@main
struct OpenClawMobileApp: App {
    @State private var settings = SettingsStore()

    init() {
        #if DEBUG
        // Simulator/E2E seeding: inject a pre-paired identity so automated runs
        // can hit a live gateway without driving the pairing UI.
        // (SIMCTL_CHILD_SEED_HOST / _SEED_DEVICE_TOKEN / _SEED_DEVICE_KEY)
        let env = ProcessInfo.processInfo.environment
        if let host = env["SEED_HOST"] { settings.host = host }
        if let token = env["SEED_DEVICE_TOKEN"] { settings.deviceToken = token }
        if let keyB64 = env["SEED_DEVICE_KEY"] {
            KeychainService.set(keyB64, for: "device.ed25519.rawPrivateKey")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ChatView(settings: settings)
                .preferredColorScheme(.dark)
        }
    }
}
