import Foundation
import Observation

/// Holds Gateway connection config. Host in UserDefaults, token in Keychain (PRD §3.1).
@MainActor
@Observable
final class SettingsStore {
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Keys.host) }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }
    var token: String {
        didSet { KeychainService.set(token, for: Keys.token) }
    }

    private enum Keys {
        static let host = "gateway.host"
        static let model = "gateway.model"
        static let token = "gateway.token"
    }

    init() {
        self.host = UserDefaults.standard.string(forKey: Keys.host) ?? ""
        self.model = UserDefaults.standard.string(forKey: Keys.model) ?? "openclaw"
        self.token = KeychainService.get(Keys.token) ?? ""
    }

    /// True once a host is set. Empty host => demo mode (canned replies).
    var isConfigured: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
}
