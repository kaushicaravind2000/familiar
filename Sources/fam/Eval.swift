import Foundation
import FamiliarCore

/// `fam eval <queries.json> [--reindex] [--index <file>] [--json <out>] [--baseline <json>]`
///
/// Scores search on a test collection with known answers (scripts/make-test-collection.sh, evals/core.json). Each query lists
/// the files it should find, optionally where ("handbook.pdf#5" a page or slide, "podcast.m4a@30-60" seconds), and
/// files that must not appear (hidden, dependency or bundle copies). Search runs exactly as in the app, cutoffs
/// included. The index is built once and reused unless `--reindex`; settings for A/B runs come from the environment
/// (FAMILIAR_BUDGET_*, FAMILIAR_MEMORY), so give each setting its own `--index`.
struct EvalFile: Decodable {
    let base: String
    let queries: [EvalQuery]
}

struct EvalQuery: Decodable {
    let q: String
    let expect: [String]
    let tag: String
    let absent: [String]?
}

/// One query's outcome, as saved with `--json`.
struct EvalOutcome: Codable {
    let q: String
    let tag: String
    let ranks: [Int]            // ranks (1-based) of the expected files that were found
    let expectedFiles: Int
    let recall1: Double, recall5: Double, recall10: Double
    let reciprocalRank: Double
    let ndcg10: Double
    let location: Bool?         // the page or moment of the best expected hit, when the query names one
    let absentShown: [String]
    let milliseconds: Double
    /// Score of the best right answer minus the best wrong one, without the display cutoff: how safely it wins.
    let margin: Double
    let top: [String]           // the first three results, for reading misses
}

struct EvalReport: Codable {
    let label: String
    let date: String
    let budgets: ImageBudgets
    let profile: String
    let indexSeconds: Double?
    let files: Int
    let vectors: Int
    let outcomes: [EvalOutcome]
}

struct Summary {
    var n = 0, r1 = 0.0, r5 = 0.0, r10 = 0.0, mrr = 0.0, ndcg = 0.0, margin = 0.0, located = 0, locatable = 0, absent = 0
    var checks = 0   // queries that only check what must not appear
    mutating func add(_ o: EvalOutcome) {
        absent += o.absentShown.count
        if o.expectedFiles == 0 { checks += 1; return }
        n += 1; r1 += o.recall1; r5 += o.recall5; r10 += o.recall10; mrr += o.reciprocalRank; ndcg += o.ndcg10
        margin += o.margin
        if let l = o.location { locatable += 1; if l { located += 1 } }
    }
    func line(_ name: String) -> String {
        if n == 0 {
            return name.padding(toLength: 18, withPad: " ", startingAt: 0)
                + String(format: "%3d  checks only what must not appear%@%4d", checks, String(repeating: " ", count: 24), absent)
        }
        let d = Double(max(n, 1))
        let loc = locatable == 0 ? "    –" : String(format: "%2d/%-2d", located, locatable)
        return name.padding(toLength: 18, withPad: " ", startingAt: 0)
            + String(format: "%3d  %5.2f  %5.2f  %5.2f  %5.2f  %6.2f  %+6.3f   %@  %4d", n, r1 / d, r5 / d,
                     r10 / d, mrr / d, ndcg / d, margin / d, loc as NSString, absent)
    }
}

func runEval(_ arguments: [String]) async throws {
    guard let path = arguments.first else {
        print("usage: fam eval <queries.json> [--reindex] [--index <file>] [--json <out>] [--baseline <json>]")
        exit(2)
    }
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    let eval = try JSONDecoder().decode(EvalFile.self, from: Data(contentsOf: file))
    let base = URL(fileURLWithPath: eval.base, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
    guard FileManager.default.fileExists(atPath: base.path) else {
        print("No test collection at \(base.path): run scripts/make-test-collection.sh first."); exit(1)
    }
    let indexURL = option("--index").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? base.deletingLastPathComponent().appendingPathComponent("eval-index.sqlite")
    let budgets = ImageBudgets.current

    // The index: built once per setting, reused after.
    var indexSeconds: Double?
    if arguments.contains("--reindex") || !FileManager.default.fileExists(atPath: indexURL.path) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: indexURL.path + suffix) }
        let db = try Catalog(url: indexURL)
        print("Indexing \(base.lastPathComponent) (photo \(budgets.photo), screenshot \(budgets.screenshot), page \(budgets.page), frame \(budgets.frame) tokens)…")
        let started = Date()
        await Ingestor(db: db).run(roots: [base])
        indexSeconds = Date().timeIntervalSince(started)
        await EmbeddingService.shared.stop()
    }
    let db = try Catalog(url: indexURL)
    let counts = try db.counts()
    let searcher = Lookup(db: db, embedder: .search)
    _ = try await searcher.search("warm up")

    let root = base.path + "/"
    func relative(_ path: String) -> String { path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path }

    var outcomes: [EvalOutcome] = []
    for query in eval.queries {
        // "file#page" and "file@from-to": the file, and where in it.
        var wanted: [String: String?] = [:]
        for item in query.expect {
            if let i = item.lastIndex(of: "@"), item[item.index(after: i)...].hasPrefix("seg"),
               let n = Int(item[item.index(i, offsetBy: 4)...]) {
                // "@seg3": the third part of a recording, from <file>.segments.json beside it (scripts/make-test-collection.sh).
                let file = String(item[..<i])
                let manifest = base.appendingPathComponent(file + ".segments.json")
                guard let data = try? Data(contentsOf: manifest),
                      let segments = try? JSONSerialization.jsonObject(with: data) as? [[Double]], n >= 1, n <= segments.count
                else { print("can't resolve \(item): no \(manifest.lastPathComponent)"); exit(1) }
                wanted[file] = "@\(segments[n - 1][0])-\(segments[n - 1][1])"
            } else if let i = item.lastIndex(where: { $0 == "#" || $0 == "@" }), item[item.index(after: i)...].first?.isNumber == true {
                wanted[String(item[..<i])] = String(item[i...])
            } else {
                wanted[item] = .some(nil)
            }
        }
        let started = Date()
        let results = try await searcher.search(query.q)
        let milliseconds = Date().timeIntervalSince(started) * 1000
        let paths = results.map { relative($0.path) }

        var ranks: [Int] = []
        var location: Bool?
        for (index, path) in paths.enumerated() where wanted[path] != nil {
            ranks.append(index + 1)
            if location == nil, index < 10, let place = wanted[path] ?? nil {
                location = EvalOutcome.located(results[index], place)
            }
        }
        if location == nil, wanted.values.contains(where: { $0 != nil }) { location = false }   // named a place, not found
        let expected = wanted.count
        func recall(_ k: Int) -> Double { expected == 0 ? 0 : Double(ranks.filter { $0 <= k }.count) / Double(min(expected, k)) }
        var dcg = 0.0, ideal = 0.0
        for rank in ranks where rank <= 10 { dcg += 1 / log2(Double(rank) + 1) }
        for i in stride(from: 1, through: min(expected, 10), by: 1) { ideal += 1 / log2(Double(i) + 1) }
        let absentShown = (query.absent ?? []).filter { query.expect.isEmpty ? paths.contains($0) : paths.prefix(10).contains($0) }
        // The margin, from the full ranking.
        let all = try await searcher.search(query.q, cutoff: false)
        let bestRight = all.first { wanted[relative($0.path)] != nil }?.score ?? 0
        let bestWrong = all.first { wanted[relative($0.path)] == nil }?.score ?? 0
        let margin = Double(bestRight - bestWrong)
        outcomes.append(EvalOutcome(q: query.q, tag: query.tag, ranks: ranks, expectedFiles: expected,
                                    recall1: recall(1), recall5: recall(5), recall10: recall(10),
                                    reciprocalRank: ranks.first.map { 1 / Double($0) } ?? 0, ndcg10: ideal > 0 ? dcg / ideal : 0,
                                    location: location, absentShown: absentShown, milliseconds: milliseconds, margin: margin,
                                    top: Array(paths.prefix(3))))
    }
    await EmbeddingService.search.stop()

    // Report.
    let tags = eval.queries.map(\.tag).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    print("\n\(counts.files) files, \(counts.segments) vectors; photo \(budgets.photo), screenshot \(budgets.screenshot), page \(budgets.page), frame \(budgets.frame) tokens\(indexSeconds.map { String(format: "; indexed in %.0f s", $0) } ?? "")")
    print("tag                 n    R@1    R@5   R@10    MRR  nDCG@10  margin  location  must-not-appear")
    var overall = Summary()
    for tag in tags {
        var s = Summary()
        for o in outcomes where o.tag == tag { s.add(o) }
        print(s.line(tag))
    }
    for o in outcomes { overall.add(o) }
    print(String(repeating: "-", count: 84))
    print(overall.line("all"))
    let times = outcomes.map(\.milliseconds).sorted()
    print(String(format: "search time: median %.0f ms, slowest %.0f ms", times[times.count / 2], times.last ?? 0))

    let misses = outcomes.filter {
        ($0.expectedFiles > 0 && $0.reciprocalRank < 1) || $0.location == false || !$0.absentShown.isEmpty
    }
    if !misses.isEmpty {
        print("\nNot first, wrong place or showing what it mustn't (\(misses.count)):")
        for o in misses {
            let rank = o.ranks.first.map { "first right answer at \($0)" } ?? "no right answer in the results"
            let place = o.location == false ? ", wrong page or moment" : ""
            let absent = o.absentShown.isEmpty ? "" : ", shows \(o.absentShown.joined(separator: ", "))"
            print("  [\(o.tag)] \"\(o.q)\": \(rank)\(place)\(absent)")
            print("      top: \(o.top.joined(separator: " | "))")
        }
    }

    let report = EvalReport(label: option("--label") ?? indexURL.deletingPathExtension().lastPathComponent,
                            date: ISO8601DateFormatter().string(from: Date()), budgets: budgets,
                            profile: MemoryProfile.current.rawValue, indexSeconds: indexSeconds,
                            files: counts.files, vectors: counts.segments, outcomes: outcomes)
    if let out = option("--json") {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: out))
        print("\nSaved \(out)")
    }
    if let baselinePath = option("--baseline") {
        let baseline = try JSONDecoder().decode(EvalReport.self, from: Data(contentsOf: URL(fileURLWithPath: baselinePath)))
        compare(report, against: baseline, tags: tags)
    }
}

extension EvalOutcome {
    /// Whether the hit points where the query says: the page or slide ("#5"), or the moment ("@30-60"). A frame
    /// counts within 3 s of the range; a sound window counts when at least half of it (or of a shorter range) overlaps.
    fileprivate static func located(_ result: SearchResult, _ place: String) -> Bool {
        if place.hasPrefix("#"), let page = Int(place.dropFirst()) {
            return (result.segmentKind == .page || result.segmentKind == .pageImage) && Int(result.locator) + 1 == page
        }
        let bounds = place.dropFirst().split(separator: "-").compactMap { Double($0) }
        guard bounds.count == 2, let seconds = result.seconds else { return false }
        let (from, to) = (bounds[0], bounds[1])
        if result.segmentKind == .frame { return seconds >= from - 3 && seconds <= to + 3 }
        // Right when most of the window lies in the range (or the range fills most of a longer window).
        let overlap = min(seconds + MediaReader.window, to) - max(seconds, from)
        return overlap >= min(MediaReader.window, to - from) / 2
    }
}

func compare(_ report: EvalReport, against baseline: EvalReport, tags: [String]) {
    func summary(_ r: EvalReport, _ tag: String?) -> Summary {
        var s = Summary()
        for o in r.outcomes where tag == nil || o.tag == tag { s.add(o) }
        return s
    }
    print("\nAgainst \(baseline.label) (photo \(baseline.budgets.photo), screenshot \(baseline.budgets.screenshot), page \(baseline.budgets.page), frame \(baseline.budgets.frame)):")
    print("tag                 ΔR@1   ΔR@5  ΔR@10   ΔMRR  ΔnDCG@10  Δmargin")
    for tag in tags + [nil] {
        let a = summary(report, tag), b = summary(baseline, tag)
        let n = Double(max(a.n, 1)), m = Double(max(b.n, 1))
        print((tag ?? "all").padding(toLength: 18, withPad: " ", startingAt: 0) + String(format: "%+6.2f %+6.2f %+6.2f %+6.2f   %+6.2f   %+6.3f",
                     a.r1 / n - b.r1 / m, a.r5 / n - b.r5 / m, a.r10 / n - b.r10 / m, a.mrr / n - b.mrr / m, a.ndcg / n - b.ndcg / m,
                     a.margin / n - b.margin / m))
    }
    if let now = report.indexSeconds, let before = baseline.indexSeconds {
        print(String(format: "indexing time: %.0f s against %.0f s", now, before))
    }
    let old = Dictionary(uniqueKeysWithValues: baseline.outcomes.map { ($0.q, $0) })
    let changed = report.outcomes.filter { old[$0.q].map { $0.reciprocalRank } != $0.reciprocalRank }
    if !changed.isEmpty {
        print("Queries whose first right answer moved:")
        for o in changed {
            let before = old[o.q]?.ranks.first.map(String.init) ?? "none", after = o.ranks.first.map(String.init) ?? "none"
            print("  [\(o.tag)] \"\(o.q)\": \(before) → \(after)")
        }
    }
}
