import SwiftData
import XCTest

@testable import VoiceInk

final class AutoLearnReplacementSafetyTests: XCTestCase {
    func testCmuxReaderExtractsWrappedComposerText() {
        let screen = """
            previous output
              ╭────────────────────────────────────────╮
              │ ❯ 最近做出來的成果就是取代 Typeless、 │
              │ 取代 Heptabase，把 PDF 轉入 Kobo。    │
              ╰────────────────────────────────────────╯
            footer
            """

        XCTAssertEqual(
            AutoLearnCmuxTextReader.extractComposerText(from: screen),
            "最近做出來的成果就是取代 Typeless、取代 Heptabase，把 PDF 轉入 Kobo。"
        )
    }

    func testCmuxReaderRejectsUnrelatedComposerText() {
        XCTAssertFalse(
            AutoLearnCmuxTextReader.isPlausibleCorrection(
                original: "我要記下紫杉弧線和白榆曲線",
                candidate: "這是一段完全不相關的新訊息"
            )
        )
    }

    func testCmuxReaderAcceptsLocalCorrection() {
        XCTAssertTrue(
            AutoLearnCmuxTextReader.isPlausibleCorrection(
                original: "最近做出來的成果就是把筆記數轉入 Obsidian。",
                candidate: "最近做出來的成果就是把 PDF 轉入 Kobo。"
            )
        )
    }

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
    func testAutoLearnPromotesRepeatedDestinationToVocabulary() async throws {
        let container = try makeContainer()
        let store = WordReplacementStore(modelContainer: container)

        let firstCandidateID = UUID()
        let firstSummary = try await store.apply(
            [
                AutoLearnReviewDecision(
                    candidateID: firstCandidateID,
                    learningAction: .addReplacementOnly,
                    incorrectTextToReplace: "斥陽",
                    correctedVocabularyTerm: "赤楊"
                )
            ],
            candidates: [
                AutoLearnReviewCandidate(
                    candidateID: firstCandidateID,
                    originalText: "斥陽曲線",
                    correctedText: "赤楊曲線"
                )
            ]
        )
        XCTAssertEqual(firstSummary.createdCount, 1)
        XCTAssertEqual(firstSummary.vocabularyCount, 0)

        let secondCandidateID = UUID()
        let secondSummary = try await store.apply(
            [
                AutoLearnReviewDecision(
                    candidateID: secondCandidateID,
                    learningAction: .addReplacementOnly,
                    incorrectTextToReplace: "次揚",
                    correctedVocabularyTerm: "赤楊"
                )
            ],
            candidates: [
                AutoLearnReviewCandidate(
                    candidateID: secondCandidateID,
                    originalText: "次揚曲線",
                    correctedText: "赤楊曲線"
                )
            ]
        )

        XCTAssertEqual(secondSummary.updatedCount, 1)
        XCTAssertEqual(secondSummary.vocabularyCount, 1)
        let context = ModelContext(container)
        let replacements = try context.fetch(FetchDescriptor<WordReplacement>())
        XCTAssertEqual(replacements.count, 1)
        XCTAssertEqual(replacements.first?.originalText, "斥陽, 次揚")
        XCTAssertEqual(replacements.first?.replacementText, "赤楊")
        let vocabulary = try context.fetch(FetchDescriptor<VocabularyWord>())
        XCTAssertEqual(vocabulary.map(\.word), ["赤楊"])
    }

    @MainActor
    func testAutoLearnPromotesExistingRepeatedDestinationOnStartup() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(
            WordReplacement(
                originalText: "斥陽, 次揚",
                replacementText: "赤楊"
            )
        )
        try context.save()

        let store = WordReplacementStore(modelContainer: container)
        let createdCount = try await store.promoteRepeatedReplacementDestinationsToVocabulary()

        XCTAssertEqual(createdCount, 1)
        let vocabulary = try context.fetch(FetchDescriptor<VocabularyWord>())
        XCTAssertEqual(vocabulary.map(\.word), ["赤楊"])
        let secondCreatedCount = try await store.promoteRepeatedReplacementDestinationsToVocabulary()
        XCTAssertEqual(secondCreatedCount, 0)
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
