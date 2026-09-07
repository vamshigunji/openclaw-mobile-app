import SwiftUI

/// Whether to show the first-run explanation, and the words on it. Pure so the decision
/// and the copy are both testable; the view is a thin shell over this.
struct FirstRunGate {
    private static let seenKey = "hasSeenFirstRun"

    static let title = "OpenClaw"
    static let continueTitle = "Set up my gateway"

    /// What a stranger needs before being asked for a setup code: what this talks to,
    /// whose machine it is, and what pairing actually does.
    static let explanation = [
        "This app is a phone client for the OpenClaw agents running on your own gateway — your Mac, your server, your network. There is no account here and nothing routes through us.",
        "Pairing creates a signing key that lives only on this phone. Your gateway approves that key once, and from then on this device can read and send messages as you.",
        "You will need your gateway running and a setup code from it. Approve the device there and you are done.",
    ]

    private let defaults: UserDefaults
    private let isConfigured: Bool

    init(defaults: UserDefaults = .standard, isConfigured: Bool) {
        self.defaults = defaults
        self.isConfigured = isConfigured
    }

    /// Fresh installs only. A configured host means someone already got through this.
    var shouldShow: Bool { !isConfigured && !defaults.bool(forKey: Self.seenKey) }

    func markSeen() { defaults.set(true, forKey: Self.seenKey) }
}

/// The first thing a new user sees. Explains, then hands off to pairing.
struct FirstRunView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Text("🦞").font(.system(size: 56))
            Text(FirstRunGate.title)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(FirstRunGate.explanation, id: \.self) { line in
                    Text(line)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            PrimaryButton(title: FirstRunGate.continueTitle, action: onContinue)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.bg)
    }
}
