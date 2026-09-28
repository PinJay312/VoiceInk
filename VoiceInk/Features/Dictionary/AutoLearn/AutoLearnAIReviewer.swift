import Foundation
import OSLog

@MainActor
final class AutoLearnAIReviewer: @unchecked Sendable {
    private struct AutoLearnReviewRequest: Encodable {
        struct CandidateForReview: Encodable {
            let candidateID: Int
            let originalText: String
            let correctedText: String
        }

        let candidatesForReview: [CandidateForReview]
    }

    private struct CandidateReviewDecision: Decodable {
        let candidateID: Int
        let learningAction: AutoLearnReviewAction
        let incorrectTextToReplace: String?
        let correctedVocabularyTerm: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case candidateID
            case learningAction
            case incorrectTextToReplace
            case correctedVocabularyTerm
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let returnedKeys = Set(container.allKeys.map(\.stringValue))
            let expectedKeys = Set(CodingKeys.allCases.map(\.stringValue))
            guard returnedKeys == expectedKeys else {
                throw DecodingError.dataCorruptedError(
                    forKey: .candidateID,
                    in: container,
                    debugDescription: "Each decision must contain exactly the four required fields."
                )
            }

            candidateID = try container.decode(Int.self, forKey: .candidateID)
            learningAction = try container.decode(AutoLearnReviewAction.self, forKey: .learningAction)
            incorrectTextToReplace = try container.decodeIfPresent(
                String.self,
                forKey: .incorrectTextToReplace
            )
            correctedVocabularyTerm = try container.decodeIfPresent(
                String.self,
                forKey: .correctedVocabularyTerm
            )
        }
    }

    private enum ReviewError: LocalizedError {
        case unavailable
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(
                    localized: "The configured AI enhancement provider cannot review Auto Learn candidates."
                )
            case .invalidResponse:
                return String(localized: "The AI returned an invalid Auto Learn review response.")
            }
        }
    }

    private let enhancementService: AIEnhancementService
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "AutoLearnAIReview"
    )

    init(enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
    }

    /// True when a review could run right now. Used to defer queued reviews
    /// while providers are still starting up instead of recording a failure.
    var hasAvailableProvider: Bool {
        guard let aiService = enhancementService.getAIService() else { return false }
        let connectedProviders = availableProviders(in: aiService)
        if let selected = AutoLearnSettings.selectedProvider {
            return connectedProviders.contains(selected)
        }
        return !connectedProviders.isEmpty
    }

    func review(_ candidates: [AutoLearnReviewCandidate]) async throws -> AutoLearnReviewResult {
        guard !candidates.isEmpty else {
            return AutoLearnReviewResult(reviewDecisions: [], unresolvedReviews: [])
        }
        guard let aiService = enhancementService.getAIService() else {
            throw ReviewError.unavailable
        }

        let connectedProviders = availableProviders(in: aiService)
        // Respect the user's provider choice. Ollama keeps correction review on-device.
        guard let provider = AutoLearnSettings.selectedProvider ?? connectedProviders.first,
            connectedProviders.contains(provider)
        else {
            throw ReviewError.unavailable
        }
        let modelName = AutoLearnSettings.selectedModel ?? aiService.selectedModel(for: provider)

        let candidatesForReview = candidates.enumerated().map { index, candidate in
            AutoLearnReviewRequest.CandidateForReview(
                candidateID: index,
                originalText: candidate.originalText,
                correctedText: candidate.correctedText
            )
        }
        let requestData = try JSONEncoder().encode(
            AutoLearnReviewRequest(candidatesForReview: candidatesForReview)
        )
        let requestText = String(decoding: requestData, as: UTF8.self)

        let loggedModelName = modelName ?? "provider-default"
        logger.notice(
            "Auto Learn review started provider=\(provider.rawValue, privacy: .public) model=\(loggedModelName, privacy: .public) candidates=\(candidates.count, privacy: .public)"
        )
        let responseText = try await aiService.reviewAutoLearnCandidates(
            payload: requestText,
            systemPrompt: Self.reviewPrompt,
            provider: provider,
            modelName: modelName
        )
        logger.notice(
            "Auto Learn AI payload: request=\(requestText, privacy: .public) response=\(responseText, privacy: .public)"
        )
        let candidateReviewDecisions = try decodeResponse(
            responseText,
            provider: provider,
            modelName: loggedModelName
        )
        let expectedCandidateIDs = Set(candidates.indices)
        let decisionsByCandidateID = Dictionary(grouping: candidateReviewDecisions) {
            $0.candidateID
        }
        let correctedContexts = candidates.map(\.correctedText)
        for unknownCandidateID in decisionsByCandidateID.keys
        where !expectedCandidateIDs.contains(unknownCandidateID) {
            logger.warning(
                "Ignoring Auto Learn decision with unknown candidate ID=\(unknownCandidateID, privacy: .public)"
            )
        }

        var reviewDecisions: [AutoLearnReviewDecision] = []
        var unresolvedReviews: [AutoLearnUnresolvedReview] = []

        for (index, candidate) in candidates.enumerated() {
            guard let matchingDecisions = decisionsByCandidateID[index] else {
                unresolvedReviews.append(
                    unresolvedReview(for: candidate, reason: .missingDecision)
                )
                continue
            }

            // One diff candidate can contain adjacent corrections with no
            // unchanged token between them. Let the reviewer separate those
            // terms, but never mix an accepted correction with a rejection.
            if matchingDecisions.count > 1,
                matchingDecisions.contains(where: { $0.learningAction == .rejectCorrection })
            {
                unresolvedReviews.append(
                    unresolvedReview(
                        for: candidate,
                        reason: .conflictingDecisions,
                        decision: matchingDecisions.first
                    )
                )
                continue
            }

            var validatedDecisions: [AutoLearnReviewDecision] = []
            var unresolvedDecision: AutoLearnUnresolvedReview?
            for decision in matchingDecisions {
                let validation = validate(
                    decision,
                    for: candidate,
                    correctedContexts: correctedContexts
                )
                guard let validatedDecision = validation.decision else {
                    unresolvedDecision = unresolvedReview(
                        for: candidate,
                        reason: validation.failure ?? .invalidRequiredActionValues,
                        decision: decision
                    )
                    break
                }
                validatedDecisions.append(validatedDecision)
            }

            if let unresolvedDecision {
                unresolvedReviews.append(unresolvedDecision)
            } else if !decisionsAreIndependent(validatedDecisions, for: candidate) {
                unresolvedReviews.append(
                    unresolvedReview(
                        for: candidate,
                        reason: .conflictingDecisions,
                        decision: matchingDecisions.first
                    )
                )
            } else {
                reviewDecisions.append(contentsOf: validatedDecisions)
            }
        }

        return AutoLearnReviewResult(
            reviewDecisions: reviewDecisions,
            unresolvedReviews: unresolvedReviews
        )
    }

    private func availableProviders(in aiService: AIService) -> [AIProvider] {
        aiService.connectedProviders.filter {
            AutoLearnProviderPolicy.isSupported($0)
                && ($0 != .ollama || !aiService.availableModels(for: $0).isEmpty)
        }
    }

    private func unresolvedReview(
        for candidate: AutoLearnReviewCandidate,
        reason: AutoLearnUnresolvedReason,
        decision: CandidateReviewDecision? = nil
    ) -> AutoLearnUnresolvedReview {
        AutoLearnUnresolvedReview(
            candidateID: candidate.candidateID,
            reason: reason,
            learningAction: decision?.learningAction,
            incorrectTextToReplace: decision?.incorrectTextToReplace,
            correctedVocabularyTerm: decision?.correctedVocabularyTerm
        )
    }

    private func validate(
        _ decision: CandidateReviewDecision,
        for candidate: AutoLearnReviewCandidate,
        correctedContexts: [String]
    ) -> (decision: AutoLearnReviewDecision?, failure: AutoLearnUnresolvedReason?) {
        if decision.learningAction == .rejectCorrection {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .rejectCorrection,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: nil
                ),
                nil
            )
        }

        guard let correctedVocabularyTerm = decision.correctedVocabularyTerm?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return (nil, .missingRequiredActionValues)
        }
        guard !correctedVocabularyTerm.isEmpty,
            correctedVocabularyTerm.count <= AutoLearnLimits.maximumCandidateCharacters,
            isGrounded(correctedVocabularyTerm, in: correctedContexts)
        else {
            return (nil, .invalidRequiredActionValues)
        }

        if decision.learningAction == .addVocabularyOnly {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .addVocabularyOnly,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: correctedVocabularyTerm
                ),
                nil
            )
        }

        guard let incorrectTextToReplace = decision.incorrectTextToReplace?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return (nil, .missingRequiredActionValues)
        }
        guard !incorrectTextToReplace.isEmpty,
            incorrectTextToReplace != correctedVocabularyTerm,
            incorrectTextToReplace.count <= AutoLearnLimits.maximumCandidateCharacters,
            !incorrectTextToReplace.contains(","),
            isExactSubstring(incorrectTextToReplace, of: candidate.originalText)
        else {
            return (nil, .invalidRequiredActionValues)
        }

        guard AutoLearnReplacementSafety.isSafeAutomaticSource(incorrectTextToReplace) else {
            return (nil, .unsafeGlobalReplacement)
        }

        if differsOnlyByLetterCase(incorrectTextToReplace, correctedVocabularyTerm) {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .rejectCorrection,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: nil
                ),
                nil
            )
        }

        return (
            AutoLearnReviewDecision(
                candidateID: candidate.candidateID,
                learningAction: decision.learningAction,
                incorrectTextToReplace: incorrectTextToReplace,
                correctedVocabularyTerm: correctedVocabularyTerm
            ),
            nil
        )
    }

    private func differsOnlyByLetterCase(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    private func isExactSubstring(_ term: String, of context: String) -> Bool {
        context.range(of: term, options: .literal) != nil
    }

    private func isGrounded(_ term: String, in contexts: [String]) -> Bool {
        contexts.contains { isExactSubstring(term, of: $0) }
    }

    private func decisionsAreIndependent(
        _ decisions: [AutoLearnReviewDecision],
        for candidate: AutoLearnReviewCandidate
    ) -> Bool {
        let originalTerms = decisions.compactMap(\.incorrectTextToReplace)
        guard canLocateWithoutOverlap(originalTerms, in: candidate.originalText) else {
            return false
        }

        // Batch canonicalization may intentionally return a corrected term
        // from another candidate, so only test terms present in this snippet.
        let localCorrectedTerms = decisions.compactMap(\.correctedVocabularyTerm).filter {
            isExactSubstring($0, of: candidate.correctedText)
        }
        return canLocateWithoutOverlap(localCorrectedTerms, in: candidate.correctedText)
    }

    private func canLocateWithoutOverlap(_ terms: [String], in text: String) -> Bool {
        guard terms.count > 1 else { return true }
        let text = text as NSString
        let rangesByTerm = terms.map { term -> [NSRange] in
            var matches: [NSRange] = []
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let match = text.range(of: term, options: .literal, range: searchRange)
                guard match.location != NSNotFound else { break }
                matches.append(match)
                let nextLocation = match.location + 1
                guard nextLocation < text.length else { break }
                searchRange = NSRange(
                    location: nextLocation,
                    length: text.length - nextLocation
                )
            }
            return matches
        }

        func assign(_ termIndex: Int, occupied: [NSRange]) -> Bool {
            guard termIndex < rangesByTerm.count else { return true }
            for range in rangesByTerm[termIndex]
            where occupied.allSatisfy({ NSIntersectionRange($0, range).length == 0 }) {
                if assign(termIndex + 1, occupied: occupied + [range]) {
                    return true
                }
            }
            return false
        }

        return assign(0, occupied: [])
    }

    private func decodeResponse(
        _ text: String,
        provider: AIProvider,
        modelName: String
    ) throws -> [CandidateReviewDecision] {
        var payload = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present (e.g. ```json ... ``` or ``` ... ```)
        if let fenceStart = payload.range(of: "```") {
            let afterFence = payload[fenceStart.upperBound...]
            let jsonContent: Substring
            if let firstNewline = afterFence.firstIndex(of: "\n") {
                jsonContent = afterFence[afterFence.index(after: firstNewline)...]
            } else {
                jsonContent = afterFence
            }
            if let fenceEnd = jsonContent.range(of: "```", options: .backwards) {
                payload = String(jsonContent[..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                payload = String(jsonContent).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // If payload has surrounding commentary, extract between the outer brackets [ ... ]
        if let firstBracket = payload.firstIndex(of: "["),
           let lastBracket = payload.lastIndex(of: "]"),
           firstBracket <= lastBracket {
            payload = String(payload[firstBracket...lastBracket])
        }

        let data = Data(payload.utf8)

        do {
            return try JSONDecoder().decode([CandidateReviewDecision].self, from: data)
        } catch {
            if let singleDecision = try? JSONDecoder().decode(CandidateReviewDecision.self, from: data) {
                return [singleDecision]
            }
            let diagnostic = invalidResponseDiagnostic(for: data)
            logInvalidResponse(
                payload,
                provider: provider,
                modelName: modelName,
                reason: diagnostic.reason,
                shape: diagnostic.shape
            )
            throw ReviewError.invalidResponse
        }
    }

    private func logInvalidResponse(
        _ payload: String,
        provider: AIProvider,
        modelName: String,
        reason: String,
        shape: String = "unknown"
    ) {
        let preview = String(payload.prefix(1_000))
        logger.error(
            "Auto Learn response invalid provider=\(provider.rawValue, privacy: .public) model=\(modelName, privacy: .public) reason=\(reason, privacy: .public) shape=\(shape, privacy: .public) characters=\(payload.count, privacy: .public) responsePreview=\(preview, privacy: .private)"
        )
    }

    private func invalidResponseDiagnostic(for data: Data) -> (reason: String, shape: String) {
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            return ("malformed-json", "invalid-json")
        }
        if value is [Any] { return ("invalid-decision-array", "array") }
        if value is [String: Any] { return ("expected-top-level-array", "object") }
        return ("unsupported-json-shape", "scalar")
    }

    private static let reviewPrompt = """
        Review speech-to-text (ASR) corrections across English, Traditional/Simplified Chinese, and multilingual speech. Each candidate has originalText and correctedText containing the user's edit plus surrounding context.

        Core Purpose:
        Identify speech-to-text recognition errors that the user corrected, and learn them as text replacements or vocabulary terms so future dictation outputs the intended wording automatically.

        Phonetic & Speech Misrecognition Principles:
        1. Phonetic resemblance / Homophones:
           - In Chinese (Traditional and Simplified), speech recognition frequently produces homophones (同音字) or near-homophones (近音字/拼音注音發音訛誤/聲調差異/捲舌與平舌音混淆). Examples include: 點書 → 點數, 本期 → 本機, 一者 → 一則, 勾語 → 口語, 基本數 → 幾本書, 備份 → 輩分, 機率 → 幾率.
           - In English / multilingual speech, misrecognitions sound similar to the intended term (e.g. Gipart → GitHub, Viest → Vitest, pages → Pax, duck → Docker).
           - When the original term and corrected term sound identical, nearly identical, or plausibly share pronunciation/transliteration in Mandarin, English, or other languages, THIS IS A GENUINE SPEECH-TO-TEXT ERROR. You MUST accept it, typically as addReplacementOnly.
           - DO NOT reject Chinese homophone corrections or English phonetic corrections simply because the destination is a common word, daily vocabulary, or standard term (e.g., 點數, 本機, 口語, 一則). Replacing speech homophone errors with the user's intended word is the core utility of addReplacementOnly.

        2. Technical, Software, Brand, and Proper Names:
           - Technologies, libraries, tools, brands, and domain-specific terms (e.g., GitHub, React, Docker, Python, Xcode, Whisper, Claude, Gemini, macOS, Notion) and user project names are valid and encouraged to learn. If speech recognition misrecognized or mangled them, accept as addReplacementAndVocabulary or addReplacementOnly.
           - When both the original and corrected terms are independently valid brands, products, technical terms, names, or ordinary words, do NOT create a global replacement between them. Use addVocabularyOnly for the intended corrected term and let sentence context disambiguate future speech. Example: Garmin and Gemini are both valid product names, so never learn Garmin → Gemini or Gemini → Garmin as a replacement.

        3. Mandatory personal-name rule:
           - A personal name is one indivisible term. For a visible multiword personal name, incorrectTextToReplace and correctedVocabularyTerm must contain every visible name component. If only one component (e.g., first name or surname) changed or is visible, use addReplacementOnly rather than Vocabulary.
           - NEVER output a one-character Chinese, Japanese, Korean, or Thai incorrectTextToReplace. Expand both fields to the complete visible name or term, such as 邱鴻瑋 → 邱紘瑋. If the complete source term cannot be grounded exactly in originalText, use addVocabularyOnly with the complete corrected name when visible; otherwise rejectCorrection.

        Rejection Criteria (rejectCorrection):
        - Semantic rewrites with completely unrelated pronunciation (e.g., "今天吃蘋果" → "今天吃香蕉", "星期一" → "星期五", "台北" → "高雄" - words that do not sound alike at all and merely change factual meaning or preference).
        - Whole sentence rephrasings, substantial additions or deletions of independent thoughts, grammar rewrites.
        - Formatting-only, whitespace-only, or punctuation-only edits.
        - Case-only changes (e.g., "apple" → "Apple").

        Learning Actions:
        1. addReplacementAndVocabulary: The corrected term is a distinctive proper noun, personal name, brand, product, tech term, or domain term, and the original plausibly sounds like it.
        2. addReplacementOnly: Use for speech-to-text phonetic/homophone misrecognitions (especially Chinese homophones/near-homophones like 點書→點數, 本期→本機, 一者→一則, 勾語→口語, or partial personal names). The original sounds like the corrected term, and the substitution is safe to apply whenever that misrecognition occurs.
        3. addVocabularyOnly: The corrected term is a specialized term/name that should be recognized by the speech model, but the source error is too broad/ambiguous for a global replacement rule, or both source and destination are independently valid terms.
        4. rejectCorrection: The edit shares no phonetic or homophonic resemblance (pure semantic rewrite), or is grammar/style rephrasing, or case-only change.

        Output Requirements:
        - Return only one JSON array. Do not return an outer object, explanation, Markdown, or code fence.
        - Each array object must contain exactly: candidateID, learningAction, incorrectTextToReplace, correctedVocabularyTerm.
        - incorrectTextToReplace must be an exact nonempty contiguous substring of originalText.
        - correctedVocabularyTerm must be copied exactly from correctedText.
        - A replacement source from Chinese, Japanese, Korean, or Thai must contain at least two characters. Never create a global single-character replacement for these scripts.
        - For addVocabularyOnly set incorrectTextToReplace to null.
        - For rejectCorrection set both fields to null.
        - If one candidate contains several separate homophone, near-homophone, or typo corrections, output one decision object per correction. Do not stop after the first correction. Every object uses that same candidateID, and the pairs must be distinct non-overlapping substrings. Do not emit rejectCorrection for the unchanged remainder of that candidate. Emit a single rejectCorrection only when the candidate contains no speech-to-text correction at all.

        Exact output format:
        [{"candidateID":0,"learningAction":"addReplacementOnly","incorrectTextToReplace":"常班","correctedVocabularyTerm":"長班"},{"candidateID":0,"learningAction":"addReplacementOnly","incorrectTextToReplace":"念課表","correctedVocabularyTerm":"練課表"},{"candidateID":1,"learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null}]
        """
}
