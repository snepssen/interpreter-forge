import Foundation

/// The translation model on a device with no checkout beside it: fetched once
/// from the pinned Hugging Face revision into Application Support, file by
/// file over plain HTTPS (the hub client has hung on large files here), with
/// sizes checked so a cut-off download is fetched again rather than loaded.
public enum ModelStore {
    struct Model {
        let repo: String
        let revision: String
        let folder: String
        let files: [(name: String, size: Int64)]
        var total: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    static let qwen4b = Model(
        repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
        folder: "qwen3-4b-instruct-2507-4bit",
        files: [
            ("added_tokens.json", 707), ("chat_template.jinja", 4040), ("config.json", 938),
            ("generation_config.json", 238), ("merges.txt", 1_671_853), ("model.safetensors.index.json", 63964),
            ("special_tokens_map.json", 613), ("tokenizer.json", 11_422_654), ("tokenizer_config.json", 5440),
            ("vocab.json", 2_776_833), ("model.safetensors", 2_263_022_417),
        ])

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Interpreter/Models")
    }

    /// The translation model, downloading it first if it isn't here.
    public static func translationModel(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let found = Resources.translationModel { return found }
        let model = qwen4b
        let folder = directory.appending(path: model.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var done: Int64 = 0
        for (name, size) in model.files {
            let target = folder.appending(path: name)
            if fileSize(target) == size {
                done += size
                continue
            }
            let url = URL(string: "https://huggingface.co/\(model.repo)/resolve/\(model.revision)/\(name)")!
            let base = done
            let downloaded = try await Download.fetch(url) { written in
                progress(Double(base + written) / Double(model.total))
            }
            guard fileSize(downloaded) == size else {
                throw Problem("\(name) arrived as \(fileSize(downloaded) ?? 0) bytes, not \(size). Try again on a steady connection.")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: downloaded, to: target)
            done += size
        }
        // Keep it out of iCloud backups: it can always be fetched again.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)
        return folder
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
