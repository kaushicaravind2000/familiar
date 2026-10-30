import Darwin
import Foundation

public enum ChatError: LocalizedError {
    case modelMissing
    case serverDidNotStart(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing: return "The answer model isn't downloaded yet. Get it in Settings → Ask."
        case .serverDidNotStart(let why): return "The answer model didn't start: \(why)"
        case .badResponse(let why): return "The answer model answered unexpectedly: \(why)"
        }
    }
}

public struct ChatMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(_ role: Role, _ content: String) { self.role = role; self.content = content }
}

/// The model that writes answers (Qwen3.5-4B) in its own llama-server, the third one beside the indexing and search
/// servers. It starts on the first question and stops after five idle minutes (one in the Low profile), so its ~3.3 GB
/// is only held while you're asking. Thinking is off: in the bake-off it took 5–42 s per answer instead of 0.5 s, and
/// sometimes thought until it ran out of room and answered nothing.
public actor ChatService {
    public static let shared = ChatService()

    private let name = "llama-server-chat"
    private var process: Process?
    private var ready = false
    private var port = 0
    private var apiKey = ""
    private var lastUse = Date()
    private var busy = 0
    private var idleTask: Task<Void, Never>?
    private var starting: Task<Void, Error>?
    private let session: URLSession

    /// Two slots, each with its own context: one plans follow-ups, one writes answers. The planning prompt (its rules
    /// and worked examples, ~550 tokens) stays cached in its slot, so a follow-up's plan reads only the new part: 0.30 s
    /// instead of 0.64 s, measured. With one slot, every answer pushed it out. Per slot: question + passages + answer
    /// in 8,192 tokens (Low: 4,096).
    public enum Slot: Int, Sendable { case planning = 0, answer = 1 }
    private var context: Int { (MemoryProfile.current == .low ? 4096 : 8192) * 2 }
    private var idleTimeout: TimeInterval { MemoryProfile.current == .low ? 60 : 300 }

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        session = URLSession(configuration: configuration)
    }

    public var isRunning: Bool { ready && (process?.isRunning ?? false) }

    /// Streams the answer's text as it's written. Cancel the consuming task to stop it. With `jsonSchema`, the
    /// server's grammar only lets the model write JSON of that shape.
    public func stream(_ messages: [ChatMessage], maxTokens: Int = 700, jsonSchema: String? = nil,
                       slot: Slot = .answer) async throws -> AsyncThrowingStream<String, Error> {
        try await ensureRunning()
        lastUse = Date()
        busy += 1
        var body: [String: Any] = [
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true, "temperature": 0, "max_tokens": maxTokens,
            "chat_template_kwargs": ["enable_thinking": false],
            "id_slot": slot.rawValue, "cache_prompt": true,
        ]
        if let jsonSchema, let schema = try? JSONSerialization.jsonObject(with: Data(jsonSchema.utf8)) {
            body["response_format"] = ["type": "json_schema", "json_schema": ["schema": schema]]
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { Task { await self.finishedRequest() } }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw ChatError.badResponse("HTTP \(status)") }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]] else { continue }
                        for choice in choices {
                            if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Writes the whole answer and returns it (the CLI, tests).
    public func complete(_ messages: [ChatMessage], maxTokens: Int = 700, jsonSchema: String? = nil,
                         slot: Slot = .answer) async throws -> String {
        var out = ""
        for try await piece in try await stream(messages, maxTokens: maxTokens, jsonSchema: jsonSchema, slot: slot) { out += piece }
        return out
    }

    private func finishedRequest() {
        busy -= 1
        lastUse = Date()
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

    public func ensureRunning() async throws {
        if ready, let process, process.isRunning { return }
        if let starting { return try await starting.value }
        ready = false
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private var pidFile: URL { AppPaths.applicationSupport.appendingPathComponent("\(name)-\(getpid()).pid") }

    private func start() async throws {
        guard let binary = AppPaths.llamaServer else { throw EmbeddingError.noServerBinary }
        guard ChatModelFiles.isInstalled else { throw ChatError.modelMissing }
        EmbeddingService.killStaleServers(named: name)

        port = EmbeddingService.freePort()
        apiKey = (0..<4).map { _ in String(UInt64.random(in: .min ... .max), radix: 16) }.joined()
        let keyFile = AppPaths.applicationSupport.appendingPathComponent("\(name).key")
        try? FileManager.default.removeItem(at: keyFile)
        guard FileManager.default.createFile(atPath: keyFile.path, contents: Data(apiKey.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ChatError.serverDidNotStart("can't write its password file")
        }
        defer { try? FileManager.default.removeItem(at: keyFile) }
        let arguments = [
            "--model", ChatModelFiles.path.path,
            "--ctx-size", "\(context)", "--parallel", "2",
            "--n-gpu-layers", "999", "--flash-attn", "on", "--jinja",
            // llama-server keeps up to 8 GB of old prompts in RAM by default; Ask never reuses them.
            "--cache-ram", "0",
            "--host", "127.0.0.1", "--port", "\(port)",
            "--api-key-file", keyFile.path,
            "--no-webui", "--log-verbosity", "2",
        ]
        let process = Process()
        if let guardTool = AppPaths.sfsTool {
            process.executableURL = guardTool
            process.arguments = ["guard", "\(getpid())", binary.path] + arguments
        } else {
            process.executableURL = binary
            process.arguments = arguments
        }
        let log = AppPaths.logs.appendingPathComponent("\(name).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .userInitiated
        try process.run()
        self.process = process
        try? "\(process.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            guard process.isRunning else {
                let tail = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.suffix(600)) } ?? ""
                self.process = nil
                throw ChatError.serverDidNotStart(tail)
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
        throw ChatError.serverDidNotStart("it took longer than two minutes to load")
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                if await self.idleExpired() { await self.stop(); return }
            }
        }
    }

    private func idleExpired() -> Bool { busy == 0 && Date().timeIntervalSince(lastUse) > idleTimeout }
}
