import XCTest
@testable import OpenClawMobile

/// Golden vectors generated from the LIVE-verified Node reference
/// (`tools/phase0-verify.mjs`, sourced from the public openclaw npm package).
/// Ed25519 is deterministic, so the signature must match byte-for-byte.
final class DeviceAuthTests: XCTestCase {
    // The probe's persisted identity (tools/.phase0-device.json)
    static let privSeedB64 = "8a2US+qPACgKJ7/b9gqlJgDvBLiGmUeGATp1kEyhDZ4="
    static let rawPubB64 = "po6xpVSG8Ia6Kk0NWqQZv8uPmzIs0Jgs5PU9QKae8uA="
    static let goldenDeviceId = "328fad625bd4b937b4d67f9f2ba8720fa5578f5eac217bf196b99eaa614a8599"
    static let goldenPayload = "v3|328fad625bd4b937b4d67f9f2ba8720fa5578f5eac217bf196b99eaa614a8599|openclaw-ios|node|operator|operator.read,operator.write|1753000000000|bootstrap-abc|nonce-123|ios|"
    static let goldenSigB64url = "Wp35bpgflvdVXJfnewYseozF18R7-rwHsCqygA9ul6Y39v79-bk7-c9VamjVvTzlh268b2eqqgB3FuNzP7CkAA"

    func identity() throws -> DeviceIdentity {
        let seed = Data(base64Encoded: Self.privSeedB64)!
        return try DeviceIdentity(rawPrivateKey: seed)
    }

    func testDeviceIdIsSha256HexOfRawPublicKey() throws {
        let id = try identity()
        XCTAssertEqual(id.rawPublicKey.base64EncodedString(), Self.rawPubB64)
        XCTAssertEqual(id.deviceId, Self.goldenDeviceId)
    }

    func testV3PayloadMatchesReferenceSerialization() throws {
        let payload = DeviceAuth.payloadV3(
            deviceId: Self.goldenDeviceId,
            clientId: "openclaw-ios", clientMode: "node", role: "operator",
            scopes: ["operator.read", "operator.write"],
            signedAtMs: 1753000000000,
            token: "bootstrap-abc", nonce: "nonce-123",
            platform: "iOS", deviceFamily: nil)
        XCTAssertEqual(payload, Self.goldenPayload)
    }

    /// CryptoKit Ed25519 signatures are randomized (not RFC-8032 deterministic),
    /// so we assert mutual verifiability instead of byte equality:
    /// 1. Swift's signature verifies over the exact golden payload bytes.
    /// 2. Node's golden signature verifies under the Swift-derived public key.
    func testSignatureInteropWithNodeReference() throws {
        let id = try identity()
        let sigB64url = try id.sign(payload: Self.goldenPayload)
        XCTAssertTrue(id.verify(signatureB64url: sigB64url, payload: Self.goldenPayload))
        XCTAssertTrue(id.verify(signatureB64url: Self.goldenSigB64url, payload: Self.goldenPayload))
        // and a tampered payload must NOT verify
        XCTAssertFalse(id.verify(signatureB64url: Self.goldenSigB64url, payload: Self.goldenPayload + "x"))
    }

    func testDeviceParamsShape() throws {
        let id = try identity()
        let device = try DeviceAuth.deviceParams(
            identity: id, nonce: "nonce-123", role: "operator",
            scopes: ["operator.read", "operator.write"],
            signatureToken: "bootstrap-abc", signedAtMs: 1753000000000)
        XCTAssertEqual(device["id"] as? String, Self.goldenDeviceId)
        XCTAssertEqual(device["publicKey"] as? String, "po6xpVSG8Ia6Kk0NWqQZv8uPmzIs0Jgs5PU9QKae8uA")
        // randomized Ed25519 → assert the signature verifies over the golden payload
        let sig = try XCTUnwrap(device["signature"] as? String)
        XCTAssertTrue(id.verify(signatureB64url: sig, payload: Self.goldenPayload))
        XCTAssertEqual(device["signedAt"] as? Int64, 1753000000000)
        XCTAssertEqual(device["nonce"] as? String, "nonce-123")
    }

    func testMetadataNormalizationIsAsciiOnlyLowercase() {
        XCTAssertEqual(DeviceAuth.normalizeMetadata(" iOS "), "ios")
        XCTAssertEqual(DeviceAuth.normalizeMetadata(nil), "")
        XCTAssertEqual(DeviceAuth.normalizeMetadata("  "), "")
        // ASCII-only: non-ASCII uppercase must pass through untouched
        XCTAssertEqual(DeviceAuth.normalizeMetadata("ÄBc"), "Äbc")
    }
}
