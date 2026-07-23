import XCTest
@testable import OpenClawMobile

/// Agent profile read + edit-via-main. The profile READS directly (operator.read:
/// agents.list + agents.files.get for AGENTS.md, the behavior file — verified live
/// 2026-07-22). EDITS go through the main agent (operator.admin: agents.update /
/// agents.files.set), same as create. These test the pure pieces.
final class AgentProfileTests: XCTestCase {

    // MARK: - Which file holds the behavior

    func testPicksAgentsMdAsTheInstructionsFile() {
        let files = ["SOUL.md", "AGENTS.md", "TOOLS.md", "IDENTITY.md"]
        XCTAssertEqual(AgentProfile.instructionsFile(from: files), "AGENTS.md")
    }

    func testFallsBackToFirstMarkdownWhenNoAgentsMd() {
        XCTAssertEqual(AgentProfile.instructionsFile(from: ["README.txt", "SOUL.md", "x.md"]), "SOUL.md")
    }

    func testNilWhenNoMarkdown() {
        XCTAssertNil(AgentProfile.instructionsFile(from: ["a.txt", "b.json"]))
    }

    // MARK: - Edit instruction (sent to main)

    func testEditInstructionCarriesOnlyChangedFieldsPlusId() {
        let req = EditAgentRequest(
            agentId: "food-namer",
            name: "Food Namer", emoji: "🍜", model: "haiku",
            instructions: "Name dishes only.")
        let text = req.instruction
        XCTAssertTrue(text.contains("food-namer"))
        XCTAssertTrue(text.contains("agents.update"))
        XCTAssertTrue(text.contains("agents.files.set"))
        XCTAssertTrue(text.contains("Name dishes only."))
        XCTAssertTrue(text.uppercased().contains("UPDATED"))
    }

    // MARK: - Edit confirmation: did the identity change to what we asked?

    func agent(_ id: String, name: String? = nil, emoji: String? = nil, model: String? = nil) -> AgentSummary {
        AgentSummary(id: id, name: name, emoji: emoji, model: model)
    }

    func testDetectsIdentityUpdateApplied() {
        let want = EditAgentRequest(agentId: "food-namer", name: "Chef", emoji: "👨‍🍳", model: "opus")
        let after = [agent("main"), agent("food-namer", name: "Chef", emoji: "👨‍🍳", model: "opus")]
        XCTAssertTrue(AgentProfile.updateApplied(want: want, in: after))
    }

    func testUpdateNotYetAppliedWhenFieldsStale() {
        let want = EditAgentRequest(agentId: "food-namer", name: "Chef")
        let after = [agent("food-namer", name: "Food Namer")]  // still old name
        XCTAssertFalse(AgentProfile.updateApplied(want: want, in: after))
    }

    func testUpdateWithOnlyInstructionsChangeIsNotDetectableViaIdentity() {
        // Instructions-only edits don't change agents.list identity → can't confirm
        // via identity; caller must re-read the file instead. This asserts the
        // helper doesn't falsely report success.
        let want = EditAgentRequest(agentId: "food-namer", instructions: "new rules")
        let after = [agent("food-namer", name: "Food Namer")]
        XCTAssertFalse(AgentProfile.updateApplied(want: want, in: after))
    }
}
