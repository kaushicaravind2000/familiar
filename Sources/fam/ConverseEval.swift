import Foundation
import FamiliarCore

// fam converse-eval <conversations.json> [--naive] [--json <out>]
// Asks each conversation turn by turn, as the Chat page does, and scores every answer: the facts it must state,
// claims it must not make, whether it cites a passage from the right file, and whether it cites anything at all.
// Follow-ups are scored apart from first questions: they're what the conversation logic is for.

private struct ConversationFile: Decodable { let conversations: [Conversation] }
private struct Conversation: Decodable { let id: String; let turns: [ConversationTurn] }
private struct ConversationTurn: Decodable {
    let q: String
    let facts: [[String]]?
    let forbid: [String]?
    let gold: [String]?
    /// Not in the files: the right answer is "I couldn't find that".
    let none: Bool?
}

private struct TurnOutcome: Encodable {
    let conversation: String
    let index: Int
    let question: String
    let standalone: String
    let searches: [String]
    let carried: Int
    let answer: String
    let correct: Bool
    let citedRight: Bool?
    let unsupported: Bool
    let seconds: Double
}

func runConverseEval(_ arguments: [String]) async throws {
    guard let path = arguments.first(where: { !$0.hasPrefix("--") }) else {
        print("usage: fam converse-eval <conversations.json> [--naive] [--json <out>]"); exit(2)
    }
    let naive = arguments.contains("--naive")
    let jsonOut = arguments.firstIndex(of: "--json").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    let file = try JSONDecoder().decode(ConversationFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let db = try Catalog()
    let asker = Asker(db: db, searcher: Lookup(db: db, embedder: .search))
    asker.planning = !naive

    var outcomes: [TurnOutcome] = []
    for conversation in file.conversations {
        var history: [Asker.Exchange] = []
        for (index, turn) in conversation.turns.enumerated() {
            let started = Date()
            let asked = try await asker.ask(turn.q, history: history, scope: nil)
            var raw = ""
            for try await piece in asked.answer { raw += piece }
            let checked = Asker.checked(raw, passageCount: asked.passages.count)
            let text = normalized(checked.text)
            let refused = text.contains("couldn't find") || text.contains("could not find")
            // A copy of the last answer for a different question is wrong even if it happens to contain the facts.
            let repeated = history.last.map { opening($0.answer) == opening(checked.text) && !opening(checked.text).isEmpty } ?? false
            let correct: Bool
            if repeated {
                correct = false
            } else if turn.none == true {
                correct = refused
            } else {
                let facts = (turn.facts ?? []).allSatisfy { group in group.contains { text.contains(normalized($0)) } }
                let forbidden = (turn.forbid ?? []).contains { text.contains(normalized($0)) }
                correct = facts && !forbidden && !refused
            }
            var citedRight: Bool?
            if let gold = turn.gold, !gold.isEmpty, turn.none != true {
                let cited = Asker.citations(in: checked.text)
                let paths = asked.passages.filter { cited.contains($0.number) }.map(\.source.path)
                citedRight = paths.contains { p in gold.contains { p.hasSuffix("/" + $0) } }
            }
            let outcome = TurnOutcome(conversation: conversation.id, index: index, question: turn.q,
                                      standalone: asked.plan.standalone, searches: asked.plan.searches, carried: asked.carried,
                                      answer: checked.text, correct: correct, citedRight: citedRight,
                                      unsupported: checked.unsupported && turn.none != true, seconds: Date().timeIntervalSince(started))
            outcomes.append(outcome)
            let mark = correct ? "ok " : (repeated ? "REP" : "BAD")
            let cite = citedRight.map { $0 ? "cite ok " : "cite BAD" } ?? "        "
            print("\(mark) \(cite) \(conversation.id)#\(index + 1) \(String(format: "%4.1fs", outcome.seconds))  \(turn.q)")
            if !correct || citedRight == false {
                if asked.plan.standalone != turn.q { print("        in full: \(asked.plan.standalone)") }
                print("        searched: \(asked.plan.searches.joined(separator: " | "))\(asked.carried > 0 ? " (+\(asked.carried) carried)" : "")")
                print("        answer: \(checked.text.replacingOccurrences(of: "\n", with: " ").prefix(220))")
            }
            history.append(Asker.Exchange(question: turn.q, answer: checked.text, passages: asked.passages))
        }
    }
    await EmbeddingService.search.stop()
    await ChatService.shared.stop()

    func line(_ label: String, _ rows: [TurnOutcome]) {
        guard !rows.isEmpty else { return }
        let cited = rows.compactMap(\.citedRight)
        let seconds = rows.map(\.seconds).sorted()
        print(String(format: "%-12@ %2d/%-2d right   cites the right file %2d/%-2d   uncited %d   median %.1f s",
                     label as NSString, rows.filter(\.correct).count, rows.count, cited.filter { $0 }.count, cited.count,
                     rows.filter(\.unsupported).count, seconds[seconds.count / 2]))
    }
    print("\n\(naive ? "naive (one rewrite, one search)" : "planned (plan, merged searches, carried passages)")")
    line("first", outcomes.filter { $0.index == 0 })
    line("follow-ups", outcomes.filter { $0.index > 0 })
    line("all", outcomes)
    if let jsonOut {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(outcomes).write(to: URL(fileURLWithPath: jsonOut))
        print("Saved \(jsonOut)")
    }
}

/// The first 100 characters without citations or spacing differences.
private func opening(_ text: String) -> String {
    String(text.lowercased().replacingOccurrences(of: "\\[\\d+\\]", with: "", options: .regularExpression)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(100))
}

/// Lowercased, curly quotes straightened, citations and the commas inside numbers (21,240; 10,00,000) removed.
private func normalized(_ text: String) -> String {
    var s = text.lowercased().replacingOccurrences(of: "’", with: "'")
    s = s.replacingOccurrences(of: "\\[\\d+\\]", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?<=\\d),(?=\\d)", with: "", options: .regularExpression)
    return s
}
