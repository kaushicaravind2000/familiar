import Darwin
import Foundation

public enum EmbeddingError: LocalizedError {
    case noServerBinary
    case modelMissing
    case serverDidNotStart(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .noServerBinary: return "The llama-server helper is missing from the app."
        case .modelMissing: return "The EmbeddingGemma 2 model isn't downloaded yet."
        case .serverDidNotStart(let why): return "The embedding model didn't start: \(why)"
        case .badResponse(let why): return "The embedding model answered unexpectedly: \(why)"
        }
    }
}

/// One thing to embed. Text is embedded as given (wrap it with `Prompts` first); media take no prompt.
public enum EmbeddingInput: Sendable {
    case text(String)
    case image(Data, mime: String)   // JPEG or PNG, already sized for its token budget (`ImageSizing`)
    case audio(Data)                 // 16 kHz mono 16-bit WAV, at most 30 s
}

/// How one llama-server is started.
public struct ServerConfig: Sendable {
    /// Names its pid and log files, so two servers never mistake each other's for their own.
    public let name: String
    /// Only the text part (no image & audio part): all a search needs, in a third of the memory.
    public let textOnly: Bool
    public let context: Int
    public let parallel: Int
    public let batch: Int
    /// CPU and HTTP threads; nil leaves llama-server's defaults (one per core).
    public let threads: Int?
    /// Seconds without work before the server stops; nil keeps it loaded.
    public let idleTimeout: TimeInterval?

    /// For indexing: text, pictures and sound, sized by the memory profile. Standard: 4 slots of 2,048 tokens, peak
    /// ~2.6 GB, stops after 5 idle minutes. Low: 2 slots of 1,024 (still room for a 30 s audio window of 750 tokens or
    /// a 560-token page), peak ~1.85 GB, stops after 1 idle minute.
    public static var indexing: ServerConfig { indexing(for: .current) }

    public static func indexing(for profile: MemoryProfile) -> ServerConfig {
        profile == .low
            ? ServerConfig(name: "llama-server", textOnly: false, context: 2048, parallel: 2, batch: 1024, threads: nil,
                           idleTimeout: 60)
            : ServerConfig(name: "llama-server", textOnly: false, context: 8192, parallel: 4, batch: 2048, threads: nil,
                           idleTimeout: 300)
    }
    /// For searches: the text part alone (~330 MB), one query at a time, always loaded. A search no longer waits
    /// behind indexing's picture batches, or for the model to load. The text part is the same file, so a query gets
    /// exactly the vector the indexing server would give it.
    public static let search = ServerConfig(name: "llama-server-search", textOnly: true, context: 1024, parallel: 1,
                                            batch: 1024, threads: 2, idleTimeout: nil)
}

/// EmbeddingGemma 2 on llama.cpp: runs the bundled `llama-server` in embedding mode on a private localhost port and
/// talks to it over HTTP. The server starts on first use and, unless its config keeps it loaded, stops after
/// `idleTimeout` seconds without work, so the model is only in memory while it's needed.
public actor EmbeddingService {
    /// The indexing server (and searches too, when the search server is off).
    public static let shared = EmbeddingService(config: .indexing)
    /// The dedicated search server.
    public static let search = EmbeddingService(config: .search)
    public static let dimension = 768

    public private(set) var config: ServerConfig
    public var idleTimeout: TimeInterval?
    private var process: Process?
    /// True once the server answers /health; requests wait for this, not just for the process.
    private var ready = false
    private var port: Int = 0
    /// A random password made at each start: the server answers only requests that carry it, so other programs on
    /// this Mac can't use the model. It travels in a file only this user can read, never on the command line (which
    /// every process can see).
    private var apiKey = ""
    private var lastUse = Date()
    /// Requests being answered right now (`stopWhenIdle` waits for them).
    private var inFlight = 0
    private var idleTask: Task<Void, Never>?
    private var starting: Task<Void, Error>?
    private let session: URLSession

    public init(config: ServerConfig) {
        self.config = config
        idleTimeout = config.idleTimeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
    }

    public func setIdleTimeout(_ seconds: TimeInterval?) { idleTimeout = seconds }

    /// Takes a new config (the memory profile changed): the server stops now and starts with it when next needed.
    public func reconfigure(_ config: ServerConfig) {
        guard config.context != self.config.context || config.parallel != self.config.parallel
                || config.batch != self.config.batch || config.idleTimeout != self.config.idleTimeout else { return }
        stop()
        self.config = config
        idleTimeout = config.idleTimeout
    }

    public var isRunning: Bool { ready && (process?.isRunning ?? false) }

    /// Embeds `inputs`, returning one L2-normalized 768-d vector per input, or nil for an input the model refused
    /// (too long, a broken picture).
    public func embed(_ inputs: [EmbeddingInput]) async throws -> [[Float]?] {
        guard !inputs.isEmpty else { return [] }
        try await ensureRunning()
        lastUse = Date()
        inFlight += 1
        defer { lastUse = Date(); inFlight -= 1 }
        do {
            return try await request(inputs).map { Optional($0) }
        } catch let error as EmbeddingError {
            Self.log("embedding failed: \(error.localizedDescription)")
            // One bad input fails the whole request: retry them one at a time to keep the rest.
            guard inputs.count > 1 else {
                if case .badResponse = error { return [nil] }
                throw error
            }
            var out: [[Float]?] = []
            for input in inputs {
                out.append(try? await request([input]).first)
            }
            return out
        } catch {
            // A search replaced by the next keystroke is cancelled on purpose: not a failure.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            // The server may have died (memory pressure, a crash in an encoder): start it again once.
            Self.log("request failed: \(error.localizedDescription)")
            if !(process?.isRunning ?? false) {
                process = nil
                ready = false
                try await ensureRunning()
                return try await request(inputs).map { Optional($0) }
            }
            throw error
        }
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        guard let vector = try await embed([.text(Prompts.query(text))]).first ?? nil else {
            throw EmbeddingError.badResponse("no vector for the query")
        }
        return vector
    }

    /// Stops the server once no request is in progress (waiting up to `timeout` seconds for the current one): frees its
    /// memory without failing a request mid-way. Used on small Macs while you chat.
    public func stopWhenIdle(timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        while inFlight > 0 && Date() < deadline { try? await Task.sleep(nanoseconds: 250_000_000) }
        if inFlight == 0 { stop() }
    }

    public func stop() {
        idleTask?.cancel()
        idleTask = nil
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(pid, SIGKILL) }
        }
        process = nil
        ready = false
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Starts the server if it isn't running, and waits until it answers.
    public func ensureRunning() async throws {
        if ready, let process, process.isRunning { return }
        if let starting { return try await starting.value }
        ready = false
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    /// One file per owning process ("llama-server-<owner pid>.pid"), holding the server's pid. The app, the CLI and
    /// test copies can each run their own servers without stopping each other's.
    private var pidFile: URL { AppPaths.applicationSupport.appendingPathComponent("\(config.name)-\(getpid()).pid") }

    private func start() async throws {
        guard let binary = AppPaths.llamaServer else { throw EmbeddingError.noServerBinary }
        let installed = config.textOnly ? FileManager.default.fileExists(atPath: EmbeddingModelFiles.text.installed.path)
                                        : EmbeddingModelFiles.isInstalled
        guard installed else { throw EmbeddingError.modelMissing }
        Self.killStaleServers(named: config.name)

        port = Self.freePort()
        apiKey = (0..<4).map { _ in String(UInt64.random(in: .min ... .max), radix: 16) }.joined()
        let keyFile = AppPaths.applicationSupport.appendingPathComponent("\(config.name).key")
        try? FileManager.default.removeItem(at: keyFile)
        guard FileManager.default.createFile(atPath: keyFile.path, contents: Data(apiKey.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw EmbeddingError.serverDidNotStart("can't write its password file")
        }
        // The server reads the file as it starts; it's removed once the server answers (or fails to).
        defer { try? FileManager.default.removeItem(at: keyFile) }
        let process = Process()
        var arguments = ["--model", EmbeddingModelFiles.text.installed.path]
        if !config.textOnly {
            arguments += ["--mmproj", EmbeddingModelFiles.media.installed.path,
                          "--image-min-tokens", "70", "--image-max-tokens", "560"]
        }
        arguments += [
            "--embeddings", "--pooling", "mean",
            "--ctx-size", "\(config.context)", "--parallel", "\(config.parallel)",
            "--batch-size", "\(config.batch)", "--ubatch-size", "\(config.batch)",
            "--n-gpu-layers", "999",
            "--host", "127.0.0.1", "--port", "\(port)",
            "--api-key-file", keyFile.path,
            "--no-webui",
            "--log-verbosity", "2",   // warnings and errors only: info logs a few lines per request
        ]
        if let threads = config.threads {
            arguments += ["--threads", "\(threads)", "--threads-http", "\(threads)"]
        }
        // Through `fam guard`, so the server stops when this process exits, even by a crash.
        if let guardTool = AppPaths.sfsTool {
            process.executableURL = guardTool
            process.arguments = ["guard", "\(getpid())", binary.path] + arguments
        } else {
            process.executableURL = binary
            process.arguments = arguments
        }
        let log = AppPaths.logs.appendingPathComponent("\(config.name).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .utility
        try process.run()
        self.process = process
        try? "\(process.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        // Loading takes a few seconds (Metal compiles its shaders on the first run).
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            guard process.isRunning else {
                let tail = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
                self.process = nil
                throw EmbeddingError.serverDidNotStart(tail)
            }
            if await healthy() {
                ready = true
                lastUse = Date()
                scheduleIdleStop()
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stop()
        throw EmbeddingError.serverDidNotStart("it took longer than two minutes to load")
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard idleTimeout != nil else { return }   // kept loaded
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                if await self.idleExpired() { await self.stop(); return }
            }
        }
    }

    private func idleExpired() -> Bool {
        guard let idleTimeout else { return false }
        return Date().timeIntervalSince(lastUse) > idleTimeout
    }

    private func request(_ inputs: [EmbeddingInput]) async throws -> [[Float]] {
        var items: [Any] = []
        for input in inputs {
            switch input {
            case .text(let text):
                items.append(text)
            case .image(let data, let mime):
                items.append(["content": [["type": "image_url",
                                           "image_url": ["url": "data:\(mime);base64,\(data.base64EncodedString())"]]]])
            case .audio(let data):
                items.append(["content": [["type": "input_audio",
                                           "input_audio": ["data": data.base64EncodedString(), "format": "wav"]]]])
            }
        }
        let body: [String: Any] = ["input": items, "encoding_format": "base64"]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/embeddings")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw EmbeddingError.badResponse("HTTP \(status): \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]], rows.count == inputs.count else {
            throw EmbeddingError.badResponse("wrong number of vectors")
        }
        var out = [[Float]](repeating: [], count: inputs.count)
        for row in rows {
            guard let index = row["index"] as? Int, index < out.count else { continue }
            if let encoded = row["embedding"] as? String, let raw = Data(base64Encoded: encoded) {
                out[index] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else if let floats = row["embedding"] as? [Double] {
                out[index] = floats.map { Float($0) }
            }
        }
        guard out.allSatisfy({ $0.count == Self.dimension }) else {
            throw EmbeddingError.badResponse("vectors aren't \(Self.dimension)-dimensional")
        }
        return out
    }

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        LogFile.append(line, to: "engine.log")
        if ProcessInfo.processInfo.environment["FAMILIAR_DEBUG"] != nil {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    /// Servers left behind by an owner that's gone (older versions, or a guard that couldn't run) would hold up to a
    /// few GB: stop them. A server whose owner is still running is left alone: it's another copy's (the app's while
    /// the CLI runs, or the other way round).
    static func killStaleServers(named name: String) {
        let folder = AppPaths.applicationSupport
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where file.hasPrefix(name) && file.hasSuffix(".pid") {
            let middle = file.dropFirst(name.count).dropLast(4)   // "-<owner>", or "" in the old single-file format
            if middle.hasPrefix("-"), let owner = pid_t(middle.dropFirst()) {
                if owner == getpid() || kill(owner, 0) == 0 || errno == EPERM { continue }   // owner still running
            } else if !middle.isEmpty {
                continue   // another server's file ("llama-server-search-…")
            }
            killStale(pidFile: folder.appendingPathComponent(file))
        }
    }

    private static func killStale(pidFile: URL) {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text) else {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        if (try? ps.run()) != nil {
            ps.waitUntilExit()
            let name = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let command = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.hasSuffix("llama-server") || command.hasSuffix("/fam") || command == "fam" { kill(pid, SIGTERM) }
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        return port > 0 ? port : 18_765
    }
}

/// EmbeddingGemma 2's task prompts (model card). Media inputs take none.
public enum Prompts {
    public static func query(_ text: String) -> String { "task: search result | query: \(text)" }

    public static func document(title: String?, text: String) -> String {
        let title = (title?.isEmpty ?? true) ? "none" : title!
        return "title: \(title) | text: \(text)"
    }
}
