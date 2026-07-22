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
    /// Device-bound operator token minted by pairing (hello-ok `auth.deviceToken`).
    /// Wins over the shared `token` when present.
    var deviceToken: String {
        didSet { KeychainService.set(deviceToken, for: Keys.deviceToken) }
    }

    private enum Keys {
        static let host = "gateway.host"
        static let model = "gateway.model"
        static let token = "gateway.token"
        static let deviceToken = "gateway.deviceToken"
    }

    init() {
        self.host = UserDefaults.standard.string(forKey: Keys.host) ?? ""
        self.model = UserDefaults.standard.string(forKey: Keys.model) ?? "openclaw"
        self.token = KeychainService.get(Keys.token) ?? ""
        self.deviceToken = KeychainService.get(Keys.deviceToken) ?? ""
    }

    /// Auth for the WS connect: paired deviceToken → legacy shared token → none.
    var wsAuth: GatewayFrames.Auth {
        if !deviceToken.isEmpty { return .token(deviceToken) }
        if !token.isEmpty { return .token(token) }
        return .none
    }

    /// Paired = device token AND a host to use it against (a Keychain token can
    /// outlive an uninstall in the simulator; without a host it's inert).
    var isPaired: Bool { !deviceToken.isEmpty && isConfigured }

    /// True once a host is set. Empty host => demo mode (canned replies).
    var isConfigured: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
}
