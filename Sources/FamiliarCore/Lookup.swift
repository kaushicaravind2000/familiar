import Accelerate
import Foundation

public struct SearchResult: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let fileKind: FileKind
    public let score: Float
    /// What matched: a page, a moment, a passage.
    public let segmentKind: SegmentKind
    public let locator: Double
    public let snippet: String?
    public let exactMatch: Bool

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }

    /// "Page 4", "at 12:30", or nil when the whole file matched.
    public var place: String? {
        switch segmentKind {
        case .page, .pageImage:
            if fileKind == .office { return "Slide \(Int(locator) + 1)" }
            return locator >= 0 ? "Page \(Int(locator) + 1)" : nil
        case .audio, .frame: return "at \(Self.clock(locator))"
        case .text, .image: return nil
        }
    }

    /// The moment to open a recording or video at, in seconds.
    public var seconds: Double? { segmentKind == .audio || segmentKind == .frame ? locator : nil }
    /// The PDF page to open at (0-based).
    public var page: Int? { (segmentKind == .page || segmentKind == .pageImage) && fileKind == .pdf && locator >= 0 ? Int(locator) : nil }

    public static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

public enum KindFilter: String, CaseIterable, Sendable {
    case all = "All", documents = "Documents", pictures = "Pictures", recordings = "Audio", videos = "Videos"

    func allows(_ kind: FileKind) -> Bool {
        switch self {
        case .all: return true
        case .documents: return [.text, .document, .office, .pdf].contains(kind)
        case .pictures: return kind == .image
        case .recordings: return kind == .audio
        case .videos: return kind == .video
        }
    }
}

/// Finds files by meaning and by exact words. The query's vector is compared with every stored vector (one matrix
/// product on the CPU via Accelerate); the best piece of each file ranks the file, and files that also hold the
/// query's exact words move up.
public final class Lookup: @unchecked Sendable {
    private let db: Catalog
    private var queryEmbedder: EmbeddingService
    /// Guards the vectors below; `updateLock` lets one update run at a time.
    private let lock = NSLock()
    private let updateLock = NSLock()
    /// Where in the index's history these vectors are from; nil: load everything on the next search.
    private var loaded: Catalog.Position?
    /// The highest segment id in memory: the next update reads only rows above it. Segment ids only grow
    /// (AUTOINCREMENT), so `segmentIDs` stays sorted and new rows always come after it.
    private var lastSegmentID: Int64 = 0
    private var segmentIDs: [Int64] = []
    private var fileIDs: [Int64] = []
    /// The vectors, row after row: 32-bit floats, or, in compact mode, 8-bit integers with a scale per row (a quarter
    /// of the memory; the best candidates are rescored with their exact vectors from the index).
    private var matrix: [Float] = []
    private var quantized: [Int8] = []
    private var scales: [Float] = []
    private var compactMode: Bool
    /// Rows whose segment was deleted: skipped when scoring, squeezed out once they're a fifth of all rows.
    private var dead = Set<Int>()
    /// In compact mode, how far the 8-bit scores of the last search's shortlist were from the exact ones (for `fam`).
    public private(set) var lastApproximationError: Float = 0
    /// How the vectors were brought up to date (for tests and `fam`).
    public private(set) var fullLoads = 0
    public private(set) var incrementalLoads = 0

    public init(db: Catalog, embedder: EmbeddingService = .shared,
                compact: Bool = MemoryProfile.current.compactVectors) {
        self.db = db
        self.queryEmbedder = embedder
        self.compactMode = compact
    }

    /// Which server turns queries into vectors: the dedicated search server, or the indexing one.
    public var embedder: EmbeddingService {
        get { lock.lock(); defer { lock.unlock() }; return queryEmbedder }
        set { lock.lock(); queryEmbedder = newValue; lock.unlock() }
    }

    /// 8-bit vectors in memory (the low-memory profile). Changing it reloads them on the next search.
    public var compact: Bool {
        get { lock.lock(); defer { lock.unlock() }; return compactMode }
        set {
            lock.lock(); defer { lock.unlock() }
            guard newValue != compactMode else { return }
            compactMode = newValue
            loaded = nil
        }
    }

    /// `cutoff: false` keeps results far below the best one (for evals: the gap between right and wrong answers).
    public func search(_ query: String, filter: KindFilter = .all, limit: Int = 40, cutoff: Bool = true) async throws -> [SearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        // An ID in the query (a PAN, a registration or invoice number) is what must match exactly; the words around it
        // ("my pan number") needn't be in the file.
        let identifiers = Self.identifiers(query)
        let terms = identifiers.isEmpty ? Self.terms(query) : identifiers
        async let keywordHits = Task.detached { [db] in (try? db.keywordSearch(terms: terms)) ?? [] }.value
        // A pasted page would overflow the search server's context: the first 2,000 characters say enough.
        let vector = try await embedder.embedQuery(String(query.prefix(2000)))
        let semantic = try semanticHits(vector, top: 400)
        return try merge(semantic: semantic, keywords: await keywordHits, identifierQuery: !identifiers.isEmpty,
                         filter: filter, limit: limit, cutoff: cutoff)
    }

    /// The best-scoring `top` segments for a query vector.
    public func semanticHits(_ query: [Float], top: Int) throws -> [(segment: Int64, file: Int64, score: Float)] {
        try updateIfNeeded()
        lock.lock()
        let rows = segmentIDs.count
        guard rows > 0 else { lock.unlock(); return [] }
        let isCompact = compactMode
        let scores = isCompact ? approximateScores(query) : exactScores(query)
        // Compact: the best 1,000 by the 8-bit scores, then their exact scores decide.
        let shortlist = isCompact ? max(top, 1000) : top
        let order = Self.best(shortlist, of: scores, skipping: dead)
        let hits = order.map { (segment: segmentIDs[$0], file: fileIDs[$0], score: scores[$0]) }
        lock.unlock()
        guard isCompact else { return hits }

        let exact = try db.vectors(ids: hits.map(\.segment))
        var rescored: [(segment: Int64, file: Int64, score: Float)] = []
        rescored.reserveCapacity(hits.count)
        var worst: Float = 0
        for hit in hits {
            guard let vector = exact[hit.segment] else { continue }   // deleted since: skip it
            let dot = VectorKernels.dot(vector, query, count: vector.count)
            worst = max(worst, abs(dot - hit.score))
            rescored.append((hit.segment, hit.file, dot))
        }
        lock.lock(); lastApproximationError = worst; lock.unlock()
        return Array(rescored.sorted { $0.score > $1.score }.prefix(top))
    }

    /// Call with `lock` held.
    private func exactScores(_ query: [Float]) -> [Float] {
        matrix.withUnsafeBufferPointer {
            VectorKernels.exactScores($0, rows: segmentIDs.count, dimension: EmbeddingService.dimension, query: query)
        }
    }

    /// Integer dot products of the 8-bit rows with the query rounded the same way, on every core. Call with `lock` held.
    private func approximateScores(_ query: [Float]) -> [Float] {
        quantized.withUnsafeBufferPointer { m in
            scales.withUnsafeBufferPointer {
                VectorKernels.approximateScores(m, scales: $0, rows: segmentIDs.count, dimension: EmbeddingService.dimension,
                                                query: query)
            }
        }
    }

    static func best(_ count: Int, of scores: [Float], skipping: Set<Int> = []) -> [Int] {
        VectorKernels.best(count, of: scores, skipping: skipping)
    }

    static func quantize(_ vector: ArraySlice<Float>) -> ([Int8], Float) { VectorKernels.quantize(vector) }

    /// Adds rows in this searcher's format. Call with `lock` held.
    private func append(_ vectors: [Float]) {
        guard compactMode else { matrix += vectors; return }
        let dimension = EmbeddingService.dimension
        quantized.reserveCapacity(quantized.count + vectors.count)
        var start = 0
        while start < vectors.count {
            let (q, scale) = Self.quantize(vectors[start ..< start + dimension])
            quantized += q
            scales.append(scale)
            start += dimension
        }
    }

    /// Brings the vectors in memory up to date with the index. Normally that's only the change: rows added since the
    /// last update are read and appended, deleted rows are marked dead. Everything is read again only on the first
    /// search, after the index is emptied, or when the index's removal log no longer reaches back far enough.
    private func updateIfNeeded() throws {
        updateLock.lock(); defer { updateLock.unlock() }
        let now = db.position()
        lock.lock()
        let current = loaded, last = lastSegmentID
        lock.unlock()
        if current == now { return }

        guard let current, current.resetCount == now.resetCount,
              let removed = db.removedSegments(after: current.removals) else {
            let (segments, files, vectors) = try db.loadVectors()
            lock.lock()
            self.segmentIDs = segments; self.fileIDs = files
            matrix = []; quantized = []; scales = []
            append(vectors)
            dead.removeAll()
            lastSegmentID = segments.last ?? 0
            loaded = now
            fullLoads += 1
            lock.unlock()
            return
        }

        // Removals first, then additions: a row added and deleted in between is either never read, or read now and
        // marked dead by the next update's removals.
        let (segments, files, vectors) = try db.loadVectors(after: last)
        lock.lock()
        for id in removed { if let row = row(of: id) { dead.insert(row) } }
        self.segmentIDs += segments
        self.fileIDs += files
        append(vectors)
        if let newest = segments.last { lastSegmentID = newest }
        if dead.count > 1000 && dead.count * 5 > segmentIDs.count { compactRows() }
        loaded = Catalog.Position(generation: now.generation, resetCount: now.resetCount,
                                   removals: current.removals + removed.count)
        incrementalLoads += 1
        lock.unlock()
    }

    /// The row holding segment `id` (`segmentIDs` is sorted). Call with `lock` held.
    private func row(of id: Int64) -> Int? {
        var low = 0, high = segmentIDs.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if segmentIDs[mid] == id { return mid }
            if segmentIDs[mid] < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    /// Drops the dead rows. Call with `lock` held.
    private func compactRows() {
        let dimension = EmbeddingService.dimension
        let keep = segmentIDs.indices.filter { !dead.contains($0) }
        segmentIDs = keep.map { segmentIDs[$0] }
        fileIDs = keep.map { fileIDs[$0] }
        if compactMode {
            var q: [Int8] = []; q.reserveCapacity(keep.count * dimension)
            for row in keep { q += quantized[row * dimension ..< (row + 1) * dimension] }
            quantized = q
            scales = keep.map { scales[$0] }
        } else {
            var m: [Float] = []; m.reserveCapacity(keep.count * dimension)
            for row in keep { m += matrix[row * dimension ..< (row + 1) * dimension] }
            matrix = m
        }
        dead.removeAll()
    }

    /// Rows in memory, how many are dead, and the bytes the vectors take (for tests and `fam`).
    public var loadedRows: (rows: Int, dead: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (segmentIDs.count, dead.count, matrix.count * 4 + quantized.count + scales.count * 4)
    }

    /// Call when another process (the CLI) changed the index file.
    public func invalidate() {
        lock.lock(); loaded = nil; lock.unlock()
    }

    private func merge(semantic: [(segment: Int64, file: Int64, score: Float)], keywords: [Catalog.KeywordHit],
                       identifierQuery: Bool, filter: KindFilter, limit: Int, cutoff: Bool = true) throws -> [SearchResult] {
        // The best segment of each file.
        var best: [Int64: (segment: Int64, score: Float)] = [:]
        for hit in semantic where best[hit.file] == nil { best[hit.file] = (hit.segment, hit.score) }
        let infos = try db.segmentInfo(ids: best.values.map { $0.segment })

        // Exact words: a boost that fades down the keyword ranking. A query that looks like an identifier (digits,
        // quotes, a code) leans on it more.
        let maxBoost: Float = identifierQuery ? 0.2 : 0.08
        var keywordBest: [Int64: (boost: Float, hit: Catalog.KeywordHit)] = [:]
        for (rank, hit) in keywords.enumerated() where keywordBest[hit.fileID] == nil {
            keywordBest[hit.fileID] = (maxBoost * (1 - Float(rank) / Float(max(keywords.count, 1)) * 0.5), hit)
        }

        var results: [Int64: SearchResult] = [:]
        for (file, hit) in best {
            guard let info = infos[hit.segment], let kind = FileKind(rawValue: info.fileKind), filter.allows(kind) else { continue }
            let keyword = keywordBest[file]
            results[file] = SearchResult(path: info.path, fileKind: kind, score: hit.score + (keyword?.boost ?? 0),
                                         segmentKind: info.kind, locator: info.locator,
                                         snippet: keyword.map { $0.hit.snippet } ?? info.snippet, exactMatch: keyword != nil)
        }
        // Files found only by their exact words.
        for (file, keyword) in keywordBest where results[file] == nil {
            guard let kind = FileKind(rawValue: keyword.hit.fileKind), filter.allows(kind) else { continue }
            results[file] = SearchResult(path: keyword.hit.path, fileKind: kind, score: 0.45 + keyword.boost,
                                         segmentKind: keyword.hit.kind, locator: keyword.hit.locator,
                                         snippet: keyword.hit.snippet, exactMatch: true)
        }

        // A file holding the exact ID beats any file that's only close in meaning.
        let ranked = results.values.sorted {
            if identifierQuery && $0.exactMatch != $1.exactMatch { return $0.exactMatch }
            return $0.score > $1.score
        }
        guard let top = ranked.first(where: { !$0.exactMatch })?.score ?? ranked.first?.score else { return [] }
        // Keep what's near the best match; far below it is noise (unrelated files score about 0.5).
        // When the ID was found, only strong matches by meaning keep it company.
        let floor: Float = identifierQuery && ranked.first?.exactMatch == true ? 0.7 : 0.5
        guard cutoff else { return Array(ranked.prefix(limit)) }
        return Array(ranked.filter { $0.exactMatch || ($0.score >= top - 0.14 && $0.score > floor) }.prefix(limit))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let stopWords: Set<String> = ["the", "a", "an", "of", "in", "on", "at", "to", "for", "and", "or", "is", "with",
                                         "my", "me", "where", "what", "that", "this", "about", "from", "by", "it", "i"]

    /// The ID-like parts of a query: quoted text, and tokens with a digit at least 4 characters long ("ABCDE1234F",
    /// "INV-2024-0042", "21/BSC/0456"). Each becomes a phrase of its letters and digits, since the keyword index
    /// splits "21/BSC/0456" into 21, bsc, 0456.
    static func identifiers(_ query: String) -> [String] {
        var out: [String] = []
        let quoted = query.components(separatedBy: "\"")
        if quoted.count >= 3 {
            for (i, part) in quoted.enumerated() where i % 2 == 1 { out.append(part) }
        }
        for token in query.split(whereSeparator: \.isWhitespace).map(String.init) where !token.contains("\"") {
            let core = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if core.count >= 4, core.rangeOfCharacter(from: .decimalDigits) != nil { out.append(core) }
        }
        return out.map { phrase in
            phrase.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
                .joined(separator: " ")
        }.filter { !$0.isEmpty }
    }

    /// Words worth matching exactly.
    static func terms(_ query: String) -> [String] {
        query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }
}
