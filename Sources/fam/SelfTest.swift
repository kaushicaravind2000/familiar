import Foundation
import FamiliarCore
import SQLite3

/// `fam selftest`: incremental vector loading must give exactly what a full reload gives, through any mix of adds,
/// replacements, deletions and resets; old indexes must migrate to never-reused segment ids; and an update should
/// cost as much as the change, not the whole index. Runs on temporary indexes only.
func selfTest() throws {
    let dimension = EmbeddingService.dimension
    var rng = SystemRandomNumberGenerator()
    func randomVector() -> [Float] {
        var v = (0..<dimension).map { _ in Float.random(in: -1...1, using: &rng) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        for i in v.indices { v[i] /= norm }
        return v
    }
    func file(_ db: Catalog, _ path: String, segments: Int) throws {
        let rows = (0..<segments).map { SegmentRow(kind: .text, locator: Double($0), snippet: nil, vector: randomVector()) }
        try db.replaceFile(path: path, kind: "text", size: 1, mtime: 0, segments: rows, keywords: [], error: nil)
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fam-selftest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    var failures = 0

    // 1. Incremental == full reload, through random changes; in both vector formats (compact: 8-bit + exact rescore).
    for compact in [false, true] {
        let db = try Catalog(url: tmp.appendingPathComponent("a-\(compact).sqlite"))
        let incremental = Lookup(db: db, compact: compact)
        var paths: [String] = []
        var next = 0
        for _ in 0..<40 { next += 1; paths.append("/t/\(next)"); try file(db, "/t/\(next)", segments: Int.random(in: 1...4)) }
        var mismatches = 0
        let operations = 300
        for step in 0..<operations {
            switch Int.random(in: 0..<100) {
            case 0..<35:   // add
                next += 1; paths.append("/t/\(next)"); try file(db, "/t/\(next)", segments: Int.random(in: 1...4))
            case 35..<60:  // replace (same path, new vectors)
                if let p = paths.randomElement() { try file(db, p, segments: Int.random(in: 1...4)) }
            case 60..<80:  // delete
                if !paths.isEmpty { let p = paths.remove(at: Int.random(in: 0..<paths.count)); try db.removeFiles(paths: [p]) }
            case 80..<95:  // delete the newest file, then add one: the case where reused ids would hide new rows
                if let p = paths.popLast() { try db.removeFiles(paths: [p]) }
                next += 1; paths.append("/t/\(next)"); try file(db, "/t/\(next)", segments: 2)
            case 95..<97:  // empty the index
                try db.removeAll(); paths.removeAll()
            default:       // several changes between two searches
                for _ in 0..<5 { next += 1; paths.append("/t/\(next)"); try file(db, "/t/\(next)", segments: 1) }
                if paths.count > 3 { try db.removeFiles(paths: [paths.removeFirst()]) }
            }
            let query = randomVector()
            let a = try incremental.semanticHits(query, top: 25)
            let b = try Lookup(db: db, compact: false).semanticHits(query, top: 25)
            // Same segments with the same scores, to float rounding: Accelerate sums in a slightly different order
            // for different matrix sizes, which moves scores in the 8th decimal place.
            let fullScores = Dictionary(uniqueKeysWithValues: b.map { ($0.segment, $0.score) })
            let same = a.count == b.count && a.allSatisfy { hit in
                fullScores[hit.segment].map { abs($0 - hit.score) < 1e-5 } ?? false
            }
            if !same {
                mismatches += 1
                if mismatches <= 2 {
                    let sameSet = Set(a.map(\.segment)) == Set(b.map(\.segment))
                    let maxDiff = zip(a, b).map { abs($0.score - $1.score) }.max() ?? 0
                    print("  mismatch at step \(step): counts \(a.count)/\(b.count), same segments: \(sameSet), largest score difference \(maxDiff)")
                    print("    incremental: \(a.prefix(4).map { "\($0.segment):\($0.score)" })")
                    print("    full:        \(b.prefix(4).map { "\($0.segment):\($0.score)" })")
                }
            }
        }
        let rows = incremental.loadedRows
        print("1\(compact ? "b. compact (8-bit)" : "a. full precision") incremental vs full reload: \(operations) random changes, \(mismatches) mismatches " +
              "(\(incremental.incrementalLoads) incremental updates, \(incremental.fullLoads) full loads; " +
              "\(rows.rows) rows in memory, \(rows.dead) marked deleted)")
        if mismatches > 0 { failures += 1 }
    }

    // 1c. Compact search at 100,000 vectors: the same top 25 as full precision, in a quarter of the memory.
    do {
        let db = try Catalog(url: tmp.appendingPathComponent("c.sqlite"))
        for n in 0..<10_000 { try file(db, "/c/\(n)", segments: 10) }
        let exact = Lookup(db: db, compact: false), compact = Lookup(db: db, compact: true)
        var differing = 0
        var timeExact = 0.0, timeCompact = 0.0
        for _ in 0..<20 {
            let query = randomVector()
            var started = Date()
            let a = try exact.semanticHits(query, top: 25); timeExact += Date().timeIntervalSince(started)
            started = Date()
            let b = try compact.semanticHits(query, top: 25); timeCompact += Date().timeIntervalSince(started)
            if a.map(\.segment) != b.map(\.segment) { differing += 1 }
        }
        let mb = { (s: Lookup) in Double(s.loadedRows.bytes) / 1_048_576 }
        print(String(format: "1c. 100,000 vectors, 20 searches: top 25 differ in %d; memory %.0f MB → %.0f MB; %.1f → %.1f ms per search (average of 20, including the first load)",
                     differing, mb(exact), mb(compact), timeExact / 20 * 1000, timeCompact / 20 * 1000))
        if differing > 0 { failures += 1 }
    }

    // 2. An index from before AUTOINCREMENT keeps its vectors and gets never-reused ids.
    do {
        let url = tmp.appendingPathComponent("old.sqlite")
        var raw: OpaquePointer?
        sqlite3_open(url.path, &raw)
        sqlite3_exec(raw, """
            CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
              size INTEGER NOT NULL, mtime REAL NOT NULL, indexed_at REAL NOT NULL, error TEXT);
            CREATE TABLE segments(id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, locator REAL NOT NULL, snippet TEXT, vector BLOB NOT NULL);
            INSERT INTO files VALUES(1, '/old/a', 'a', 'text', 1, 0, 0, NULL);
            """, nil, nil, nil)
        let blob = [Float](repeating: 0.036, count: dimension)
        for _ in 0..<3 {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(raw, "INSERT INTO segments(file_id, kind, locator, vector) VALUES(1, 'text', 0, ?)", -1, &statement, nil)
            blob.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), nil) }
            sqlite3_step(statement); sqlite3_finalize(statement)
        }
        sqlite3_close(raw)
        let db = try Catalog(url: url)
        let kept = try db.loadVectors().segments
        try db.removeFiles(paths: ["/old/a"])
        try file(db, "/old/b", segments: 1)
        let newID = try db.loadVectors().segments.first ?? 0
        let ok = kept == [1, 2, 3] && newID == 4
        print("2. migration: kept segments \(kept), next new id \(newID) (must be 4, not a reused 1): \(ok ? "ok" : "FAILED")")
        if !ok { failures += 1 }
    }

    // 3. Cost at 100,000 vectors.
    do {
        let db = try Catalog(url: tmp.appendingPathComponent("big.sqlite"))
        for n in 0..<10_000 { try file(db, "/big/\(n)", segments: 10) }
        let searcher = Lookup(db: db)
        let query = randomVector()
        func timed(_ label: String) throws {
            let started = Date()
            _ = try searcher.semanticHits(query, top: 25)
            print(String(format: "   %@ %6.1f ms", label, Date().timeIntervalSince(started) * 1000))
        }
        print("3. search cost at 100,000 vectors (update + scoring):")
        try timed("first search (full load):     ")
        try timed("nothing changed:              ")
        try file(db, "/big/new", segments: 10)
        try timed("after one file added:         ")
        try db.removeFiles(paths: ["/big/7"])
        try timed("after one file deleted:       ")
        try file(db, "/big/8", segments: 10)
        try timed("after one file replaced:      ")
        searcher.invalidate()
        try timed("forced full reload, for scale:")
    }

    // 4. Logs stay under 2 MB: past 1 MB the file rolls over to .1.
    do {
        let name = "selftest-\(UUID().uuidString).log"
        let line = String(repeating: "x", count: 1023) + "\n"
        for _ in 0..<2600 { LogFile.append(line, to: name) }
        let url = AppPaths.logs.appendingPathComponent(name), old = url.appendingPathExtension("1")
        let size = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue ?? 0 }
        let ok = size(url) <= LogFile.limit + 1024 && size(old) <= LogFile.limit + 1024 && size(old) > 0
        print("4. log rotation: 2.6 MB written → current \(size(url) / 1024) KB, previous \(size(old) / 1024) KB: \(ok ? "ok" : "FAILED")")
        try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: old)
        if !ok { failures += 1 }
    }

    // 5. A damaged index is replaced at open, and damage found later (integrity check) is recovered from in place.
    do {
        let url = tmp.appendingPathComponent("damaged.sqlite")
        try Data((0..<65536).map { _ in UInt8.random(in: 0...255) }).write(to: url)   // not a database at all
        let db = try Catalog(url: url)
        try file(db, "/d/a", segments: 2)
        let atOpenCount = try db.loadVectors().segments.count
        let atOpen = db.recoveredAtOpen && atOpenCount == 2
        print("5a. garbage file at open: replaced with a fresh index that works: \(atOpen ? "ok" : "FAILED")")
        if !atOpen { failures += 1 }

        let url2 = tmp.appendingPathComponent("pages.sqlite")
        do {
            let db2 = try Catalog(url: url2)
            for n in 0..<300 { try file(db2, "/p/\(n)", segments: 3) }
        }
        // Scribble over pages in the middle, keeping the header: opening works, the data underneath doesn't.
        let handle = try FileHandle(forUpdating: url2)
        let length = try handle.seekToEnd()
        for offset in stride(from: UInt64(length / 3), to: UInt64(length / 3 * 2), by: 4096) {
            try handle.seek(toOffset: offset)
            handle.write(Data((0..<512).map { _ in UInt8.random(in: 0...255) }))
        }
        try handle.close()
        let db2 = try Catalog(url: url2)
        let damaged = !db2.checkIntegrity()
        try db2.recover()
        try file(db2, "/p/new", segments: 1)
        let afterCount = try db2.loadVectors().segments.count
        let healthy = db2.checkIntegrity() && afterCount == 1
        let kept = FileManager.default.fileExists(atPath: tmp.appendingPathComponent("pages.damaged.sqlite").path)
        print("5b. damaged pages: integrity check caught it: \(damaged), recovered to a working index: \(healthy), damaged copy kept: \(kept)")
        if !(damaged && healthy && kept) { failures += 1 }
    }

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")
    if failures > 0 { exit(1) }
}

/// `fam selftest-changes`: reading only the paths FSEvents reports must leave the index exactly as a full scan would,
/// through adds, edits, deletions, new and deleted folders, and changes in skipped places. Uses the model.
func selfTestChanges() async throws {
    let fm = FileManager.default
    // Under /tmp, which macOS reports as /private/tmp: deleted paths must still match how the index spells them.
    let root = URL(fileURLWithPath: "/tmp/fam-changes-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    for n in 0..<6 { try write("notes/note\(n).txt", "Note number \(n) about topic \(n * 7).") }
    try write("projects/app/README.md", "The app project.")
    try write("projects/app/package.json", "{}")

    let incrementalDB = try Catalog(url: root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-inc.sqlite"))
    let indexer = Ingestor(db: incrementalDB)
    await indexer.run(roots: [root])

    // Changes, and the paths FSEvents would report for them.
    var reported: [String] = []
    try write("notes/note1.txt", "Note one, edited: now about Lisbon."); reported.append("notes/note1.txt")
    try fm.removeItem(at: root.appendingPathComponent("notes/note2.txt")); reported.append("notes/note2.txt")
    try write("notes/new.txt", "A brand new note about cookies."); reported.append("notes/new.txt")
    try write("trips/2027/plan.md", "Trip plan for Japan."); try write("trips/2027/budget.txt", "Budget: 3000.")
    reported.append("trips")                                  // a folder that appeared, with files inside
    try fm.removeItem(at: root.appendingPathComponent("projects")); reported.append("projects")   // a folder deleted
    try write(".hidden/secret.txt", "Should never be read."); reported.append(".hidden/secret.txt")
    try write("lib/node_modules/pkg/readme.txt", "Dependency docs."); reported.append("lib/node_modules/pkg/readme.txt")
    await indexer.run(roots: [root], changes: reported.map { "/private" + root.appendingPathComponent($0).path })

    let fullDB = try Catalog(url: root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-full.sqlite"))
    await Ingestor(db: fullDB).run(roots: [root])
    await EmbeddingService.shared.stop()

    let a = try incrementalDB.fileStates(), b = try fullDB.fileStates()
    let names = { (s: [String: FileState]) in s.keys.map { String($0.dropFirst(root.standardizedFileURL.path.count + 1)) }.sorted() }
    let sameFiles = names(a) == names(b)
    let sameVersions = a.allSatisfy { path, state in b[path].map { $0.size == state.size && $0.mtime == state.mtime } ?? false }
    print("6. changes only vs full scan: \(names(a).count) files either way: \(sameFiles && sameVersions ? "identical" : "DIFFERENT")")
    print("   indexed: \(names(a).joined(separator: ", "))")
    if !(sameFiles && sameVersions) {
        print("   full scan has: \(names(b).joined(separator: ", "))")
        exit(1)
    }
}
