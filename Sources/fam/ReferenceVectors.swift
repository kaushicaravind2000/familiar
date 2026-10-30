import Foundation
import FamiliarCore

/// `fam selftest-vectors [--write]`: the model must keep making the same vectors. A fixed set of inputs (texts, a
/// photo, a screenshot, 30 s of speech, all from the test collection) is embedded and compared with the vectors stored
/// in evals/reference-vectors.json; any input below 0.999 cosine fails. Run it after updating llama.cpp or the model:
/// a change there could otherwise shift results without anyone noticing. `--write` stores the current vectors as the
/// reference (do that only on purpose, with a reason).
func referenceVectors(_ arguments: [String]) async throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let store = repo.appendingPathComponent("evals/reference-vectors.json")
    // The inputs are kept as files, copied once from the test collection: regenerating that collection respeaks the
    // audio (say + AAC aren't byte-identical run to run), which would look like a model change.
    let fixed = repo.appendingPathComponent("evals/reference-inputs")
    let fm = FileManager.default
    if arguments.contains("--write") || !fm.fileExists(atPath: fixed.appendingPathComponent("speech.wav").path) {
        let testbed = repo.appendingPathComponent("build/testbed")
        guard fm.fileExists(atPath: testbed.path) else { print("No test collection: run scripts/make-test-collection.sh first."); exit(1) }
        try fm.createDirectory(at: fixed, withIntermediateDirectories: true)
        for (from, to) in [("img/Animals-Zebra.jpg", "photo.jpg"), ("screenshots/Screenshot 2026-10-01 at 10.12.33.png", "screenshot.png")] {
            try? fm.removeItem(at: fixed.appendingPathComponent(to))
            try fm.copyItem(at: testbed.appendingPathComponent(from), to: fixed.appendingPathComponent(to))
        }
        let windows = try await MediaReader.audioWindows(testbed.appendingPathComponent("audio/podcast.m4a"))
        try windows[0].wav.write(to: fixed.appendingPathComponent("speech.wav"))
    }
    let budgets = ImageBudgets.current
    func picture(_ name: String, budget: Int) throws -> EmbeddingInput {
        guard let image = ImagePrep.load(fixed.appendingPathComponent(name), maxSide: ImagePrep.loadSide),
              let data = ImagePrep.encode(image, budget: budget) else { throw ReadError.unreadable(name) }
        return .image(data, mime: ImagePrep.mime)
    }
    let inputs: [(String, EmbeddingInput)] = [
        ("query", .text(Prompts.query("a dog on the beach"))),
        ("document", .text(Prompts.document(title: "lease", text: "Tenants may keep one cat or one small dog under 10 kg."))),
        ("hindi", .text(Prompts.document(title: nil, text: "मसूर दाल बनाने की विधि"))),
        ("photo", try picture("photo.jpg", budget: budgets.photo)),
        ("screenshot", try picture("screenshot.png", budget: budgets.screenshot)),
        ("speech", .audio(try Data(contentsOf: fixed.appendingPathComponent("speech.wav")))),
    ]
    let vectors = try await EmbeddingService.shared.embed(inputs.map(\.1))
    await EmbeddingService.shared.stop()

    if arguments.contains("--write") {
        var out: [String: [Float]] = [:]
        for ((name, _), vector) in zip(inputs, vectors) { out[name] = vector }
        struct File: Encodable { let model: String; let budgets: ImageBudgets; let vectors: [String: [Float]] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(File(model: "\(EmbeddingModelFiles.repository)@\(EmbeddingModelFiles.revision)", budgets: budgets, vectors: out))
            .write(to: store)
        print("Wrote \(store.path)")
        return
    }
    struct Stored: Decodable { let vectors: [String: [Double]] }
    let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: store))
    var failed = 0
    for ((name, _), vector) in zip(inputs, vectors) {
        guard let vector, let reference = stored.vectors[name] else { print("  \(name): missing"); failed += 1; continue }
        let cosine = zip(vector, reference).reduce(0.0) { $0 + Double($1.0) * $1.1 }
        let ok = cosine >= 0.999
        if !ok { failed += 1 }
        print(String(format: "  %-11@ cosine %.5f %@", name as NSString, cosine, ok ? "ok" : "CHANGED"))
    }
    print(failed == 0 ? "Vectors match the reference." : "\(failed) input(s) changed: results may shift. Check with fam eval before shipping.")
    if failed > 0 { exit(1) }
}
