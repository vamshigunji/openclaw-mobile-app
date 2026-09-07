import Observation
import SwiftUI

/// App-wide state: settings + the ONE shared multi-agent connection. Every agent
/// thread and the roster share this single `SyncSource` so there's one socket for
/// the whole app (T6 connection actor underneath). Rebuilt when the host/pairing
/// changes so a fresh pairing takes effect without an app restart.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    private(set) var sync: SyncSource

    init(settings: SettingsStore) {
        self.settings = settings
        self.sync = Self.makeSync(settings)
    }

    /// Foreground refresh: the shared connection reconnects on demand, and each screen's
    /// own connection-state subscription re-reads once it is back up.
    func refreshOnForeground() {
        guard settings.isConfigured else { return }
        Task { _ = try? await sync.listAgents() }   // cheapest call that revives the socket
    }

    /// Call after pairing / host change to point every agent at the new gateway.
    func rebuildConnection() {
        sync = Self.makeSync(settings)
    }

    private static func makeSync(_ settings: SettingsStore) -> SyncSource {
        settings.isConfigured
            ? GatewayWSSyncSource(host: settings.host, auth: settings.wsAuth,
                                  identity: DeviceIdentity.loadOrCreate())
            : DemoSyncSource()
    }
}
