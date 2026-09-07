import SwiftUI

@main
struct OpenClawMobileApp: App {
    @State private var app: AppModel
    @State private var showFirstRun: Bool

    init() {
        let settings = SettingsStore()
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
        _app = State(initialValue: AppModel(settings: settings))
        var gate = FirstRunGate(isConfigured: settings.isConfigured)
        #if DEBUG
        // QA hooks drive specific screens; never park them on the explainer.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--skip-first-run") || args.contains("--seed-demo")
            || args.contains("--open-settings") || args.contains("--open-create")
            || args.contains("--open-board") || args.contains("--open-profile") {
            gate.markSeen()
        }
        #endif
        _showFirstRun = State(initialValue: gate.shouldShow)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showFirstRun {
                    FirstRunView {
                        FirstRunGate(isConfigured: app.settings.isConfigured).markSeen()
                        showFirstRun = false
                    }
                } else {
                    RootTabView(app: app)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
