import SwiftData
import XCTest

@testable import VoiceInk

final class AutoLearnReplacementSafetyTests: XCTestCase {
    @MainActor
    func testAutoLearnDoesNotStoreSingleCompactScriptCharacterReplacement() async throws {
        let container = try makeContainer()
        let store = WordReplacementStore(modelContainer: container)
        let candidateID = UUID()

        let summary = try await store.apply(
            [
                AutoLearnReviewDecision(
                    candidateID: candidateID,
                    learningAction: .addReplacementOnly,
                    incorrectTextToReplace: "鴻",
                    correctedVocabularyTerm: "紘"
                )
            ],
            candidates: [
                AutoLearnReviewCandidate(
                    candidateID: candidateID,
                    originalText: "和邱鴻瑋",
                    correctedText: "和邱紘瑋"
                )
            ]
        )

        XCTAssertFalse(summary.hasChanges)
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WordReplacement>()).isEmpty)
    }

    @MainActor
    func testAutoLearnStoresCompletePersonalNameReplacement() async throws {
        let container = try makeContainer()
        let store = WordReplacementStore(modelContainer: container)
        let candidateID = UUID()

        let summary = try await store.apply(
            [
                AutoLearnReviewDecision(
                    candidateID: candidateID,
                    learningAction: .addReplacementAndVocabulary,
                    incorrectTextToReplace: "邱鴻瑋",
                    correctedVocabularyTerm: "邱紘瑋"
                )
            ],
            candidates: [
                AutoLearnReviewCandidate(
                    candidateID: candidateID,
                    originalText: "和邱鴻瑋",
                    correctedText: "和邱紘瑋"
                )
            ]
        )

        XCTAssertEqual(summary.createdCount, 1)
        XCTAssertEqual(summary.vocabularyCount, 1)
        let context = ModelContext(container)
        let replacements = try context.fetch(FetchDescriptor<WordReplacement>())
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements.first?.originalText, "邱鴻瑋")
        XCTAssertEqual(replacements.first?.replacementText, "邱紘瑋")
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: WordReplacement.self,
            VocabularyWord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
