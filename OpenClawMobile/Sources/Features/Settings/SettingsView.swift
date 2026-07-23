import SwiftUI

/// Settings — pairing-first hierarchy (design review 2026-07-21, decision 1A):
/// unpaired → pairing hero on top, manual fields under "Advanced";
/// paired → compact status row first. Visual spec:
/// `designs/assets/2026-07-21-pairing-states.png`.
struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var flow = PairingFlow()
    @State private var setupCode = ""
    @State private var showScanner = false
    @State private var showAdvanced = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if settings.isPaired, case .idle = flow.step {
                        pairedStatusRow
                        advancedSection(expanded: true)
                    } else {
                        pairingSection
                        advancedSection(expanded: showAdvanced)
                    }
                    Spacer()
                }
                .padding(16)
            }
            .background(Theme.bgPrimary.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showScanner) { scannerSheet }
        .onChange(of: flow.step) { _, step in announce(step) } // a11y (3A)
    }

    // MARK: - Pairing hero (states per approved mockup)

    @ViewBuilder
    private var pairingSection: some View {
        Text("Pair this device")
            .font(.system(.headline, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)

        switch flow.step {
        case .idle, .scanning:
            infoCard(
                title: nil,
                body: "Pairing lets this phone talk to your gateway with its own key. On your gateway, run `openclaw qr`, then scan it here.")
            PrimaryButton(title: "▣  Scan Setup Code") { showScanner = true }
            Text("— or —")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
            MonoField(label: "Paste Setup Code", placeholder: "eyJ1cmwiOiJ3c3M6…", text: $setupCode)
            PrimaryButton(title: "Pair Device", secondary: true, disabled: SetupCode.parse(setupCode) == nil) {
                startPairing(with: setupCode)
            }

        case .connecting:
            pairBadge("CONNECTING", color: Theme.accent, spinning: true)
            ladder(step1: .active, step2: .pending, step3: .pending)
            PrimaryButton(title: "Cancel", secondary: true) { flow.cancel() }

        case .waitingApproval(let attempt):
            pairBadge("WAITING ON GATEWAY", color: AgentStatus.waiting.color)
            ladder(step1: .done, step2: .active, step3: .pending)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your gateway needs to approve this device once.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Text("Ask your OpenClaw (or run on the gateway box):")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                codeBlock("openclaw devices approve \(flow.lastRequestId ?? "--latest")")
                Text("Retrying automatically — \(countdown(attempt)) remaining")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(12)
            .background(Theme.bgSecondary)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
            PrimaryButton(title: "Cancel", secondary: true) { flow.cancel() }

        case .paired(let minted):
            pairBadge("PAIRED", color: Theme.accent)
            ladder(step1: .done, step2: .done, step3: .done)
            infoCard(
                title: "This phone now has its own device key.",
                body: minted
                    ? "You can revoke it anytime on the gateway with `openclaw devices`."
                    : "Device was already approved — connected with the existing key.")
            PrimaryButton(title: "Start Chatting →") { flow.reset(); dismiss() }

        case .failed(let reason):
            failedView(reason)
        }
    }

    @ViewBuilder
    private func failedView(_ reason: PairingFlow.FailureReason) -> some View {
        switch reason {
        case .expiredCode:
            pairBadge("CODE EXPIRED", color: AgentStatus.failed.color)
            infoCard(title: "Setup codes only live a few minutes.",
                     body: "Generate a fresh one on your gateway with `openclaw qr`, then scan it — takes under 10 seconds.")
            PrimaryButton(title: "▣  Scan New Code") { flow.reset(); showScanner = true }
        case .timeout:
            pairBadge("APPROVAL TIMED OUT", color: AgentStatus.failed.color)
            infoCard(title: "The approval didn't arrive in time.",
                     body: "Approve on the gateway, then retry:")
            codeBlock("openclaw devices approve \(flow.lastRequestId ?? "--latest")")
            PrimaryButton(title: "Retry") { startPairing(with: setupCode) }
        case .cameraDenied:
            pairBadge("CAMERA UNAVAILABLE", color: AgentStatus.waiting.color)
            infoCard(title: "No camera access.",
                     body: "Paste the setup code below instead — same result. (Enable camera access in iOS Settings to scan.)")
            MonoField(label: "Paste Setup Code", placeholder: "eyJ1cmwiOiJ3c3M6…", text: $setupCode)
            PrimaryButton(title: "Pair Device", secondary: true, disabled: SetupCode.parse(setupCode) == nil) {
                startPairing(with: setupCode)
            }
        case .other(let message):
            pairBadge("PAIRING FAILED", color: AgentStatus.failed.color)
            infoCard(title: "Something went wrong.", body: message)
            PrimaryButton(title: "Retry") { startPairing(with: setupCode) }
        }
    }

    private var pairedStatusRow: some View {
        HStack(spacing: 8) {
            pairBadge("PAIRED", color: Theme.accent)
            Text("device key in Keychain")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Re-pair") { settings.deviceToken = ""; flow.reset() }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Paired. Device key stored in Keychain.")
    }

    // MARK: - Advanced (manual host/token/model — the fallback, not the front door)

    @ViewBuilder
    private func advancedSection(expanded: Bool) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded || showAdvanced },
            set: { showAdvanced = $0 })) {
            VStack(alignment: .leading, spacing: 14) {
                MonoField(label: "Gateway Host", placeholder: "https://…trycloudflare.com", text: $settings.host)
                MonoField(label: "Gateway Token", placeholder: "Bearer token", secure: true, text: $settings.token)
                MonoField(label: "Model", placeholder: "openclaw", text: $settings.model)
                PrimaryButton(title: testing ? "Testing…" : "Test Connection", secondary: true, disabled: testing) {
                    Task { await test() }
                }
                if let testResult {
                    Text(testResult)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("ADVANCED — HOST, TOKEN, MODEL")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .tint(Theme.textSecondary)
    }

    // MARK: - Actions

    private func startPairing(with raw: String) {
        guard let code = SetupCode.parse(raw) else { return }
        if let url = code.url { settings.host = url } // QR carries the host
        let runner = PairingFlow.gatewayRunner(host: settings.host, code: code)
        Task {
            await flow.pair(runOnce: runner) { settings.deviceToken = $0 }
        }
    }

    private var scannerSheet: some View {
        ZStack(alignment: .bottom) {
            QRScannerView(
                onCode: { raw in
                    showScanner = false
                    setupCode = raw
                    startPairing(with: raw)
                },
                onUnavailable: {
                    showScanner = false
                    flow.cameraDenied()
                })
            VStack(spacing: 8) {
                Text("Point at the QR from `openclaw qr`. Host and code fill in automatically.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Enter code manually instead") { showScanner = false }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            .padding(16)
            .background(Theme.bgPrimary.opacity(0.9))
        }
        .ignoresSafeArea()
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        // Host may be stored as wss:// (from a QR) — health is plain HTTPS.
        let httpHost = settings.host
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
        guard settings.isConfigured,
              let url = URL(string: httpHost)?.appendingPathComponent("health") else {
            testResult = "No host set — app runs in demo mode."
            return
        }
        var req = URLRequest(url: url)
        if !settings.token.isEmpty {
            req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            testResult = (200...299).contains(code) ? "✓ Connected (HTTP \(code))" : "Reached host, HTTP \(code)"
        } catch {
            testResult = "✗ \(error.localizedDescription)"
        }
    }

    // MARK: - Components (Theme tokens only — no inline values)

    private enum LadderState { case done, active, pending, failed }

    private func ladder(step1: LadderState, step2: LadderState, step3: LadderState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ladderRow("Code accepted — signature verified", step1)
            ladderRow("Waiting for approval on your gateway", step2)
            ladderRow("Paired — key stored in Keychain", step3)
        }
        .accessibilityElement(children: .combine)
    }

    private func ladderRow(_ label: String, _ state: LadderState) -> some View {
        let color: Color = switch state {
        case .done: Theme.accent
        case .active: AgentStatus.waiting.color
        case .pending: Theme.borderColor
        case .failed: AgentStatus.failed.color
        }
        return HStack(spacing: 8) {
            Circle()
                .fill(state == .pending ? Color.clear : color)
                .overlay(Circle().stroke(color, lineWidth: Theme.border))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(state == .pending ? Theme.textSecondary : color)
        }
        .accessibilityLabel("\(label): \(state == .done ? "done" : state == .active ? "in progress" : "pending")")
    }

    private func pairBadge(_ label: String, color: Color, spinning: Bool = false) -> some View {
        HStack(spacing: 5) {
            if spinning {
                ProgressView().controlSize(.mini).tint(color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(color.opacity(0.4), lineWidth: Theme.border))
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Theme.accent)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgPrimary)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
            .textSelection(.enabled)
    }

    private func infoCard(title: String?, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(.init(body)) // markdown backticks render mono-accent
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSecondary)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
    }




    private func countdown(_ attempt: Int) -> String {
        let secs = flow.remainingSeconds(afterAttempt: attempt)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    /// VoiceOver announcements on state transitions (design review 3A).
    private func announce(_ step: PairingFlow.Step) {
        let message: String? = switch step {
        case .connecting: "Connecting to gateway"
        case .waitingApproval: "Waiting for approval on your gateway"
        case .paired: "Paired. This phone now has its own device key."
        case .failed(.expiredCode): "Setup code expired. Scan a new code."
        case .failed(.timeout): "Approval timed out."
        case .failed(.cameraDenied): "Camera unavailable. Paste the setup code instead."
        case .failed(.other(let m)): "Pairing failed. \(m)"
        default: nil
        }
        if let message { UIAccessibility.post(notification: .announcement, argument: message) }
    }
}
