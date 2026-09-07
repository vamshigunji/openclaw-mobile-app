import Foundation

/// Canned board rows for demo mode (no gateway configured). Same decode path as the real
/// thing — the JSON below is the gateway's `sessions.list` / `tasks.list` shape.
enum DemoBoard {
    static let sessions: [SessionSummary] = decode(SessionListResponse.self, from: sessionsJSON)?.sessions ?? []
    static let tasks: [TaskSummary] = decode(TaskListResponse.self, from: tasksJSON)?.tasks ?? []

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static let now = Date().timeIntervalSince1970 * 1000

    private static var sessionsJSON: String {
        """
        {"sessions":[
          {"key":"agent:main:ship-attachments","sessionId":"d1","agentId":"main","kind":"agent",
           "label":"Ship the attachment picker","status":"running","hasActiveRun":true,
           "lastMessagePreview":"Re-encoding the image before upload…",
           "lastActivityAt":\(now - 60_000),"childSessions":["agent:main:ship-attachments:sub"],
           "worktree":{"id":"w1","branch":"feat/attachments","repoRoot":"/Users/dev/openclaw-mobile-app"},
           "model":"claude-opus-4-8","estimatedCostUsd":0.42},
          {"key":"agent:main:ship-attachments:sub","sessionId":"d2","agentId":"main","kind":"agent",
           "derivedTitle":"Resize helper","status":"running","spawnedBy":"agent:main:ship-attachments",
           "lastActivityAt":\(now - 30_000)},
          {"key":"agent:main:fix-settings","sessionId":"d3","agentId":"main","kind":"agent",
           "label":"Migrate the settings store","status":"failed","unread":true,
           "lastRunError":"no such column: device_token","lastActivityAt":\(now - 900_000),
           "worktree":{"id":"w2","branch":"fix/settings","repoRoot":"/Users/dev/openclaw-mobile-app"}},
          {"key":"agent:main:ci-image","sessionId":"d4","agentId":"main","kind":"agent",
           "label":"Bump the CI image","status":"done","lastActivityAt":\(now - 7_200_000),
           "spawnedCwd":"/Users/dev/openclaw-mobile-app"},
          {"key":"agent:writer:landing-copy","sessionId":"d5","agentId":"writer","kind":"agent",
           "label":"Landing page copy","status":"done","unread":true,"pinned":true,
           "lastMessagePreview":"Here are three headline options…",
           "category":"Website redesign","lastActivityAt":\(now - 1_800_000)},
          {"key":"agent:writer:pricing-page","sessionId":"d6","agentId":"writer","kind":"agent",
           "label":"Pricing page rewrite","status":"queued","category":"Website redesign",
           "lastActivityAt":\(now - 2_400_000)},
          {"key":"agent:researcher:transport-rfc","sessionId":"d7","agentId":"researcher","kind":"agent",
           "label":"Summarize the transport RFC"},
          {"key":"agent:researcher:competitors","sessionId":"d8","agentId":"researcher","kind":"agent",
           "label":"Competitor teardown","status":"done","lastActivityAt":\(now - 86_400_000),
           "execCwd":"/Users/dev/research"}
        ]}
        """
    }

    private static var tasksJSON: String {
        """
        {"tasks":[
          {"taskId":"dt1","runtime":"subagent","status":"running","title":"Resize helper",
           "agentId":"main","sessionKey":"agent:main:ship-attachments",
           "childSessionKey":"agent:main:ship-attachments:sub","lastToolName":"Edit",
           "progressSummary":"Rewriting ImageReencoder.jpeg",
           "diffStat":{"files":2,"added":41,"removed":8},"updatedAt":\(now - 30_000)},
          {"taskId":"dt2","runtime":"cli","status":"completed","title":"Run the test suite",
           "agentId":"main","sessionKey":"agent:main:ship-attachments",
           "terminalSummary":"130 tests, 0 failures","updatedAt":\(now - 300_000)},
          {"taskId":"dt3","runtime":"cron","status":"failed","title":"Nightly protocol probe",
           "agentId":"main","sessionKey":"agent:main:fix-settings",
           "error":"connect ECONNREFUSED","updatedAt":\(now - 900_000)},
          {"taskId":"dt4","runtime":"acp","status":"queued","title":"Draft the pricing table",
           "agentId":"writer","sessionKey":"agent:writer:pricing-page","updatedAt":\(now - 2_400_000)}
        ]}
        """
    }
}
