import XCTest
@testable import OpenClawMobile

extension XCTestCase {
    /// Polls `condition` on the main actor until it holds or `timeout` elapses.
    @MainActor
    func waitUntil(_ timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

extension XCTestCase {
    /// A ChatViewModel on the agent's main thread over a real GatewayWSSyncSource against `gateway`.
    /// Sets `settings.host` so the WS send path is taken; callers reset it in a defer.
    @MainActor
    func makeChatViewModel(gateway: MockGateway, agentId: String = "main") -> (ChatViewModel, SettingsStore) {
        let sync = GatewayWSSyncSource(host: gateway.wsHost, auth: .token("mock-device-token-1"),
                                       identity: DeviceIdentity())
        let settings = SettingsStore()
        settings.host = gateway.wsHost
        let vm = ChatViewModel(thread: .main(for: AgentSummary(id: agentId, name: agentId)),
                               sync: sync, settings: settings)
        vm.start()
        return (vm, settings)
    }
}
