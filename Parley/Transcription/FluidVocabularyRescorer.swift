import Foundation
import FluidAudio

/// Post-pass vocabulary boosting for batch Parakeet (TDT v3) offline transcripts.
enum FluidVocabularyRescorer {
    struct Result: Sendable {
        let text: String
        let modified: Bool
    }

    /// Rescore a batch transcript when custom vocabulary + CTC models are available.
    static func apply(
        transcript: String,
        tokenTimings: [TokenTiming],
        samples: [Float],
        vocabulary: CustomVocabularyContext,
        ctcModels: CtcModels
    ) async -> Result {
        let base = Result(text: transcript, modified: false)
        guard !tokenTimings.isEmpty, !samples.isEmpty else { return base }
        do {
            let blankId = ctcModels.vocabulary.count
            let spotter = CtcKeywordSpotter(models: ctcModels, blankId: blankId)
            let spotResult = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: vocabulary,
                minScore: nil
            )
            let logProbs = spotResult.logProbs
            guard !logProbs.isEmpty else { return base }

            let vocabConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
            let ctcModelDir = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
            let rescorer = try await VocabularyRescorer.create(
                spotter: spotter,
                vocabulary: vocabulary,
                config: .default,
                ctcModelDirectory: ctcModelDir
            )
            let output = rescorer.ctcTokenRescore(
                transcript: transcript,
                tokenTimings: tokenTimings,
                logProbs: logProbs,
                frameDuration: spotResult.frameDuration,
                cbw: vocabConfig.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: vocabConfig.minSimilarity
            )
            guard output.wasModified else { return base }
            return Result(text: output.text, modified: true)
        } catch {
            AppLog.log("Fluid vocabulary rescore failed: \(error.localizedDescription)", category: "record")
            return base
        }
    }
}
