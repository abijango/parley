import Foundation
import Speech

/// Tracks SpeechAnalyzer locale asset download/install state — the Speech-framework
/// counterpart to `FluidModelManager` (no on-disk path; assets live in the OS store).
@MainActor
final class SpeechAssetManager: ObservableObject {
    enum Status: Equatable {
        case unknown
        case unsupported
        case notInstalled
        case downloading
        case installed
        case failed(String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var supportedLocales: [Locale] = []

    /// Refresh whether the configured locale's speech assets are installed.
    func refreshPresence(for localeIdentifier: String) {
        guard status != .downloading else { return }
        Task {
            let locales = await SpeechTranscriber.supportedLocales
            supportedLocales = locales
            guard let locale = await resolvedLocale(for: localeIdentifier) else {
                status = .unsupported
                return
            }
            let installed = await SpeechTranscriber.installedLocales
            let isInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
            status = isInstalled ? .installed : .notInstalled
        }
    }

    /// Download and install speech assets for the given BCP-47 locale id.
    func download(localeIdentifier: String) {
        guard status != .downloading else { return }
        status = .downloading
        Task {
            do {
                guard let locale = await resolvedLocale(for: localeIdentifier) else {
                    status = .unsupported
                    return
                }
                let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                status = .installed
                AppLog.log("SpeechAnalyzer assets installed for \(locale.identifier(.bcp47))", category: "model")
            } catch {
                status = .failed(error.localizedDescription)
                AppLog.log("SpeechAnalyzer asset download failed: \(error.localizedDescription)", category: "model")
            }
        }
    }

    /// Returns the Speech-supported locale equivalent to `localeIdentifier`, or nil.
    static func resolvedLocale(for localeIdentifier: String) async -> Locale? {
        let requested = Locale(identifier: localeIdentifier)
        if let eq = await SpeechTranscriber.supportedLocale(equivalentTo: requested) { return eq }
        // Fall back to language-only match (e.g. "en" → en-US).
        let lang = requested.language.languageCode?.identifier ?? localeIdentifier
        let locales = await SpeechTranscriber.supportedLocales
        return locales.first { $0.language.languageCode?.identifier == lang }
    }

    private func resolvedLocale(for localeIdentifier: String) async -> Locale? {
        await Self.resolvedLocale(for: localeIdentifier)
    }
}
