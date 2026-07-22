import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var testing = false

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
