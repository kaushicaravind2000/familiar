import Accelerate
import Foundation
import Int8Kernels

/// The arithmetic of search, shared by `Lookup` and `fam bench-vectors` so the benchmark times exactly what the app runs.
///
/// Full precision: every stored vector is a row of 32-bit floats in one block, and one matrix-vector product
/// (Accelerate's `cblas_sgemv`) scores them all. Compact: each row is 8-bit integers plus one scale (its largest value
/// maps to ±127), the query is rounded the same way, and the dot products are summed as 32-bit integers on every core
/// with the NEON int8 dot-product instruction (`int8_scores`, in C); the best candidates are then rescored exactly (`dot`). The top rows are picked with a small heap (`best`).
public enum VectorKernels {
    /// Every row's score against `query`: `rows` vectors of `dimension` floats, row after row.
    public static func exactScores(_ matrix: UnsafeBufferPointer<Float>, rows: Int, dimension: Int, query: [Float]) -> [Float] {
        var scores = [Float](repeating: 0, count: rows)
        guard rows > 0 else { return scores }
        query.withUnsafeBufferPointer { q in
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(dimension), 1, matrix.baseAddress, Int32(dimension),
                        q.baseAddress, 1, 0, &scores, 1)
        }
        return scores
    }

    /// Every 8-bit row's approximate score against `query`, in up to `parallelism` chunks at once (a chunk is at least
    /// 2,048 rows, so small searches stay on one core).
    public static func approximateScores(_ quantized: UnsafeBufferPointer<Int8>, scales: UnsafeBufferPointer<Float>,
                                         rows: Int, dimension: Int, query: [Float], parallelism: Int = 16) -> [Float] {
        let (q, queryScale) = quantize(query[...])
        var scores = [Float](repeating: 0, count: rows)
        guard rows > 0 else { return scores }
        let chunks = min(max(1, parallelism), max(1, rows / 2048))
        q.withUnsafeBufferPointer { qv in
            scores.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    int8_scores(quantized.baseAddress, scales.baseAddress, rows * chunk / chunks, rows * (chunk + 1) / chunks,
                                dimension, qv.baseAddress, queryScale, out.baseAddress)
                }
            }
        }
        return scores
    }

    /// A vector as 8-bit integers and the scale that turns them back: its largest value maps to ±127.
    public static func quantize(_ vector: ArraySlice<Float>) -> ([Int8], Float) {
        let largest = vector.reduce(0) { max($0, abs($1)) }
        guard largest > 0 else { return ([Int8](repeating: 0, count: vector.count), 0) }
        let scale = largest / 127
        return (vector.map { Int8(max(-127, min(127, ($0 / scale).rounded()))) }, scale)
    }

    /// The exact score of one vector.
    public static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(count))
        return result
    }

    /// The rows with the `count` highest scores, best first, leaving out `skipping`. Only those few are kept in order,
    /// in a small heap, instead of sorting every score: at a million rows the full sort took 125 ms.
    public static func best(_ count: Int, of scores: [Float], skipping: Set<Int> = []) -> [Int] {
        guard count > 0 else { return [] }
        // A min-heap: the weakest score kept so far is at the top, and anything not above it is passed over.
        var heap: [(score: Float, row: Int)] = []
        heap.reserveCapacity(min(count, scores.count))
        func siftDown(_ start: Int) {
            var i = start
            while true {
                let left = 2 * i + 1, right = left + 1
                var smallest = i
                if left < heap.count && heap[left].score < heap[smallest].score { smallest = left }
                if right < heap.count && heap[right].score < heap[smallest].score { smallest = right }
                if smallest == i { return }
                heap.swapAt(i, smallest)
                i = smallest
            }
        }
        scores.withUnsafeBufferPointer { s in
            for row in 0..<s.count {
                let score = s[row]
                if heap.count == count && !(score > heap[0].score) { continue }
                if skipping.contains(row) { continue }
                if heap.count < count {
                    heap.append((score, row))
                    var i = heap.count - 1
                    while i > 0 && heap[(i - 1) / 2].score > heap[i].score {
                        heap.swapAt(i, (i - 1) / 2)
                        i = (i - 1) / 2
                    }
                } else {
                    heap[0] = (score, row)
                    siftDown(0)
                }
            }
        }
        return heap.sorted { $0.score > $1.score }.map(\.row)
    }
}
