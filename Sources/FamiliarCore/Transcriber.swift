import Foundation

/// Speech to text for meetings, recordings and videos: Parakeet Unified 0.6B (English, with punctuation and capitals)
/// on the Neural Engine, run by the bundled `familiar-speech` helper (FluidAudio needs macOS 14, so it's a separate
/// program, like llama-server). A transcript makes a recording readable: Ask can quote it, and its words are found by
/// exact-word search. English only for now.
public enum Transcriber {
    public struct Line: Codable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
        public let speaker: String?
        public init(start: Double, end: Double, text: String, speaker: String?) {
            self.start = start; self.end = end; self.text = text; self.speaker = speaker
        }
    }

    private struct Run: Decodable { let sentences: [Line] }

    /// The helper is there and this Mac runs macOS 14 or later.
    public static var isSupported: Bool {
        guard #available(macOS 14, *) else { return false }
        return AppPaths.transcriber != nil
    }

    /// Settings → Ask → "Transcribe recordings". `FAMILIAR_TRANSCRIBE=1` turns it on for the CLI and tests.
    public static var enabled: Bool {
        get {
            if let env = ProcessInfo.processInfo.environment["FAMILIAR_TRANSCRIBE"] { return env == "1" }
            return SettingsStore.defaults.bool(forKey: "transcribeSpeech")
        }
        set { SettingsStore.defaults.set(newValue, forKey: "transcribeSpeech") }
    }

    /// The speech model, as the ready marker and the index name it (the helper's default).
    public static let choice = "parakeet-unified-en"

    /// What the helper is told: where the models are.
    static var modelArguments: [String] { ["--models", modelsFolder.path] }

    public static var modelsFolder: URL { AppPaths.models.appendingPathComponent("Speech", isDirectory: true) }
    private static var readyMarker: URL { modelsFolder.appendingPathComponent("ready") }
    /// The model (~1.2 GB: its streaming and whole-clip encoders) is downloaded and compiled for this Mac: the marker names the current model (a Mac set up
    /// with the earlier TDT v3 model prepares again), and every pinned file is still there.
    public static var isPrepared: Bool {
        let marker = (try? String(contentsOf: readyMarker, encoding: .utf8)) ?? ""
        return marker.split(separator: "\n").contains { $0 == choice } && SpeechModelFiles.all.allSatisfy(\.isInstalled)
    }

    /// Speech files from before they were pinned (fetched by FluidAudio itself) are checked once against their
    /// SHA-256 in the background; any that differ are removed, so the next use downloads the pinned ones.
    public static func verifyOnce() {
        let marker = modelsFolder.appendingPathComponent("verified")
        guard FileManager.default.fileExists(atPath: readyMarker.path), !FileManager.default.fileExists(atPath: marker.path) else { return }
        SpeechModelFiles.removeUnverified()
        FileManager.default.createFile(atPath: marker.path, contents: Data(SpeechModelFiles.diarizerRevision.utf8))
    }
    /// Recordings get transcripts while they're indexed.
    public static var isReady: Bool { isSupported && enabled && isPrepared }

    public enum Failure: LocalizedError {
        case unsupported, failed(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported: return "Transcribing needs macOS 14 or later."
            case .failed(let why): return "The speech model didn't run: \(why)"
            }
        }
    }

    /// Downloads the pinned model files (checked against their SHA-256), then has the helper load them once, which
    /// compiles them for this Mac. Progress 0–0.9 is the download, the rest the compile. The earlier TDT v3 model, if
    /// it's there, is removed afterwards (0.5 GB).
    public static func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard isSupported, let helper = AppPaths.transcriber else { throw Failure.unsupported }
        try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        SpeechModelFiles.removeUnverified()
        let downloader = ModelDownloader(files: SpeechModelFiles.all)
        downloader.onProgress = { done, total in progress(0.9 * Double(done) / Double(max(total, 1))) }
        try await downloader.run()
        SpeechModelFiles.markRevision()
        // The files are all there, so FluidAudio finds them and doesn't go online.
        let (status, _, errors) = try await run(helper, ["--prepare"] + modelArguments) { line in
            if line.hasPrefix("progress "), let value = Double(line.dropFirst(9)) { progress(0.9 + 0.1 * value) }
        }
        guard status == 0 else { throw Failure.failed(String(errors.suffix(300))) }
        FileManager.default.createFile(atPath: readyMarker.path, contents: Data((choice + "\n").utf8))
        for old in ["parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v3-coreml"] {
            try? FileManager.default.removeItem(at: modelsFolder.appendingPathComponent(old))
        }
    }

    /// The file's speech as timed sentences (empty when it has none).
    public static func transcribe(_ url: URL) async throws -> [Line] {
        guard isSupported, let helper = AppPaths.transcriber else { throw Failure.unsupported }
        let (status, output, errors) = try await run(helper, [url.path, "--json"] + modelArguments)
        if status != 0 {
            if errors.contains("no sound") { return [] }
            throw Failure.failed(String(errors.suffix(300)))
        }
        return try JSONDecoder().decode(Run.self, from: output).sentences
    }

    /// Runs the helper, collecting its output; `onLine` sees each line it writes to stderr as it comes.
    private static func run(_ helper: URL, _ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil)
        async throws -> (Int32, Data, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = helper
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.qualityOfService = .utility
                let errors = LockedText()
                err.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = String(decoding: handle.availableData, as: UTF8.self)
                    errors.append(chunk)
                    if let onLine { chunk.split(separator: "\n").forEach { onLine(String($0)) } }
                }
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()   // read while it runs: a full pipe would stall it
                process.waitUntilExit()
                err.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (process.terminationStatus, data, errors.value))
            }
        }
    }

    private final class LockedText: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ more: String) { lock.lock(); text += more; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }
}

/// The speech helper kept running (`familiar-speech --serve`) for a meeting. Each track's sound is streamed to it as
/// it's recorded, and what's heard comes back about a second later: finished sentences and the one still being
/// spoken (`onLive`). At the end, each track is finished (its last words), and whole files can be transcribed or
/// labelled by speaker without loading the model again. Requests are matched to replies by id; the sound goes out on
/// one queue in order, so a track's finish always comes after its last sound.
public actor TranscriberSession {
    /// A track's newly finished sentences and its sentence in progress (empty when nobody is speaking).
    public typealias Live = @Sendable (_ track: String, _ lines: [Transcriber.Line], _ partial: String) -> Void

    private var process: Process?
    private var input: FileHandle?
    private var starting: Task<Void, Error>?
    private let writes = DispatchQueue(label: "Familiar.transcriber.writes", qos: .userInitiated)
    private var waiting: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var nextID = 1
    private let onLive: Live?

    public init(onLive: Live? = nil) { self.onLive = onLive }

    private struct Reply: Decodable {
        let id: Int?; let track: String?; let lines: [Transcriber.Line]?; let partial: String?; let done: Bool?
        let sentences: [Transcriber.Line]?; let error: String?; let ready: Bool?
    }
    private struct Request: Encodable {
        let cmd: String; var id: Int?; var track: String?; var pcm: String?; var on: Bool?
        var path: String?; var speakers: Bool?; var lines: [Transcriber.Line]?
    }

    public func start() async throws {
        if process != nil { return }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        guard Transcriber.isSupported, let helper = AppPaths.transcriber else { throw Transcriber.Failure.unsupported }
        signal(SIGPIPE, SIG_IGN)   // a helper that died mid-write must not take the app with it
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--serve"] + Transcriber.modelArguments
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        try process.run()
        let reader = LineReader(outPipe.fileHandleForReading)
        let first = await Task.detached { reader.next() }.value
        guard let first, (try? JSONDecoder().decode(Reply.self, from: Data(first.utf8)))?.ready == true else {
            process.terminate()
            throw Transcriber.Failure.failed("the speech model didn't load")
        }
        self.process = process
        input = inPipe.fileHandleForWriting
        Task.detached { [weak self] in
            while let line = reader.next() { await self?.received(line) }
            await self?.ended()
        }
    }

    private func received(_ line: String) {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(line.utf8)) else { return }
        if let id = reply.id, let waiter = waiting.removeValue(forKey: id) {
            waiter.resume(returning: reply)
        } else if let track = reply.track, reply.error == nil {
            onLive?(track, reply.lines ?? [], reply.partial ?? "")
        }
    }

    private func ended() {
        for waiter in waiting.values { waiter.resume(throwing: Transcriber.Failure.failed("the speech helper stopped")) }
        waiting = [:]
        process = nil; input = nil
    }

    private func write(_ request: Request) {
        guard let input, let data = try? JSONEncoder().encode(request) else { return }
        writes.async { try? input.write(contentsOf: data + Data("\n".utf8)) }
    }

    /// The meeting records the call's sound too ("others"): the microphone is cleaned of it before it's transcribed,
    /// so a call heard through the speakers isn't written down as yours. Call before streaming.
    public func cancelEcho() async throws {
        try await start()
        write(Request(cmd: "echo", on: true))
    }

    /// More of a track's sound (16 kHz mono); what's heard arrives through `onLive`.
    public func stream(_ track: String, samples: [Float]) {
        guard !samples.isEmpty else { return }
        var ints = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        let pcm = Data(bytes: &ints, count: ints.count * 2).base64EncodedString()
        write(Request(cmd: "audio", track: track, pcm: pcm))
    }

    private func ask(_ request: Request) async throws -> Reply {
        try await start()
        var request = request
        let id = nextID
        nextID += 1
        request.id = id
        let reply: Reply = try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            write(request)
        }
        if let error = reply.error { throw Transcriber.Failure.failed(error) }
        return reply
    }

    /// A track's last words, once its sound has ended (the track can then start again from nothing).
    public func finish(_ track: String) async throws -> [Transcriber.Line] {
        try await ask(Request(cmd: "finish", track: track)).lines ?? []
    }

    /// A finished track read again as one clip, every word heard with what came before and after it: more accurate
    /// than the streamed lines, which these replace. Throws when the whole-clip model isn't installed.
    public func whole(_ track: String) async throws -> [Transcriber.Line] {
        try await ask(Request(cmd: "whole", track: track)).sentences ?? []
    }

    /// The speech in an audio file, as timed sentences; `speakers` labels who spoke (S1, S2…).
    public func transcribe(_ url: URL, speakers: Bool = false) async throws -> [Transcriber.Line] {
        try await ask(Request(cmd: "file", path: url.path, speakers: speakers)).sentences ?? []
    }

    /// The same lines with who said each one, from the file's sound.
    public func label(_ url: URL, lines: [Transcriber.Line]) async throws -> [Transcriber.Line] {
        try await ask(Request(cmd: "label", path: url.path, lines: lines)).sentences ?? lines
    }

    public func stop() {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil
    }
}

/// Lines from a pipe, read as they come (blocking: call it off the main thread).
final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    init(_ handle: FileHandle) { self.handle = handle }

    func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
