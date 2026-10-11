import FluidAudio
import Foundation
import WhisperKit

/// App-owned, persistent Whisper files, with a completion record written only
/// after the models and tokenizer load. Cached launches never contact the Hub.
enum RecognitionStore {
    static var whisperBase: URL { ModelStore.directory.appending(path: "Recognition/Whisper") }
    static var whisperFolder: URL {
        whisperBase.appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-\(RecognitionModel.whisperVariant)")
    }
    struct File: Codable { let path: String; let size: Int64 }

    static func complete(in root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appending(path: "complete.json")),
              let files = try? JSONDecoder().decode([File].self, from: data), !files.isEmpty else { return false }
        return files.allSatisfy {
            !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") &&
            $0.size > 0 && ModelStore.fileSize(root.appending(path: $0.path)) == $0.size
        }
    }

    static func markComplete(in root: URL) throws {
        let files = manifest(in: root)
        guard !files.isEmpty else { throw Problem("No speech recognition files were stored.") }
        try JSONEncoder().encode(files).write(to: root.appending(path: "complete.json"), options: .atomic)
    }

    static func manifest(in root: URL) -> [File] {
        guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return enumerator.compactMap { item -> File? in
            guard let url = item as? URL, url.lastPathComponent != "complete.json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0 else { return nil }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { return nil }
            return File(path: String(path.dropFirst(prefix.count)), size: Int64(size))
        }.sorted { $0.path < $1.path }
    }

    static func excludeFromBackup(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var folder = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    static func size(of model: RecognitionModel) -> Int64? {
        let folder = model == .parakeetUltra ? AsrModels.defaultCacheDirectory(for: .ultra) : whisperBase
        let bytes = manifest(in: folder).map(\.size).reduce(0, +)
        return bytes > 0 ? bytes : nil
    }
}
