import Foundation

/// Which merge strategy combines drop/rejoin recordings.
enum MergeBackend: String { case audioRepass, transcriptStitch }
