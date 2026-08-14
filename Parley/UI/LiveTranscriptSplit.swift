import Foundation

/// Splits a live timeline so confirmed rows stay identity-stable while the
/// unconfirmed tail can update on its own.
enum LiveTranscriptSplit {
    static func confirmed(_ segments: [Segment]) -> [Segment] {
        guard let last = segments.last, !last.confirmed else { return segments }
        return Array(segments.dropLast())
    }

    static func volatile(_ segments: [Segment]) -> Segment? {
        guard let last = segments.last, !last.confirmed else { return nil }
        return last
    }
}
