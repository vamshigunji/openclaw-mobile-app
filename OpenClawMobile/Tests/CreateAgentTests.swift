import XCTest
@testable import OpenClawMobile

/// The "+" create-agent flow (approach B): the app can't call agents.create
/// (operator.admin), so it sends a STRUCTURED request to the main agent — which
/// holds admin — then polls agents.list for the newly-appeared agent. These test
/// the pure pieces: the instruction the app compiles, id normalization, and the
/// before/after delta detection that doesn't depend on guessing the new id.
final class CreateAgentTests: XCTestCase {
    func testNormalizedIdFromDisplayName() {
        XCTAssertEqual(CreateAgentRequest(name: "Indian Timer").normalizedId, "indian-timer")
        XCTAssertEqual(CreateAgentRequest(name: "  LinkedIn  Team!! ").normalizedId, "linkedin-team")
        XCTAssertEqual(CreateAgentRequest(name: "Résumé Bot 3000").normalizedId, "resume-bot-3000")
    }

    func testInstructionCarriesEveryFieldAndTheDoneConvention() {
        let req = CreateAgentRequest(
            name: "Indian Timer", emoji: "🇮🇳", model: "haiku",
            behavior: "only ever reply the current time in India")
        let text = req.instruction
        // The main agent needs the id, display name, emoji, model, behavior…
        XCTAssertTrue(text.contains("indian-timer"))
        XCTAssertTrue(text.contains("Indian Timer"))
        XCTAssertTrue(text.contains("🇮🇳"))
        XCTAssertTrue(text.contains("haiku"))
        XCTAssertTrue(text.contains("only ever reply the current time in India"))
        // …and a machine-checkable done signal so the app knows it finished.
        XCTAssertTrue(text.contains("agents.create"))
        XCTAssertTrue(text.uppercased().contains("CREATED"))
    }

    func testInstructionOmitsEmptyOptionalFields() {
        let req = CreateAgentRequest(name: "Bare", behavior: "do a thing")
        let text = req.instruction
        XCTAssertTrue(text.contains("bare"))
        XCTAssertFalse(text.contains("emoji:")) // no emoji line when none given
        XCTAssertFalse(text.contains("model:")) // no model line when none given
    }

    // MARK: - New-agent detection (robust: detect the DELTA, don't guess the id)

    func agent(_ id: String) -> AgentSummary { AgentSummary(id: id) }

    func testDetectsTheNewlyAppearedAgent() {
        let before: Set<String> = ["main"]
        let after = [agent("main"), agent("indian-timer")]
        let found = CreateAgentFlow.newAgent(before: before, after: after)
        XCTAssertEqual(found?.id, "indian-timer")
    }

    func testPrefersNormalizedIdMatchWhenMultipleAppear() {
        // If two agents appear at once, prefer the one matching what we asked for.
        let before: Set<String> = ["main"]
        let after = [agent("main"), agent("scratch"), agent("indian-timer")]
        let found = CreateAgentFlow.newAgent(before: before, after: after,
                                             preferId: "indian-timer")
        XCTAssertEqual(found?.id, "indian-timer")
    }

    func testNoNewAgentYieldsNil() {
        let before: Set<String> = ["main", "indian-timer"]
        let after = [agent("main"), agent("indian-timer")]
        XCTAssertNil(CreateAgentFlow.newAgent(before: before, after: after))
    }
}
