import Foundation

/// Reliable Hugging Face model downloader that BYPASSES swift-transformers' Xet client.
/// On Xet-enabled repos (most current `mlx-community` models), swift-transformers' built-in
/// Xet transfer is slow and dies mid-file on large weights, and MLX's `downloadModel` then
/// silently masks it as "config.json not found". Instead we fetch each repo file from the
/// public `resolve/main/<file>` URL via URLSession (which transparently follows the 302 to
/// the CDN) into a flat local directory, then hand MLX that directory via
/// `ModelConfiguration(directory:)` — so the Hub/Xet path is never used.
final class HFModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let endpoint = "https://huggingface.co"
    private var continuation: CheckedContinuation<URL, Error>?
    private var onBytes: ((Int64) -> Void)?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Ensures every repo file is present in `dir`, downloading the missing/incomplete ones.
    /// Returns `dir`. `progress` is the overall fraction (0...1) of bytes still to fetch.
    func ensureModel(id: String, in dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = try await siblings(id: id)
        guard !files.isEmpty else { throw DownloadError(message: "No files listed for \(id) on Hugging Face.") }

        // Decide what's missing and total the bytes to fetch.
        var missing: [(name: String, url: URL, size: Int64)] = []
        var totalToFetch: Int64 = 0
        for name in files {
            let url = URL(string: "\(endpoint)/\(id)/resolve/main/\(name)")!
            let remote = try await remoteSize(url)
            let local = dir.appendingPathComponent(name)
            let localSize = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? Int64
            if let localSize, remote > 0, localSize == remote { continue }   // already complete
            missing.append((name, url, remote))
            totalToFetch += max(0, remote)
        }
        guard !missing.isEmpty else { progress(1); return dir }
        if totalToFetch <= 0 { totalToFetch = 1 }   // avoid divide-by-zero if HEAD sizes were unknown

        var prior: Int64 = 0
        for f in missing {
            let tmp = try await downloadFile(f.url) { written in
                progress(min(0.999, Double(prior + written) / Double(totalToFetch)))
            }
            let dest = dir.appendingPathComponent(f.name)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            prior += max(0, f.size)
            progress(min(0.999, Double(prior) / Double(totalToFetch)))
        }
        progress(1)
        return dir
    }

    // MARK: Hub metadata

    private func siblings(id: String) async throws -> [String] {
        let url = URL(string: "\(endpoint)/api/models/\(id)")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError(message: "Model \"\(id)\" not found on Hugging Face (check the id in Settings → Summary).")
        }
        struct Info: Decodable { struct Sibling: Decodable { let rfilename: String }; let siblings: [Sibling] }
        let info = try JSONDecoder().decode(Info.self, from: data)
        let skip: Set<String> = [".gitattributes"]
        // Skip docs; keep config/tokenizer/weights/index.
        return info.siblings.map(\.rfilename).filter { !skip.contains($0) && !$0.lowercased().hasSuffix(".md") }
    }

    private func remoteSize(_ url: URL) async throws -> Int64 {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        let (_, resp) = try await URLSession.shared.data(for: req)
        let len = resp.expectedContentLength
        return len > 0 ? len : 0
    }

    // MARK: Single-file download with progress

    private func downloadFile(_ url: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.onBytes = onBytes
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onBytes?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is removed when this delegate returns — move it to a stable temp now.
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            continuation?.resume(returning: stable)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        onBytes = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Only relevant on failure; success is handled in didFinishDownloadingTo.
        if let error, let cont = continuation {
            cont.resume(throwing: error)
            continuation = nil
            onBytes = nil
        }
    }
}
