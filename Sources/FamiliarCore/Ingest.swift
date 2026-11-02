import CoreGraphics
import Foundation

public struct IndexProgress: Sendable {
    public enum Phase: String, Sendable { case idle, scanning, indexing, paused, done, failed }
    public var phase: Phase = .idle
    public var total = 0
    public var done = 0
    public var failed = 0
    public var current: String?
    public var message: String?
    /// Folders macOS didn't allow Familiar to open during the last full scan (nil after a scan of changes only).
    public var denied: [String]?
    /// A few new or changed files: read at full speed even while power or heat holds indexing back.
    public var urgent = false
    /// Files this pass reads per chosen folder or file, and how many it has read.
    public var rootTotals: [String: Int] = [:]
    public var rootDone: [String: Int] = [:]
    public var startedAt: Date?

    public init() {}
}

/// Brings the index up to date with the chosen folders: reads new and changed files, embeds their pieces and stores
/// them; forgets files that are gone. Only reads files, never changes them.
public actor Ingestor {
    private let db: Catalog
    private let embedder: EmbeddingService
    private var progress = IndexProgress()
    /// Paused by hand: nothing is read.
    private var userPaused = false
    /// Paused by power or heat (battery setting, Low Power Mode, a very hot Mac): only urgent passes are read.
    private var powerPaused = false
    /// Slow pace (on battery, a hot Mac): one file at a time, resting twice as long as each file took, so the GPU
    /// works about a third of the time. Urgent passes ignore it.
    private var slow = false
    /// This pass is a few new files (`urgentLimit` or fewer from the folder watcher): they're read right away.
    private var urgent = false
    private var rootOf: [String: String] = [:]
    public static let urgentLimit = 50
    private var holding: Bool { userPaused || (powerPaused && !urgent) }
    private var pacedSlow: Bool { slow && !urgent }
    private var active = 0
    private let onProgress: @Sendable (IndexProgress) -> Void
    /// How files are read. When it goes up, the kinds that version changed are read again once, even if unchanged.
    public static let readerVersion = 4
    /// What each version changed. 2: OCR on every picture (not only screenshots), without language correction.
    /// 3: sound in 10 s windows every 5 s instead of 30 s every 25 s (chosen with fam eval).
    /// 4: transcripts from Parakeet Unified (English, with punctuation) instead of TDT v3.
    static let rereadKinds: [Int: Set<FileKind>] = [2: [.image, .pdf], 3: [.audio, .video], 4: [.audio, .video]]

    /// Files read at once: each one keeps the model busy while the next is being read.
    private let workers = 3

    public init(db: Catalog, embedder: EmbeddingService = .shared,
                onProgress: @escaping @Sendable (IndexProgress) -> Void = { _ in }) {
        self.db = db
        self.embedder = embedder
        self.onProgress = onProgress
    }

    /// What may run: paused by hand, paused by power or heat, slow. New files (urgent passes) ignore the last two.
    public func setPace(userPaused: Bool, powerPaused: Bool, slow: Bool) {
        self.userPaused = userPaused
        self.powerPaused = powerPaused
        self.slow = slow
        if progress.phase == .indexing || progress.phase == .paused {
            progress.phase = holding ? .paused : .indexing
            onProgress(progress)
        }
    }

    public func setPaused(_ value: Bool) { setPace(userPaused: value, powerPaused: powerPaused, slow: slow) }

    public var isPaused: Bool { holding }

    public func setSlow(_ value: Bool) { slow = value }

    /// One pass over `roots`, or, with `changes`, over only those paths (from the folder watcher). Cancel the calling
    /// task to stop it; what's done so far stays in the index.
    public func run(roots: [URL], excluded: [URL] = [], changes: [String]? = nil) async {
        progress = IndexProgress()
        urgent = false
        progress.phase = .scanning
        progress.startedAt = Date()
        onProgress(progress)

        let candidates: [Candidate]
        var scopes: [String]?   // a scan of changes speaks only for these paths
        if let changes {
            let scan = FolderScanner.scanChanges(changes, roots: roots, excluded: excluded)
            candidates = scan.candidates
            scopes = scan.scopes
        } else {
            let scan = FolderScanner.scanReporting(roots: roots, excluded: excluded, isCancelled: { Task.isCancelled })
            candidates = scan.candidates
            progress.denied = scan.denied.map(\.path)
        }
        guard !Task.isCancelled else { return finish(.idle) }

        let states: [String: FileState]
        do { states = try db.fileStates() } catch { return fail(error) }

        // Forget files that are gone or no longer in a chosen folder (but not those on a disk that isn't plugged in).
        let present = Set(candidates.map { $0.url.path })
        // A root is a folder (its files are under it) or a file (the path itself).
        func within(_ path: String, _ root: URL) -> Bool { path == root.path || path.hasPrefix(root.path + "/") }
        let mountedRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        let gone = states.keys.filter { path in
            guard !present.contains(path) else { return false }
            if let scopes { return scopes.contains { path == $0 || path.hasPrefix($0 + "/") } }
            let inRoot = roots.contains { within(path, $0) }
            return !inRoot || mountedRoots.contains { within(path, $0) }
        }
        try? db.removeFiles(paths: gone)

        let indexedWith = Int(db.meta("readerVersion") ?? "1") ?? 1
        var reread = Self.rereadKinds.filter { $0.key > indexedWith }.reduce(into: Set<FileKind>()) { $0.formUnion($1.value) }
        // Transcripts: when transcribing has just been turned on (or its model just arrived), or the recordings were
        // transcribed with another model, recordings and videos are read again once. The mark names the model they were
        // transcribed with ("1" was Parakeet's, before the mark named it). While it's off, new ones are read without,
        // so the mark comes off.
        let transcribing = Transcriber.isReady
        let speechIndexed = db.meta("speechIndexed").map { $0 == "1" ? Transcriber.choice : $0 }
        if transcribing && speechIndexed != Transcriber.choice { reread.formUnion([.audio, .video]) }
        if !transcribing && speechIndexed != nil && speechIndexed != "0" { try? db.setMeta("speechIndexed", "0") }
        let todo = candidates.filter { candidate in
            guard let state = states[candidate.url.path] else { return true }
            if reread.contains(candidate.kind) { return true }
            return state.size != candidate.size || abs(state.mtime - candidate.mtime) > 0.001
        }.sorted { a, b in
            a.kind.order != b.kind.order ? a.kind.order < b.kind.order : a.mtime > b.mtime
        }

        urgent = changes != nil && todo.count <= Self.urgentLimit
        progress.urgent = urgent
        // Per chosen folder or file: how much this pass reads in it (Settings shows each one's progress).
        rootOf = [:]
        for candidate in todo {
            if let root = roots.first(where: { within(candidate.url.path, $0) }) {
                rootOf[candidate.url.path] = root.path
                progress.rootTotals[root.path, default: 0] += 1
            }
        }
        progress.phase = holding ? .paused : .indexing
        progress.total = todo.count
        onProgress(progress)
        guard !todo.isEmpty else {
            try? db.setMeta("readerVersion", "\(Self.readerVersion)")
            if transcribing && changes == nil { try? db.setMeta("speechIndexed", Transcriber.choice) }
            return finish(.done)
        }

        var fatal: Error?
        await withTaskGroup(of: Error?.self) { group in
            var next = 0
            func startNext() -> Bool {
                guard next < todo.count else { return false }
                let candidate = todo[next]
                next += 1
                group.addTask { await self.process(candidate) }
                return true
            }
            for _ in 0..<workers { _ = startNext() }
            while let error = await group.next() {
                if let error, fatal == nil {
                    fatal = error
                    group.cancelAll()
                }
                if fatal == nil && !Task.isCancelled { _ = startNext() }
            }
        }
        if let fatal { return fail(fatal) }
        if !Task.isCancelled {
            try? db.setMeta("readerVersion", "\(Self.readerVersion)")
            // Only a full pass covers every recording; a pass over a few changed files says nothing about the rest.
            if transcribing && changes == nil { try? db.setMeta("speechIndexed", Transcriber.choice) }
        }
        finish(Task.isCancelled ? .idle : .done)
    }

    private func finish(_ phase: IndexProgress.Phase) {
        progress.phase = phase
        progress.current = nil
        onProgress(progress)
    }

    private func fail(_ error: Error) {
        progress.phase = .failed
        progress.message = error.localizedDescription
        progress.current = nil
        onProgress(progress)
    }

    private func waitWhilePaused() async {
        while holding && !Task.isCancelled { try? await Task.sleep(nanoseconds: 300_000_000) }
    }

    /// Reads and stores one file. Returns an error only when the model itself can't run (then the pass stops);
    /// a file that can't be read is recorded with its reason and skipped until it changes.
    private func process(_ candidate: Candidate) async -> Error? {
        await waitWhilePaused()
        // At the slow pace only one file is read at a time.
        while pacedSlow && active >= 1 && !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard !Task.isCancelled else { return nil }
        active += 1
        let started = Date()
        defer { active -= 1 }
        progress.current = candidate.url.lastPathComponent
        onProgress(progress)

        var segments: [SegmentRow] = []
        var keywords: [KeywordRow] = []
        var failure: String?
        do {
            (segments, keywords) = try await read(candidate)
        } catch let error as EmbeddingError {
            switch error {
            case .badResponse(let why): failure = why
            default: return error
            }
        } catch {
            failure = error.localizedDescription
        }
        guard !Task.isCancelled else { return nil }
        do {
            try db.replaceFile(path: candidate.url.path, kind: candidate.kind.rawValue, size: candidate.size,
                               mtime: candidate.mtime, segments: segments, keywords: keywords, error: failure)
        } catch {
            return error
        }
        progress.done += 1
        if let root = rootOf[candidate.url.path] { progress.rootDone[root, default: 0] += 1 }
        if failure != nil { progress.failed += 1 }
        onProgress(progress)
        if pacedSlow {
            let rest = min(Date().timeIntervalSince(started) * 2, 20)
            try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))
        }
        return nil
    }

    // MARK: - Readers

    /// What a file holds, checked for keys and passwords before anything of it is stored. Every reader's text ends up
    /// in its keyword rows (chunks, page and slide text, a picture's text, a transcript), and snippets and embedded
    /// text are cut from the same strings, so one check of the rows covers them all, readers added later included.
    /// Text and documents are also checked before they're embedded, which saves the work.
    private func read(_ candidate: Candidate) async throws -> ([SegmentRow], [KeywordRow]) {
        let (segments, keywords) = try await readContents(candidate)
        if keywords.contains(where: { Privacy.holdsSecret($0.text) }) { throw ReadError.unreadable(Self.secretSkipped) }
        return (segments, keywords)
    }

    static let secretSkipped = "skipped: it holds a key or password"

    private func readContents(_ candidate: Candidate) async throws -> ([SegmentRow], [KeywordRow]) {
        let url = candidate.url
        let title = url.deletingPathExtension().lastPathComponent
        switch candidate.kind {
        case .text:
            return try await text(skippingSecrets(TextReader.read(url)), title: title, kind: .text)
        case .document:
            return try await text(skippingSecrets(DocumentReader.read(url)), title: title, kind: .text)
        case .office:
            var segments: [SegmentRow] = [], keywords: [KeywordRow] = []
            for piece in try OfficeReader.read(url) {
                let (s, k) = try await text(piece.text, title: title, kind: .page, locator: piece.locator)
                segments += s; keywords += k
            }
            return (segments, keywords)
        case .pdf:
            return try await pdf(url, title: title)
        case .image:
            return try await image(url, title: title)
        case .audio:
            return try await audio(url, title: title)
        case .video:
            let duration = await MediaReader.duration(url)
            let frames = await MediaReader.frames(url, duration: duration, budget: ImageBudgets.current.frame)
            let vectors = try await embedAll(frames.map { .image($0.jpeg, mime: ImagePrep.mime) })
            var segments = zip(frames, vectors).compactMap { frame, vector in
                vector.map { SegmentRow(kind: .frame, locator: frame.time, snippet: nil, vector: $0) }
            }
            let (sound, transcript) = try await audio(url, title: title)
            return (segments + sound, transcript)
        }
    }

    /// Text that holds a private key or an access key is never stored: the file is recorded as skipped instead.
    private func skippingSecrets(_ text: String) throws -> String {
        if Privacy.holdsSecret(text) { throw ReadError.unreadable(Self.secretSkipped) }
        return text
    }

    /// Text in chunks: each chunk embedded with its file's title, and kept whole for exact-word search. With
    /// `locator`, every chunk points there (a PDF page, a slide); otherwise at its character offset.
    private func text(_ text: String, title: String, kind: SegmentKind, locator: Double? = nil)
        async throws -> ([SegmentRow], [KeywordRow]) {
        let chunks = TextReader.chunks(text)
        let keywords = chunks.map { KeywordRow(text: $0.0, locator: locator ?? Double($0.1), kind: kind) }
        if TextReader.isMostlyNumbers(text) { return ([], keywords) }
        let vectors = try await embedAll(chunks.map { .text(Prompts.document(title: title, text: $0.0)) })
        var segments: [SegmentRow] = []
        for (chunk, vector) in zip(chunks, vectors) {
            let at = locator ?? Double(chunk.1)
            if let vector {
                segments.append(SegmentRow(kind: kind, locator: at, snippet: snippet(chunk.0), vector: vector))
                continue
            }
            // Refused: most likely more tokens than a slot holds (Chinese or Japanese text, where a character can be
            // a token or more). Each half on its own.
            let half = chunk.0.index(chunk.0.startIndex, offsetBy: chunk.0.count / 2)
            let halves = [String(chunk.0[..<half]), String(chunk.0[half...])].filter { $0.count > 3 }
            let retried = try await embedAll(halves.map { .text(Prompts.document(title: title, text: $0)) })
            for (piece, vector) in zip(halves, retried) {
                if let vector { segments.append(SegmentRow(kind: kind, locator: at, snippet: snippet(piece), vector: vector)) }
            }
        }
        return (segments, keywords)
    }

    private func pdf(_ url: URL, title: String) async throws -> ([SegmentRow], [KeywordRow]) {
        let (pages, pdfTitle) = try PDFReader.read(url)
        let title = pdfTitle ?? title
        var segments: [SegmentRow] = [], keywords: [KeywordRow] = []
        var texts: [(String, Double)] = []
        var images: [(Data, Double)] = []
        for page in pages {
            if let image = page.image {
                images.append((image, Double(page.index)))
                if let ocr = page.ocr {
                    keywords.append(KeywordRow(text: ocr, locator: Double(page.index), kind: .page))
                    if ocr.count > 80 { texts.append((ocr, Double(page.index))) }
                }
            } else {
                for chunk in TextReader.chunks(page.text, limit: 8) { texts.append((chunk.0, Double(page.index))) }
                keywords.append(KeywordRow(text: page.text, locator: Double(page.index), kind: .page))
            }
        }
        let textVectors = try await embedAll(texts.map { .text(Prompts.document(title: title, text: $0.0)) })
        for (piece, vector) in zip(texts, textVectors) {
            if let vector { segments.append(SegmentRow(kind: .page, locator: piece.1, snippet: snippet(piece.0), vector: vector)) }
        }
        let imageVectors = try await embedAll(images.map { .image($0.0, mime: ImagePrep.mime) })
        for (piece, vector) in zip(images, imageVectors) {
            if let vector { segments.append(SegmentRow(kind: .pageImage, locator: piece.1, snippet: nil, vector: vector)) }
        }
        return (segments, keywords)
    }

    private func image(_ url: URL, title: String) async throws -> ([SegmentRow], [KeywordRow]) {
        guard let image = ImagePrep.load(url, maxSide: ImagePrep.loadSide) else { throw ReadError.unreadable("not a readable picture") }
        guard image.width >= 48, image.height >= 48 else { return ([], []) }   // icons and spacers
        let budgets = ImageBudgets.current
        let budget = ImagePrep.isScreenshot(url) ? budgets.screenshot : budgets.photo
        guard let jpeg = ImagePrep.encode(image, budget: budget) else {
            throw ReadError.unreadable("can't resize it")
        }
        var inputs: [EmbeddingInput] = [.image(jpeg, mime: ImagePrep.mime)]
        var keywords: [KeywordRow] = []
        var ocr: String?
        // Every picture's text is read: screenshots, and photos or scans of cards, certificates and receipts, whose
        // numbers only an exact-word search can find.
        if let text = TextRecognizer.recognize(image) {
            ocr = text
            keywords.append(KeywordRow(text: text, locator: 0, kind: .image))
            if text.count > 80 { inputs.append(.text(Prompts.document(title: title, text: String(text.prefix(1400))))) }
        }
        let vectors = try await embedAll(inputs)
        var segments: [SegmentRow] = []
        if let v = vectors[0] { segments.append(SegmentRow(kind: .image, locator: 0, snippet: nil, vector: v)) }
        if vectors.count > 1, let v = vectors[1] {
            segments.append(SegmentRow(kind: .image, locator: 0, snippet: ocr.map(snippet), vector: v))
        }
        return (segments, keywords)
    }

    /// The sound in overlapping windows, and, when transcribing is on, what's said: each sentence kept for Ask and
    /// exact-word search, and stretches of up to 12 s embedded as text, so a search matches the words as well as the
    /// sound. Short stretches point at the right moment: at 30 s, a topic starting mid-stretch was placed at the
    /// stretch's start (3 wrong moments in fam eval). A transcript that fails leaves the sound alone.
    private func audio(_ url: URL, title: String) async throws -> ([SegmentRow], [KeywordRow]) {
        let windows = try await MediaReader.audioWindows(url)
        let vectors = try await embedAll(windows.map { .audio($0.wav) }, batch: 4)
        var segments = zip(windows, vectors).compactMap { window, vector in
            vector.map { SegmentRow(kind: .audio, locator: window.start, snippet: nil, vector: $0) }
        }
        guard Transcriber.isReady, !windows.isEmpty else { return (segments, []) }
        let lines: [Transcriber.Line]
        do { lines = try await Transcriber.transcribe(url) } catch {
            EmbeddingService.log("transcript of \(url.lastPathComponent) failed: \(error.localizedDescription)")
            return (segments, [])
        }
        let keywords = lines.map { KeywordRow(text: $0.text, locator: $0.start, kind: .audio) }
        var stretches: [(start: Double, text: String)] = []
        for line in lines {
            if let last = stretches.last, line.start - last.start < 12, last.text.count + line.text.count < 400 {
                stretches[stretches.count - 1].text += " " + line.text
            } else {
                stretches.append((line.start, line.text))
            }
        }
        let textVectors = try await embedAll(stretches.map { .text(Prompts.document(title: title, text: $0.text)) })
        for (stretch, vector) in zip(stretches, textVectors) {
            if let vector { segments.append(SegmentRow(kind: .audio, locator: stretch.start, snippet: snippet(stretch.text), vector: vector)) }
        }
        return (segments, keywords)
    }

    private func embedAll(_ inputs: [EmbeddingInput], batch: Int = 8) async throws -> [[Float]?] {
        var out: [[Float]?] = []
        out.reserveCapacity(inputs.count)
        var start = 0
        while start < inputs.count {
            await waitWhilePaused()
            if Task.isCancelled { throw CancellationError() }
            let end = min(start + batch, inputs.count)
            out += try await embedder.embed(Array(inputs[start..<end]))
            start = end
        }
        return out
    }

    private func snippet(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(flat.prefix(320))
    }
}
