import XCTest

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
