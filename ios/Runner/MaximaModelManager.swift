import Foundation
import ZIPFoundation

/// Downloads and unpacks a Vosk speech model into
/// `Application Support/models/vosk-model`.
///
/// Default model mirrors the Android manager:
/// `vosk-model-small-en-us-0.15` (~40 MB). The Dart side resolves the
/// directory through `getVoskModelDir`; bundling a model inside the
/// Runner.app resource bundle (`models/vosk-model`) is also detected
/// automatically.
final class MaximaModelManager {
    static let shared = MaximaModelManager()

    static let defaultModelUrl =
        "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"

    private init() {}

    /// Directory where the extracted model lives.
    var modelDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("models/vosk-model", isDirectory: true)
    }

    /// A usable model exists either bundled in the app or extracted
    /// under Application Support.
    var isInstalled: Bool {
        if bundledModelUrl() != nil { return true }
        return FileManager.default.fileExists(atPath: modelDirectory.path)
    }

    /// Path Dart should open: bundled copy wins, then the downloaded one.
    var usableModelPath: String? {
        if let bundled = bundledModelUrl() { return bundled.path }
        return isInstalled ? modelDirectory.path : nil
    }

    private func bundledModelUrl() -> URL? {
        let candidates = [
            "vosk-model",
            "models/vosk-model",
            "vosk-model-small-en-us-0.15",
        ]
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: nil),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Downloads [urlString] (default: the small English model) and
    /// unzips it so that `modelDirectory` contains the recognizer graph.
    func downloadModel(
        urlString: String = MaximaModelManager.defaultModelUrl,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(ModelError.badUrl))
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { tmp, _, error in
            do {
                guard let tmp = tmp else {
                    throw error ?? ModelError.downloadFailed
                }
                let fm = FileManager.default
                let target = self.modelDirectory
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }

                // The archive contains a single top-level directory
                // (e.g. vosk-model-small-en-us-0.15/); unzip into the
                // parent and rename it to `vosk-model`.
                let staging = target.deletingLastPathComponent()
                    .appendingPathComponent(".staging-\(UUID().uuidString)")
                try fm.createDirectory(
                    at: staging, withIntermediateDirectories: true
                )
                try fm.unzipItem(at: tmp, to: staging)
                defer { try? fm.removeItem(at: staging) }

                let entries = try fm.contentsOfDirectory(
                    at: staging,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles
                )
                guard let extracted = entries.first(where: {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey])
                        .isDirectory) == true
                }) else {
                    throw ModelError.badArchive
                }
                try fm.moveItem(at: extracted, to: target)
                completion(.success(target.path))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    enum ModelError: Error {
        case badUrl
        case downloadFailed
        case badArchive
    }
}
