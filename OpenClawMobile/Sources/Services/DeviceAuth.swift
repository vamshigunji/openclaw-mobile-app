import CryptoKit
import Foundation

/// Ed25519 device identity for protocol-v4 device-auth pairing (.docs/protocol.md §5).
/// Key type is Ed25519 → lives in the Keychain, not the Secure Enclave (SE is P-256 only).
struct DeviceIdentity: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey

    /// Raw 32-byte Ed25519 public key.
    var rawPublicKey: Data { privateKey.publicKey.rawRepresentation }

    /// `deviceId = hex( sha256( raw ed25519 public-key bytes ) )` — LIVE-confirmed.
    var deviceId: String {
        SHA256.hash(data: rawPublicKey).map { String(format: "%02x", $0) }.joined()
    }

    init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    init() { privateKey = Curve25519.Signing.PrivateKey() }

    /// `base64url( ed25519.sign( utf8(payload) ) )`
    func sign(payload: String) throws -> String {
        try privateKey.signature(for: Data(payload.utf8)).base64urlEncodedString()
    }

    func verify(signatureB64url: String, payload: String) -> Bool {
        guard let sig = Data(base64urlEncoded: signatureB64url) else { return false }
        return privateKey.publicKey.isValidSignature(sig, for: Data(payload.utf8))
    }

    // MARK: - Keychain persistence

    private static let keychainKey = "device.ed25519.rawPrivateKey"

    /// Load the persisted identity or mint + persist a new one. The private key
    /// never leaves the device (.docs/protocol.md §3).
    static func loadOrCreate() -> DeviceIdentity {
        if let b64 = KeychainService.get(keychainKey),
           let raw = Data(base64Encoded: b64),
           let id = try? DeviceIdentity(rawPrivateKey: raw) {
            return id
        }
        let id = DeviceIdentity()
        KeychainService.set(id.privateKey.rawRepresentation.base64EncodedString(), for: keychainKey)
        return id
    }
}

/// The v3 device-auth signature payload — exact port of `buildDeviceAuthPayloadV3`
/// from the public openclaw npm package (pinned by `tools/phase0-verify.mjs` and
/// DeviceAuthTests golden vectors). PIPE-DELIMITED STRING, not JSON.
enum DeviceAuth {
    /// ASCII-only lowercase + trim; absent → "" (still a trailing field).
    static func normalizeMetadata(_ value: String?) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? UnicodeScalar(scalar.value + 32)! : scalar
        }))
    }

    /// `v3|deviceId|clientId|clientMode|role|scopes,csv|signedAtMs|token|nonce|platform|deviceFamily`
    static func payloadV3(deviceId: String, clientId: String, clientMode: String,
                          role: String, scopes: [String], signedAtMs: Int64,
                          token: String?, nonce: String,
                          platform: String?, deviceFamily: String?) -> String {
        [
            "v3", deviceId, clientId, clientMode, role,
            scopes.joined(separator: ","), String(signedAtMs), token ?? "", nonce,
            normalizeMetadata(platform), normalizeMetadata(deviceFamily),
        ].joined(separator: "|")
    }

    /// The signed `device{}` object for the connect frame (.docs/protocol.md §4).
    /// `signatureToken` = `auth.token ?? auth.bootstrapToken ?? ""`.
    static func deviceParams(identity: DeviceIdentity, nonce: String, role: String,
                             scopes: [String], signatureToken: String?,
                             signedAtMs: Int64,
                             clientId: String = "openclaw-ios", clientMode: String = "node",
                             platform: String = "ios", deviceFamily: String? = nil) throws -> [String: Any] {
        let payload = payloadV3(deviceId: identity.deviceId, clientId: clientId,
                                clientMode: clientMode, role: role, scopes: scopes,
                                signedAtMs: signedAtMs, token: signatureToken, nonce: nonce,
                                platform: platform, deviceFamily: deviceFamily)
        return [
            "id": identity.deviceId,
            "publicKey": identity.rawPublicKey.base64urlEncodedString(),
            "signature": try identity.sign(payload: payload),
            "signedAt": signedAtMs,
            "nonce": nonce,
        ]
    }
}

// MARK: - base64url (RFC 4648 §5, no padding)

extension Data {
    func base64urlEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64urlEncoded string: String) {
        var b64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        self.init(base64Encoded: b64)
    }
}
