import XCTest
@testable import OpenClawMobile

/// Run-completion notifications (loop P3). Fired ONLY from a real gateway terminal event —
/// never a timer, never a guess. See designs/2026-09-07-push-notifications-decision.md.
final class NotificationTests: XCTestCase {
    private func env(_ json: String) throws -> InboundEnvelope {
        try JSONDecoder().decode(InboundEnvelope.self, from: Data(json.utf8))
    }

    private func chatFrame(state: String) -> String {
        #"""
        {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:task",
         "agentId":"main","state":"\#(state)","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}}
        """#
    }

    // MARK: - What fires

    func testFiresOnEachTerminalState() throws {
        for state in ["final", "aborted", "error"] {
            let request = RunNotification.from(try env(chatFrame(state: state)), threadTitle: "Ship it")
            XCTAssertNotNil(request, "\(state) ends a run and is worth telling the user about")
            XCTAssertTrue(request?.body.contains("Ship it") == true, "name the thread that finished")
        }
    }

    func testDistinguishesSuccessFromFailure() throws {
        let ok = RunNotification.from(try env(chatFrame(state: "final")), threadTitle: "Ship it")
        let bad = RunNotification.from(try env(chatFrame(state: "error")), threadTitle: "Ship it")
        let stopped = RunNotification.from(try env(chatFrame(state: "aborted")), threadTitle: "Ship it")
        XCTAssertNotEqual(ok?.title, bad?.title, "a failure must not read like a success")
        XCTAssertNotEqual(ok?.title, stopped?.title)
    }

    func testCarriesTheSessionKeySoTappingOpensTheRightThread() throws {
        let request = RunNotification.from(try env(chatFrame(state: "final")), threadTitle: "Ship it")
        XCTAssertEqual(request?.sessionKey, "agent:main:task")
    }

    // MARK: - What must NOT fire

    func testNeverFiresOnADelta() throws {
        let delta = #"""
        {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:task",
         "agentId":"main","state":"delta","deltaText":"still working"}}
        """#
        XCTAssertNil(RunNotification.from(try env(delta), threadTitle: "Ship it"),
                     "a run in progress is not a finished run")
    }

    func testNeverFiresOnNonChatTraffic() throws {
        for json in [
            #"{"type":"event","event":"tick","payload":{"ts":1}}"#,
            #"{"type":"event","event":"presence","payload":{"agentId":"main"}}"#,
            #"{"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool","data":{"phase":"result","name":"Bash"},"agentId":"main"}}"#,
        ] {
            XCTAssertNil(RunNotification.from(try env(json), threadTitle: "Ship it"),
                         "liveness and tool traffic are not completions")
        }
    }

    // MARK: - Permission handling

    func testPermissionStateMachineNeverNags() {
        var permission = NotificationPermission()
        XCTAssertTrue(permission.shouldAsk, "not determined yet — ask once")
        permission.record(granted: false)
        XCTAssertFalse(permission.shouldAsk, "a denial is remembered, never re-asked")
        XCTAssertFalse(permission.canNotify)

        var granted = NotificationPermission()
        granted.record(granted: true)
        XCTAssertFalse(granted.shouldAsk)
        XCTAssertTrue(granted.canNotify)
    }
}
