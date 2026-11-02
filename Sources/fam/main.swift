import Foundation
import FamiliarCore

// fam: the engine from the terminal.
//   fam download              download the model (once)
//   fam index <folder>...     bring the index up to date with these folders
//   fam search <words>        search it
//   fam ask <question>        answer it from the files (fam download-chat first)
//   fam status                what's in the index
// It uses the same index and model as the app (~/Library/Application Support/Familiar).

let arguments = Array(CommandLine.arguments.dropFirst())
// The app's helper guard: before anything else, and it never returns.
if arguments.first == "guard" { runGuard(Array(arguments.dropFirst())) }
guard let command = arguments.first else {
    print("usage: fam download | download-chat | index <folder>... | search <words> | ask <question> | status")
    exit(2)
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

do {
    switch command {
    case "download":
        let downloader = ModelDownloader()
        var lastShown = -1
        downloader.onProgress = { done, total in
            let percent = Int(Double(done) / Double(total) * 100)
            if percent != lastShown { lastShown = percent; print("\r\(percent)%", terminator: ""); fflush(stdout) }
        }
        try await downloader.run()
        print("\nModel ready in \(AppPaths.models.path)")

    case "download-chat":
        let downloader = ModelDownloader(files: ChatModelFiles.all)
        var lastShown = -1
        downloader.onProgress = { done, total in
            let percent = Int(Double(done) / Double(total) * 100)
            if percent != lastShown { lastShown = percent; print("\r\(percent)%", terminator: ""); fflush(stdout) }
        }
        try await downloader.run()
        print("\nAnswer model ready in \(AppPaths.models.path)")

    case "prepare-speech":
        // fam prepare-speech: downloads the pinned speech models (checked against their SHA-256) and compiles them.
        var shown = -1
        try await Transcriber.prepare { value in
            let percent = Int(value * 100)
            if percent != shown { shown = percent; print("\r\(percent)%", terminator: ""); fflush(stdout) }
        }
        print("\nSpeech model ready in \(Transcriber.modelsFolder.path)")

    case "ask":
        // fam ask <question> [--passages]: the passages it quotes, then the answer as it's written.
        let showPassages = arguments.contains("--passages")
        let question = arguments.dropFirst().filter { $0 != "--passages" }.joined(separator: " ")
        let db = try Catalog()
        let asker = Asker(db: db, searcher: Lookup(db: db, embedder: .search))
        let started = Date()
        let (passages, answer) = try await asker.ask(question)
        let found = Date()
        for p in passages {
            print("[\(p.number)] \(p.label)")
            if showPassages { print("    " + p.text.replacingOccurrences(of: "\n", with: "\n    ")) }
        }
        var first: Date?
        for try await piece in answer {
            if first == nil { first = Date(); print("") }
            print(piece, terminator: ""); fflush(stdout)
        }
        print(String(format: "\n\nsearch %.2f s, first word %.2f s, all %.2f s", found.timeIntervalSince(started),
                     (first ?? Date()).timeIntervalSince(started), Date().timeIntervalSince(started)))
        await EmbeddingService.search.stop()
        await ChatService.shared.stop()

    case "converse":
        // fam converse [--naive] "question" "follow-up" …: a conversation, as the Chat page has it. Shows the plan
        // (the question in full, the searches, whether the last answer's passages were carried over), the sources and
        // the answer, checked. --naive: the first version (one rewrite, one search, nothing carried), to compare.
        let naive = arguments.contains("--naive")
        var rest = Array(arguments.dropFirst().filter { $0 != "--naive" })
        var scope: String?
        if let i = rest.firstIndex(of: "--scope"), i + 1 < rest.count {
            scope = (rest[i + 1] as NSString).expandingTildeInPath
            rest.removeSubrange(i...(i + 1))
        }
        let questions = rest
        let db = try Catalog()
        let asker = Asker(db: db, searcher: Lookup(db: db, embedder: .search))
        asker.planning = !naive
        var history: [Asker.Exchange] = []
        for question in questions {
            let started = Date()
            let turn = try await asker.ask(question, history: history, scope: scope)
            print("\n> \(question)")
            if turn.plan.standalone != question { print("  in full: \(turn.plan.standalone)") }
            if turn.plan.searches != [question] { print("  searched: " + turn.plan.searches.joined(separator: " | ")) }
            if turn.carried > 0 { print("  carried from the last answer: \(turn.carried)") }
            print("  sources: " + turn.passages.map { "[\($0.number)] \($0.label)" }.joined(separator: " · "))
            var answer = ""
            for try await piece in turn.answer { answer += piece }
            let checked = Asker.checked(answer, passageCount: turn.passages.count)
            print("  " + checked.text.replacingOccurrences(of: "\n", with: "\n  ") + (checked.unsupported ? "  ⚠︎ not from your files" : ""))
            print(String(format: "  (%.1f s)", Date().timeIntervalSince(started)))
            history.append(Asker.Exchange(question: question, answer: checked.text, passages: turn.passages))
        }
        await EmbeddingService.search.stop()
        await ChatService.shared.stop()

    case "converse-eval":
        // fam converse-eval <conversations.json> [--naive] [--json <out>]: scores conversations turn by turn.
        try await runConverseEval(Array(arguments.dropFirst()))

    case "index":
        let slow = arguments.contains("--slow")   // the pace the app uses on battery
        let roots = arguments.dropFirst().filter { $0 != "--slow" }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        guard !roots.isEmpty else { print("usage: fam index <folder>..."); exit(2) }
        let db = try Catalog()
        let started = Date()
        let indexer = Ingestor(db: db) { p in
            switch p.phase {
            case .indexing:
                let line = "[\(p.done)/\(p.total)] \(p.current ?? "")"
                print("\r\(line.padding(toLength: 100, withPad: " ", startingAt: 0))", terminator: "")
                fflush(stdout)
            case .done:
                print("\nDone: \(p.done) files read, \(p.failed) couldn't be read")
                if let denied = p.denied, !denied.isEmpty { print("macOS refused access to: \(denied.joined(separator: ", "))") }
            case .failed: print("\nStopped: \(p.message ?? "")")
            default: break
            }
        }
        await indexer.setSlow(slow)
        await indexer.run(roots: roots)
        await EmbeddingService.shared.stop()
        print(String(format: "%.1f s", Date().timeIntervalSince(started)))

    case "search":
        let query = arguments.dropFirst().joined(separator: " ")
        let db = try Catalog()
        let searcher = Lookup(db: db)
        let started = Date()
        let results = try await searcher.search(query)
        let elapsed = Date().timeIntervalSince(started)
        for (n, r) in results.prefix(15).enumerated() {
            let place = r.place.map { " (\($0))" } ?? ""
            let exact = r.exactMatch ? " ✱" : ""
            print(String(format: "%2d. %.3f  ", n + 1, r.score) + r.name + place + exact)
            print("      " + r.path)
            if let snippet = r.snippet { print("      " + String(snippet.prefix(140))) }
        }
        print(String(format: "%d results in %.2f s", results.count, elapsed))
        await EmbeddingService.shared.stop()

    case "latency":
        // fam latency <folder> [--shared]: indexes <folder> into a fresh index and, meanwhile, times a search every
        // 200 ms, with the dedicated search server (default) or the shared indexing one (--shared).
        guard arguments.count >= 2 else { print("usage: fam latency <folder> [--shared]"); exit(2) }
        let folder = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath).standardizedFileURL
        let shared = arguments.contains("--shared")
        let db = try Catalog()
        try db.removeAll()
        let searcher = Lookup(db: db, embedder: shared ? .shared : .search)
        _ = try await searcher.search("warm up")   // load the server(s) first: this measures waiting, not loading
        let indexer = Ingestor(db: db)
        let indexing = Task { await indexer.run(roots: [folder]) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        var times: [Double] = []
        while times.count < 20 {
            let started = Date()
            _ = try await searcher.search("dog on the beach")
            times.append(Date().timeIntervalSince(started) * 1000)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        indexing.cancel()
        await EmbeddingService.shared.stop()
        await EmbeddingService.search.stop()
        times.sort()
        print(String(format: "%@ server: search while indexing p50 %.0f ms, max %.0f ms",
                     shared ? "shared indexing" : "dedicated search", times[times.count / 2], times.last!))

    case "bench-vectors":
        // fam bench-vectors [--sizes 10000,100000,1000000] [--queries 200] [--threads n] [--json <out>]: 8-bit vectors
        // with exact rescoring against float32, on this machine (synthetic data; see BenchVectors.swift).
        try benchVectors(Array(arguments.dropFirst()))

    case "eval":
        // fam eval <queries.json> [--reindex] [--index <file>] [--json <out>] [--baseline <json>]: search quality.
        try await runEval(Array(arguments.dropFirst()))

    case "selftest":
        // fam selftest: checks incremental vector loading against full reloads, the segment-id migration, timing,
        // log rotation and damaged-index recovery.
        try selfTest()

    case "selftest-vectors":
        // fam selftest-vectors [--write]: the model still makes the stored reference vectors.
        try await referenceVectors(Array(arguments.dropFirst()))

    case "selftest-changes":
        // fam selftest-changes: reading only changed paths must match a full scan (uses the model).
        try await selfTestChanges()

    case "compactcheck":
        // fam compactcheck: on the real index, compares 8-bit (compact) search with full precision for a set of
        // everyday queries. Prints only counts and score differences, nothing from the files.
        let db = try Catalog()
        let exact = Lookup(db: db, compact: false), compact = Lookup(db: db, compact: true)
        let queries = ["a document about money", "photo of people outside", "a screenshot with an error", "travel plans",
                       "a recording of someone talking", "contract or agreement", "receipt or invoice", "notes from a meeting",
                       "identity card", "a certificate", "a picture of food", "something about health", "a list of tasks",
                       "a letter", "a chart or graph", "school or university", "a map", "a phone number", "a presentation",
                       "a form to fill in"]
        var sameTop10 = 0, sameTop25 = 0, worstRawError: Float = 0, worstFinal: Float = 0
        for q in queries {
            let vector = try await EmbeddingService.search.embedQuery(q)
            let a = try exact.semanticHits(vector, top: 25), b = try compact.semanticHits(vector, top: 25)
            if a.prefix(10).map(\.segment) == b.prefix(10).map(\.segment) { sameTop10 += 1 }
            if a.map(\.segment) == b.map(\.segment) { sameTop25 += 1 }
            let exactScores = Dictionary(uniqueKeysWithValues: a.map { ($0.segment, $0.score) })
            for hit in b { if let e = exactScores[hit.segment] { worstFinal = max(worstFinal, abs(e - hit.score)) } }
            worstRawError = max(worstRawError, compact.lastApproximationError)
        }
        await EmbeddingService.search.stop()
        let rows = exact.loadedRows, rowsCompact = compact.loadedRows
        print("\(rows.rows) vectors of 768 numbers; \(queries.count) queries")
        print(String(format: "memory: %.2f MB as 32-bit floats, %.2f MB as 8-bit", Double(rows.bytes) / 1_048_576, Double(rowsCompact.bytes) / 1_048_576))
        print("same top 10: \(sameTop10)/\(queries.count), same top 25: \(sameTop25)/\(queries.count)")
        print(String(format: "largest error of an 8-bit score before rescoring: %.4f; after rescoring: %.7f", worstRawError, worstFinal))

    case "status":
        let counts = try Catalog().counts()
        print("\(counts.files) files (\(counts.failed) unreadable), \(counts.segments) vectors")
        for (kind, n) in counts.byKind.sorted(by: { $0.key < $1.key }) { print("  \(kind): \(n)") }
        print("Model: \(EmbeddingModelFiles.isInstalled ? "installed" : "not downloaded")")
        print("Answer model: \(ChatModelFiles.isInstalled ? "installed" : "not downloaded")")

    default:
        print("unknown command \(command)")
        exit(2)
    }
} catch {
    fail(error)
}
