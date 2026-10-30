import CryptoKit
import Foundation

/// The EmbeddingGemma 2 files: ggml-org's Q8_0 GGUF conversion of google/embeddinggemma-2, pinned to one revision so
/// every install makes the same vectors.
public enum EmbeddingModelFiles {
    public static let repository = "ggml-org/embeddinggemma-2-GGUF"
    public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    public struct File: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
        public var repository = EmbeddingModelFiles.repository
        public var revision = EmbeddingModelFiles.revision
        /// Where under Models/ it goes; `name` is its path in the repository (it may have folders in it).
        public var folder = ""

        public var url: URL {
            let path = name.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!
        }
        public var installed: URL {
            (folder.isEmpty ? AppPaths.models : AppPaths.models.appendingPathComponent(folder, isDirectory: true)).appendingPathComponent(name)
        }
        public var isInstalled: Bool { FileManager.default.fileExists(atPath: installed.path) }
    }

    /// The text model (310 MB): all a search needs.
    public static let text = File(name: "embeddinggemma-2-Q8_0.gguf", bytes: 309_855_456,
                                  sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
    /// The image and audio encoders (555 MB).
    public static let media = File(name: "mmproj-embeddinggemma-2-Q8_0.gguf", bytes: 554_821_024,
                                   sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
    public static let all = [text, media]
    public static let totalBytes = all.reduce(0) { $0 + $1.bytes }

    /// Only verified files get their final name, so a file being there means it's whole.
    public static var missing: [File] {
        all.filter { !FileManager.default.fileExists(atPath: $0.installed.path) }
    }
    public static var isInstalled: Bool { missing.isEmpty }

    /// A file's SHA-256, as lowercase hex. Read through one reused 4 MB buffer, so checking a 2.7 GB model never
    /// holds more than that in memory.
    public static func sha256(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url]) }
        stream.open()
        defer { stream.close() }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 4 << 20)
        var count = 0
        repeat {
            count = buffer.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url]) }
            buffer.withUnsafeBufferPointer { digest.update(bufferPointer: UnsafeRawBufferPointer(start: $0.baseAddress, count: count)) }
        } while count > 0
        let hex = Array("0123456789abcdef")
        return String(digest.finalize().flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] })
    }
}

/// The model that writes answers in Ask: Qwen3.5-4B (Apache 2.0) in Unsloth's Q4_K_M GGUF, pinned like EmbeddingGemma.
/// Chosen in the 2026-10-22 bake-off: 56 of 59 answerable questions right, every "not in your files" question
/// refused, 0.5 s to the first word and ~95 tokens/s on an M4 Max, ~3.3 GB on the GPU.
public enum ChatModelFiles {
    public static let model = EmbeddingModelFiles.File(name: "Qwen3.5-4B-Q4_K_M.gguf", bytes: 2_740_937_888,
                                              sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
                                              repository: "unsloth/Qwen3.5-4B-GGUF",
                                              revision: "e87f176479d0855a907a41277aca2f8ee7a09523")
    public static let all = [model]
    /// The file the chat server loads. `FAMILIAR_CHAT_MODEL` points at another GGUF (evals of other sizes).
    public static var path: URL {
        ProcessInfo.processInfo.environment["FAMILIAR_CHAT_MODEL"].map { URL(fileURLWithPath: $0) } ?? model.installed
    }
    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: path.path) }
}

public enum DownloadError: LocalizedError {
    case http(Int)
    case checksum(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "Hugging Face answered with HTTP \(code)."
        case .checksum(let name): return "\(name) didn't download correctly (its checksum doesn't match). Try again."
        }
    }
}

/// Downloads the model files that aren't installed yet, resuming a partial download where it stopped, and verifies
/// each against its SHA-256 before giving it its final name.
public final class ModelDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// What this downloader fetches: EmbeddingGemma's files, or the chat model's.
    public let files: [EmbeddingModelFiles.File]
    private var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    /// Bytes on disk across all files, and the total.
    public var onProgress: (@Sendable (Int64, Int64) -> Void)?

    private var session: URLSession!
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var received: Int64 = 0
    private var finishedBefore: Int64 = 0
    private let lock = NSLock()

    public init(files: [EmbeddingModelFiles.File] = EmbeddingModelFiles.all) {
        self.files = files
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func run() async throws {
        finishedBefore = files.filter(\.isInstalled).reduce(0) { $0 + $1.bytes }
        for file in files where !file.isInstalled {
            try await download(file)
            finishedBefore += file.bytes
        }
        onProgress?(totalBytes, totalBytes)
    }

    public func cancel() {
        session.invalidateAndCancel()
    }

    private func download(_ file: File) async throws {
        let part = file.installed.appendingPathExtension("part")
        let fm = FileManager.default
        try fm.createDirectory(at: file.installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        var existing = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0
        if existing > file.bytes { try? fm.removeItem(at: part); fm.createFile(atPath: part.path, contents: nil); existing = 0 }

        if existing < file.bytes {
            let handle = try FileHandle(forWritingTo: part)
            try handle.seekToEnd()
            lock.withLock { self.handle = handle; self.received = existing }
            var request = URLRequest(url: file.url)
            if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                session.dataTask(with: request).resume()
            }
            try? handle.close()
        }

        let digest = try EmbeddingModelFiles.sha256(of: part)
        guard digest == file.sha256 else {
            try? fm.removeItem(at: part)
            throw DownloadError.checksum(file.name)
        }
        try? fm.removeItem(at: file.installed)
        try fm.moveItem(at: part, to: file.installed)
    }

    typealias File = EmbeddingModelFiles.File

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            // The server ignored the range: start the file over.
            lock.withLock {
                try? handle?.truncate(atOffset: 0)
                received = 0
            }
        } else if status != 206 {
            completionHandler(.cancel)
            finish(DownloadError.http(status))
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let total: Int64 = lock.withLock {
            handle?.write(data)
            received += Int64(data.count)
            return finishedBefore + received
        }
        onProgress?(total, totalBytes)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            let c = self.continuation
            self.continuation = nil
            return c
        }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}
