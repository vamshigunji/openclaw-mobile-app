import SwiftUI

/// Mutable box so the `@Sendable` onDeviceToken callback can hand the minted
/// token back to the pairing loop.
private final class TokenBox: @unchecked Sendable {
    var value: String?
}

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testing = false
    @State private var setupCode = ""
    @State private var pairStatus: String?
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Gateway Host", "http://100.x.x.x:18789", text: $settings.host)
                    field("Gateway Token", "Bearer token", text: $settings.token, secure: true)
                    field("Model", "openclaw", text: $settings.model)

                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            if testing { ProgressView().tint(Theme.bgPrimary) }
                            Text(testing ? "Testing…" : "Test Connection")
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent)
                        .foregroundStyle(Theme.bgPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .disabled(testing)

                    if let testResult {
                        Text(testResult)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Device pairing (.docs/protocol.md §3): setup code → signed
                    // bootstrap connect → operator approves → deviceToken persisted.
                    Text("DEVICE PAIRING")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8)
                    if settings.isPaired {
                        Text("✓ Paired — device-bound token in Keychain")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                    field("Setup Code", "paste setup code", text: $setupCode)
                    Button {
                        Task { await pair() }
                    } label: {
                        HStack {
                            if pairing { ProgressView().tint(Theme.bgPrimary) }
                            Text(pairing ? "Pairing… approve on gateway" : "Pair Device")
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent)
                        .foregroundStyle(Theme.bgPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .disabled(pairing || setupCode.trimmingCharacters(in: .whitespaces).isEmpty || settings.host.isEmpty)

                    if let pairStatus {
                        Text(pairStatus)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
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
    }

    private func field(_ label: String, _ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .padding(10)
            .background(Theme.bgSecondary)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
        }
    }

    /// Signed bootstrap connect, retrying while the operator approves the device
    /// (`PAIRING_REQUIRED / wait_then_retry`). ~2 minutes of 3s retries.
    private func pair() async {
        pairing = true
        pairStatus = "Connecting…"
        defer { pairing = false }
        let code = setupCode.trimmingCharacters(in: .whitespaces)
        let minted = TokenBox()
        let source = GatewayWSSyncSource(
            host: settings.host, auth: .bootstrap(code),
            identity: DeviceIdentity.loadOrCreate(),
            onDeviceToken: { minted.value = $0 })
        for attempt in 1...40 {
            do {
                try await source.connectOnce()
                if let token = minted.value, !token.isEmpty {
                    settings.deviceToken = token
                    pairStatus = "✓ Paired. Device token stored in Keychain."
                } else {
                    // hello-ok without a fresh mint — already-approved device.
                    pairStatus = "✓ Connected — device already paired."
                }
                return
            } catch GatewayError.pairingPending {
                pairStatus = "Waiting for approval on gateway… (attempt \(attempt))"
                try? await Task.sleep(for: .seconds(3))
            } catch {
                pairStatus = "✗ \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                return
            }
        }
        pairStatus = "✗ Timed out waiting for approval. Re-run pairing."
    }

    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        guard settings.isConfigured,
              let url = URL(string: settings.host)?.appendingPathComponent("health") else {
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
}
