import Foundation
import Observation

/// Mutable box so a `@Sendable` callback can hand the minted token back.
final class TokenBox: @unchecked Sendable {
    var value: String?
}

/// A parsed setup code. `openclaw qr` emits a base64url JSON blob
/// `{url, bootstrapToken}` (LIVE-verified 2026-07-21); users may also paste the
/// bare inner token. One parser for QR + paste (DRY, eng review 3A).
struct SetupCode: Equatable {
    var url: String?
    var bootstrapToken: String

    static func parse(_ raw: String) -> SetupCode? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // base64url alphabet only (both the blob and bare tokens use it)
        guard trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return nil
        }
        // Try the full blob first: base64url(JSON {url, bootstrapToken})
        if let data = Data(base64urlEncoded: trimmed),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let token = obj["bootstrapToken"] as? String, !token.isEmpty else {
                return nil // valid JSON blob but no token — reject, don't misread as bare token
            }
            return SetupCode(url: obj["url"] as? String, bootstrapToken: token)
        }
        // Bare inner token (tokens are ~40+ chars; reject short garbage)
        guard trimmed.count >= 20 else { return nil }
        return SetupCode(url: nil, bootstrapToken: trimmed)
    }
}

/// Pairing state machine — drives the 6-state UI (design review 2026-07-21,
/// approved mockup). Transport is an injected closure so every transition is
/// unit-testable; the view renders `step` and never touches the network.
@MainActor
@Observable
final class PairingFlow {
    enum Step: Equatable {
        case idle
        case scanning
        case connecting
        case waitingApproval(attempt: Int)
        case paired(minted: Bool)
        case failed(FailureReason)
    }

    enum FailureReason: Equatable {
        case expiredCode
        /// The URL does not resolve — a typo, or a tunnel that no longer exists.
        case badHost
        /// The URL is fine but nothing answered — gateway down, or the tunnel is closed.
        case unreachable
        case timeout
        case cameraDenied
        case other(String)

        /// What went wrong, in four words.
        var headline: String {
            switch self {
            case .expiredCode:  "Code expired"
            case .badHost:      "Can't find that gateway"
            case .unreachable:  "Gateway didn't answer"
            case .timeout:      "Approval timed out"
            case .cameraDenied: "Camera unavailable"
            case .other:        "Pairing failed"
            }
        }

        /// What to do about it. Never an error code — the user cannot act on one.
        var recovery: String {
            switch self {
            case .expiredCode:
                "Setup codes last a few minutes. Generate a fresh one on your gateway with `openclaw qr` and scan it again."
            case .badHost:
                "Check the address in the setup code. A Quick Tunnel URL changes every time the tunnel restarts, so an old code points nowhere."
            case .unreachable:
                "The address looks right but nothing answered. Make sure the gateway is running and its tunnel is up, then try again."
            case .timeout:
                "Nobody approved this device in time. Approve it on the gateway, then retry."
            case .cameraDenied:
                "Paste the setup code instead — same result. To scan, open iOS Settings and allow camera access."
            case .other(let message):
                "Something unexpected went wrong. Check the gateway is running, then try again. Details: \(message)"
            }
        }

        /// Map a thrown error onto the reason whose recovery text actually helps.
        static func from(_ error: Error) -> FailureReason {
            if let gateway = error as? GatewayError {
                switch gateway {
                case .bootstrapExpired: return .expiredCode
                case .unreachable(let detail):
                    return detail.localizedCaseInsensitiveContains("bad host") ? .badHost : .unreachable
                default: break
                }
            }
            if let url = error as? URLError {
                switch url.code {
                case .cannotFindHost, .unsupportedURL, .badURL: return .badHost
                case .cannotConnectToHost, .timedOut, .networkConnectionLost,
                     .notConnectedToInternet, .secureConnectionFailed: return .unreachable
                default: break
                }
            }
            return .other((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    enum RunResult: Equatable {
        case minted(String)  // hello-ok minted a deviceToken
        case connected       // hello-ok without a mint (already-approved device)
    }

    enum Outcome: Equatable { case paired, timedOut, failed, cancelled }

    private(set) var step: Step = .idle
    /// requestId from the latest PAIRING_REQUIRED — the UI shows the exact
    /// `openclaw devices approve <id>` command (approved mockup, state 3).
    private(set) var lastRequestId: String?

    let maxAttempts: Int
    let retryDelay: Duration
    private var isCancelled = false

    init(maxAttempts: Int = 40, retryDelay: Duration = .seconds(3)) {
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
    }

    /// Seconds remaining in the approval window (for the countdown label).
    func remainingSeconds(afterAttempt attempt: Int) -> Int {
        max(0, (maxAttempts - attempt) * Int(retryDelay.components.seconds))
    }

    func beginScanning() { step = .scanning }
    func reset() { step = .idle; isCancelled = false; lastRequestId = nil }
    func cameraDenied() { step = .failed(.cameraDenied) }

    func cancel() {
        isCancelled = true
        step = .idle
    }

    /// Run the signed bootstrap connect, retrying through PAIRING_REQUIRED
    /// until approval, terminal failure, timeout, or cancel.
    @discardableResult
    func pair(runOnce: () async throws -> RunResult,
              storeToken: (String) -> Void) async -> Outcome {
        isCancelled = false
        step = .connecting
        for attempt in 1...maxAttempts {
            if isCancelled { return .cancelled }
            do {
                switch try await runOnce() {
                case .minted(let token):
                    storeToken(token)
                    step = .paired(minted: true)
                case .connected:
                    step = .paired(minted: false)
                }
                return .paired
            } catch GatewayError.pairingPending(let requestId) {
                if let requestId { lastRequestId = requestId }
                if isCancelled { return .cancelled }
                step = .waitingApproval(attempt: attempt)
                try? await Task.sleep(for: retryDelay)
            } catch GatewayError.bootstrapExpired {
                step = .failed(.expiredCode)
                return .failed
            } catch {
                // Route through the mapper so a dead tunnel reads as "gateway didn't answer",
                // not as a raw URLError the user cannot act on.
                step = .failed(.from(error))
                return .failed
            }
        }
        step = .failed(.timeout)
        return .timedOut
    }

    /// Production runner: one signed bootstrap connect against the gateway.
    /// The setup-code blob carries the host; fall back to the stored one.
    static func gatewayRunner(host: String, code: SetupCode) -> () async throws -> RunResult {
        let resolvedHost = code.url ?? host
        return {
            let minted = TokenBox()
            let source = GatewayWSSyncSource(
                host: resolvedHost, auth: .bootstrap(code.bootstrapToken),
                identity: DeviceIdentity.loadOrCreate(),
                onDeviceToken: { minted.value = $0 })
            try await source.connectOnce()
            if let token = minted.value, !token.isEmpty { return .minted(token) }
            return .connected
        }
    }
}
