import FluidAudio
import Foundation

/// Translation models on this device: fetched from their pinned Hugging Face
/// revision into Application Support, file by file over plain HTTPS (the hub
/// client has hung on large files here), sizes checked so a cut-off download
/// is fetched again rather than loaded, and kept out of iCloud backups since
/// they can always be fetched again. On a Mac the checkout's models/ folder
/// counts too, for development.
public enum ModelStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Interpreter/Models")
    }

    /// Where `model` is, if it is all here.
    public static func location(of model: TranslationModel) -> URL? {
        location(of: model, in: [directory.appending(path: model.id), Resources.checkout.appending(path: "models/\(model.id)")])
    }

    static func location(of model: TranslationModel, in folders: [URL]) -> URL? {
        folders
            .first { folder in model.files.allSatisfy { fileSize(folder.appending(path: $0.name)) == $0.size } }
    }

    public static func isDownloaded(_ model: TranslationModel) -> Bool { location(of: model) != nil }

    /// Downloaded into this app's storage, so the app can delete it (a
    /// checkout's models/ folder is the developer's, not the app's).
    public static func isDeletable(_ model: TranslationModel) -> Bool { used(model) > 0 }

    /// Fetch whatever of `model` isn't here yet; `progress` runs from 0 to 1.
    @discardableResult
    public static func download(_ model: TranslationModel,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let found = location(of: model) { return found }
        let folder = directory.appending(path: model.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try excluded.setResourceValues(values)
        var done: Int64 = 0
        for file in model.files {
            let target = folder.appending(path: file.name)
            if fileSize(target) == file.size {
                done += file.size
                continue
            }
            let url = URL(string: "https://huggingface.co/\(model.repo)/resolve/\(model.revision)/\(file.name)")!
            let base = done
            let downloaded = try await Download.fetch(url) { written in
                progress(Double(base + written) / Double(model.download))
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }
            guard fileSize(downloaded) == file.size else {
                throw Problem("\(file.name) arrived as \(fileSize(downloaded) ?? 0) bytes, not \(file.size). Try again on a steady connection.")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: downloaded, to: target)
            done += file.size
        }
        progress(1)
        return folder
    }

    /// Remove a downloaded model (never the checkout's copy).
    public static func delete(_ model: TranslationModel) throws {
        let folder = directory.appending(path: model.id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    /// Bytes of downloaded models on this device.
    public static func used(_ model: TranslationModel) -> Int64 {
        model.files.compactMap { fileSize(directory.appending(path: model.id).appending(path: $0.name)) }.reduce(0, +)
    }

    /// Parakeet's folder in FluidAudio's cache, if it has been downloaded.
    public static func recognitionSize() -> Int64? {
        let folder = AsrModels.defaultCacheDirectory(for: .v3)
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        let total = files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
            .reduce(0, +)
        return total > 0 ? Int64(total) : nil
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// One file, with the bytes written so far reported as they arrive.
final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

    static func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let download = Download(progress: progress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            download.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            continuation?.resume(throwing: Problem("The model server did not return a successful HTTP response."))
            continuation = nil
            return
        }
        // The temporary file is deleted when this returns; keep it.
        let kept = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
