import Foundation
import FamiliarCore

/// `fam bench-vectors [--sizes 10000,100000,1000000] [--queries 200] [--threads n] [--json <out>]`: what 8-bit vectors
/// with exact rescoring cost and save, on this machine, with the app's own search kernels (`VectorKernels`).
///
/// Data: clustered synthetic vectors of EmbeddingGemma 2's size (768), seeded, so every machine searches the same
/// numbers: 2,000 random centres, each vector a centre plus noise (cosine ~0.7 to its centre), normalised (embeddings
/// are compared as unit vectors). Queries are vectors from the set with more noise (cosine ~0.6 to their source): each
/// has a few close neighbours and a long tail of unrelated ones, like a real search. No files, no model, nothing from the index.
///
/// For each size it reports memory (float32 rows; int8 rows plus one float32 scale each), the time per query of:
///   float32  one matrix-vector product over every row (Accelerate), then the top 10
///   int8     integer dot products on every core (the NEON SDOT kernel, Int8Kernels), then the top 10 by those scores
///   int8+rs  int8, then the best `shortlist` rescored exactly from float32, then the top 10 (what the app does; the app
///            reads the shortlist's float32 vectors from its index on disk, here they're in memory)
/// and how many of float32's top 10 each finds (agreement), and how long picking the top 1,000 takes with the heap
/// against a full sort. `--threads 1` keeps the int8 kernel on one thread; set `VECLIB_MAXIMUM_THREADS=1` for
/// Accelerate's. Run under `taskpolicy -b` to keep it on the efficiency cores.
func benchVectors(_ arguments: [String]) throws {
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    let sizes = (option("--sizes") ?? "10000,100000,1000000").split(separator: ",").compactMap { Int($0) }
    let queryCount = Int(option("--queries") ?? "") ?? 200
    let threads = Int(option("--threads") ?? "") ?? 16
    let shortlist = 1000
    let dimension = EmbeddingService.dimension

    print(machineHeader(threads: threads))
    print("\(dimension)-dimension vectors, \(queryCount) queries per size, top 10, shortlist \(shortlist)\n")
    print("rows        float32 MB  int8 MB   float32 ms      int8 ms         int8+rs ms      agree int8  agree int8+rs  top-1000 heap / sort ms")
    var report: [[String: Any]] = []

    var random = SplitMix(seed: 768)
    let centres = (0..<2000).map { _ in normalised((0..<dimension).map { _ in random.normal() }) }

    for rows in sizes {
        // The set: centre + noise, normalised, written straight into one block of float32 rows.
        var matrix = [Float](repeating: 0, count: rows * dimension)
        matrix.withUnsafeMutableBufferPointer { m in
            for r in 0..<rows {
                let centre = centres[Int(random.next() % UInt64(centres.count))]
                var norm: Float = 0
                for k in 0..<dimension {
                    let v = centre[k] + random.normal() / Float(dimension).squareRoot()
                    m[r * dimension + k] = v
                    norm += v * v
                }
                let inverse = 1 / norm.squareRoot()
                for k in 0..<dimension { m[r * dimension + k] *= inverse }
            }
        }
        // The same rows in 8 bits.
        var quantized = [Int8](repeating: 0, count: rows * dimension)
        var scales = [Float](repeating: 0, count: rows)
        for r in 0..<rows {
            let (q, scale) = VectorKernels.quantize(matrix[r * dimension ..< (r + 1) * dimension])
            quantized.replaceSubrange(r * dimension ..< (r + 1) * dimension, with: q)
            scales[r] = scale
        }
        let queries: [[Float]] = (0..<queryCount).map { _ in
            let r = Int(random.next() % UInt64(rows))
            return normalised((0..<dimension).map { matrix[r * dimension + $0] + 1.3 * random.normal() / Float(dimension).squareRoot() })
        }

        var bestScores: [Float] = [], tenthScores: [Float] = [], typicalScores: [Float] = []
        var f32Times: [Double] = [], int8Times: [Double] = [], rescoredTimes: [Double] = []
        var heapTimes: [Double] = [], sortTimes: [Double] = []
        var agreeInt8 = 0, agreeRescored = 0
        matrix.withUnsafeBufferPointer { m in
            quantized.withUnsafeBufferPointer { qm in
                scales.withUnsafeBufferPointer { s in
                    for (i, query) in queries.enumerated() {
                        var started = Date()
                        let exact = VectorKernels.exactScores(m, rows: rows, dimension: dimension, query: query)
                        let truth = VectorKernels.best(10, of: exact)
                        f32Times.append(Date().timeIntervalSince(started))
                        bestScores.append(exact[truth[0]]); tenthScores.append(exact[truth[9]])
                        typicalScores.append(exact[Int(UInt(bitPattern: i &* 7919) % UInt(rows))])

                        started = Date()
                        let approximate = VectorKernels.approximateScores(qm, scales: s, rows: rows, dimension: dimension,
                                                                          query: query, parallelism: threads)
                        let int8Top = VectorKernels.best(10, of: approximate)
                        int8Times.append(Date().timeIntervalSince(started))

                        started = Date()
                        let again = VectorKernels.approximateScores(qm, scales: s, rows: rows, dimension: dimension,
                                                                    query: query, parallelism: threads)
                        let candidates = VectorKernels.best(shortlist, of: again)
                        let rescored: [(row: Int, score: Float)] = query.withUnsafeBufferPointer { q in
                            candidates.map { ($0, VectorKernels.dot(m.baseAddress! + $0 * dimension, q.baseAddress!, count: dimension)) }
                        }
                        let rescoredTop = rescored.sorted { $0.score > $1.score }.prefix(10).map(\.row)
                        rescoredTimes.append(Date().timeIntervalSince(started))

                        agreeInt8 += Set(truth).intersection(int8Top).count
                        agreeRescored += Set(truth).intersection(rescoredTop).count

                        if i < 20 {   // top 1,000: heap against a full sort, on the exact scores
                            started = Date()
                            _ = VectorKernels.best(1000, of: exact)
                            heapTimes.append(Date().timeIntervalSince(started))
                            started = Date()
                            _ = exact.indices.sorted { exact[$0] > exact[$1] }.prefix(1000)
                            sortTimes.append(Date().timeIntervalSince(started))
                        }
                    }
                }
            }
        }
        let f32MB = Double(rows * dimension * 4) / 1_048_576
        let int8MB = Double(rows * dimension + rows * 4) / 1_048_576
        let total = Double(queryCount * 10)
        func ms(_ t: [Double]) -> String {
            let sorted = t.sorted()
            return String(format: "%6.2f (p95 %5.1f)", sorted[sorted.count / 2] * 1000, sorted[min(sorted.count - 1, sorted.count * 95 / 100)] * 1000)
        }
        print(String(format: "%-10d  %9.1f  %7.1f  ", rows, f32MB, int8MB) + ms(f32Times) + "  " + ms(int8Times) + "  " + ms(rescoredTimes)
              + String(format: "  %9.1f%%  %12.1f%%  %8.2f / %.2f", 100 * Double(agreeInt8) / total, 100 * Double(agreeRescored) / total,
                       median(heapTimes) * 1000, median(sortTimes) * 1000))
        func middle(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
        print(String(format: "            scores (cosine): best %.2f, 10th %.2f, a random row %.2f", middle(bestScores), middle(tenthScores), middle(typicalScores)))
        report.append(["bestScore": middle(bestScores), "tenthScore": middle(tenthScores), "randomRowScore": middle(typicalScores),
                       "rows": rows, "float32MB": f32MB, "int8MB": int8MB,
                       "float32Ms": median(f32Times) * 1000, "int8Ms": median(int8Times) * 1000, "int8RescoredMs": median(rescoredTimes) * 1000,
                       "agreeInt8": Double(agreeInt8) / total, "agreeInt8Rescored": Double(agreeRescored) / total,
                       "heapTop1000Ms": median(heapTimes) * 1000, "sortTop1000Ms": median(sortTimes) * 1000])
    }
    if let path = option("--json") {
        let data = try JSONSerialization.data(withJSONObject: ["machine": machineHeader(threads: threads), "dimension": dimension,
                                                               "queries": queryCount, "shortlist": shortlist, "results": report],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
        print("\nSaved \(path)")
    }
}

/// The chip, its cores, memory, macOS, and how this run was limited: what a reader needs to compare.
private func machineHeader(threads: Int) -> String {
    func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
    func sysctlInt(_ name: String) -> Int {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }
    let performance = sysctlInt("hw.perflevel0.physicalcpu"), efficiency = sysctlInt("hw.perflevel1.physicalcpu")
    let memory = sysctlInt("hw.memsize") / 1_073_741_824
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let accelerate = ProcessInfo.processInfo.environment["VECLIB_MAXIMUM_THREADS"].map { ", Accelerate threads \($0)" } ?? ""
    let background = Thread.current.qualityOfService == .background ? ", background (efficiency cores)" : ""
    return "\(sysctlString("machdep.cpu.brand_string")), \(performance) performance + \(efficiency) efficiency cores, \(memory) GB, "
        + "macOS \(os.majorVersion).\(os.minorVersion); int8 threads \(threads)\(accelerate)\(background)"
}

private func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }

private func normalised(_ v: [Float]) -> [Float] {
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? v.map { $0 / norm } : v
}

/// A small seeded generator, so every machine benchmarks the same vectors.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Roughly normal (the sum of four uniforms, centred and scaled to variance 1): fast and plenty for noise.
    mutating func normal() -> Float {
        var sum: Float = 0
        for _ in 0..<4 { sum += Float(next() >> 40) / Float(1 << 24) }
        return (sum - 2) * 1.7320508
    }
}
