import Foundation

/// One numbered piece of a file that an answer may quote: a page, a stretch of a recording, a part of a document.
public struct Passage: Sendable, Identifiable {
    public var id: Int { number }
    public let number: Int
    /// "lease.docx", "handbook.pdf, page 4", "team-meeting.m4a, at 0:15"
    public let label: String
    public let text: String
    /// The search result to open: the file, at this passage's page or moment.
    public let source: SearchResult

    func renumbered(_ n: Int) -> Passage { Passage(number: n, label: label, text: text, source: source) }
}

/// Ask: answers a question from your files, alone or as part of a conversation.
///
///  1. Plan (follow-ups and comparisons): the answer model turns the question into JSON (forced by a grammar, so a
///     small model can't ramble): the question in full ("the car one" → "the car insurance"), 1–3 searches (one per
///     thing compared), and whether it leans on the last answer ("which renews first?", "the second one").
///  2. Passages: each search runs; their rankings merge (reciprocal rank fusion); when the plan leans on the last answer,
///     the passages that answer cited come first, so what was said before can be checked and cited again.
///  3. Answer: the recent turns (within a character budget) and the passages go to the model, which must cite them.
///  4. Check: citations that point at nothing are removed; an answer with no citation is marked as not from your files.
///
/// What the evals taught is built in: every page is its own passage (a "page 4" label got cited as passage [4]),
/// passages are few and relevant (they cost time before the first word), and the model says it couldn't find the
/// answer rather than guess. `planning = false` is the first, simpler version (one free-text rewrite, one search, no
/// carried passages), kept to measure against (`fam converse-eval --naive`).
public final class Asker: @unchecked Sendable {
    private let db: Catalog
    private let searcher: Lookup
    private let chat: ChatService
    /// Files quoted per answer, characters per file, and characters in all: ~3,000 tokens, which fits the answer
    /// model's 8K context with room for the answer (Low: 4K context, so less). At 1,800 per file a two-page letter
    /// lost its second page, and a payslip's long tax page pushed out the page with the net pay.
    public var maxFiles = 6
    public var perFile = 3000
    public var budget = MemoryProfile.current == .low ? 5000 : 10000
    /// Characters of earlier turns the model sees, newest first (Low: less).
    public var historyBudget = MemoryProfile.current == .low ? 1200 : 2400
    public var planning = true

    public init(db: Catalog, searcher: Lookup, chat: ChatService = .shared) {
        self.db = db
        self.searcher = searcher
        self.chat = chat
    }

    public static let refusal = "I couldn't find that in your files."

    /// One set of instructions for everything: a question gets a short cited answer, a request (prepare, write,
    /// summarise) gets done using the passages as material, small talk gets a sentence. Separate modes and a
    /// classifier were tried and misfired ("ok prepare one" taken for small talk); the earlier "one to three sentences"
    /// rule alone made the model repeat itself when asked to prepare something.
    public static let instructions = """
        You help the user with their own files, using the passages below, which come from those files.
        - For a question, answer briefly (one to three sentences, or a short list) and cite the passages you used, \
        like [1] or [2].
        - If they ask you to write, prepare, draft, summarise or plan something, do it fully, using the passages as \
        material, with short headings or bullet points where they help, and cite the passages that informed each part.
        - If the message isn't about their files (hello, thanks), reply in a sentence.
        Use only what the passages say about the user's files and work: earlier answers in this conversation are not \
        sources. If the passages don't contain what's needed, say: \(refusal)
        """

    // MARK: - Conversation

    /// One earlier question and its answer, with the passages that answer was given.
    public struct Exchange: Sendable {
        public let question: String
        public let answer: String
        public let passages: [Passage]
        public init(question: String, answer: String, passages: [Passage] = []) {
            self.question = question; self.answer = answer; self.passages = passages
        }
        /// The passages the answer actually cited.
        var cited: [Passage] {
            let numbers = Asker.citations(in: answer)
            return passages.filter { numbers.contains($0.number) }
        }
    }

    /// What a question needs: itself in full, what to search for, and whether the last answer matters.
    public struct Plan: Sendable, Decodable {
        public let standalone: String
        public let searches: [String]
        public let usesPrevious: Bool
        enum CodingKeys: String, CodingKey { case standalone, searches, usesPrevious = "uses_previous" }
        public init(standalone: String, searches: [String], usesPrevious: Bool) {
            self.standalone = standalone; self.searches = searches; self.usesPrevious = usesPrevious
        }
    }

    /// The result of asking: the plan, the passages, the answer as it's written.
    public struct Turn: Sendable {
        public let plan: Plan
        public let passages: [Passage]
        /// How many of `passages` came from the last answer (they're first).
        public let carried: Int
        public let answer: AsyncThrowingStream<String, Error>
    }

    static let planSchema = """
        {"type":"object","properties":{
          "standalone":{"type":"string"},
          "searches":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3},
          "uses_previous":{"type":"boolean"}},
         "required":["standalone","searches","uses_previous"]}
        """

    static let planInstructions = """
        You plan searches over the user's own files for their last question in a conversation. Reply with JSON:
        - standalone: the last question rewritten so it can be understood alone. Replace it, that, they, them, there, \
        "the car one", "the second one" and similar with exactly what they refer to in the conversation. Keep what \
        the user asks for (a date, an amount, a reason).
        - searches: 1 to 3 short search phrases that would find the facts needed in the files. When the question \
        compares or combines things, one phrase per thing.
        - uses_previous: true when answering needs what the earlier answers said (which of them, the second one, \
        compared with that, more about it, make one of those); false for a new topic.
        """

    /// Worked examples, as earlier turns: a small model follows examples better than rules.
    static let planExamples: [(String, String)] = [
        ("Conversation:\nQ: When does my bike insurance expire?\nA: It expires on 7 October 2026 [1].\n\nLast question: and the policy number?",
         #"{"standalone":"What is the policy number of my bike insurance?","searches":["bike insurance policy number"],"uses_previous":false}"#),
        ("Conversation:\nQ: When does my passport expire?\nA: On 2 May 2029 [1].\nQ: And my driving licence?\nA: On 9 June 2031 [2].\n\nLast question: which one expires first?",
         #"{"standalone":"Which expires first, my passport (2 May 2029) or my driving licence (9 June 2031)?","searches":["passport expiry date","driving licence expiry date"],"uses_previous":true}"#),
        ("Conversation:\nQ: Which laptops do we have?\nA: 1. A MacBook Air [1]. 2. A ThinkPad X1 [2].\n\nLast question: what's the warranty on the second one?",
         #"{"standalone":"What is the warranty on the ThinkPad X1?","searches":["ThinkPad X1 warranty"],"uses_previous":true}"#),
        ("Conversation:\nQ: How long should I boil eggs?\nA: Nine minutes [1].\n\nLast question: what goes into my pasta sauce?",
         #"{"standalone":"What goes into my pasta sauce?","searches":["pasta sauce recipe ingredients"],"uses_previous":false}"#),
        ("Conversation:\n(none)\n\nLast question: Did revenue grow more in Asia or in Europe?",
         #"{"standalone":"Did revenue grow more in Asia or in Europe?","searches":["revenue growth Asia","revenue growth Europe"],"uses_previous":false}"#),
        ("Conversation:\nQ: What makes a good onboarding email?\nA: Short, one clear next step, and a named sender [1].\n\nLast question: ok write one",
         #"{"standalone":"Write an onboarding email that is short, has one clear next step and a named sender","searches":["onboarding email guidelines","welcome email tone and next step"],"uses_previous":true}"#),
    ]

    /// A first question is planned only when it compares things (it may need two searches); otherwise it's searched
    /// as asked, which saves the planning call.
    static func looksComparative(_ question: String) -> Bool {
        let q = " " + question.lowercased() + " "
        return [" or ", " vs", " versus ", "compare", "difference between", " both ", "which is more", "which one"].contains { q.contains($0) }
    }

    /// Plans the question (see the type's notes). Without history and not comparative, or if the model fails, the
    /// question itself is the one search.
    public func plan(_ question: String, after history: [Exchange]) async -> Plan {
        let plain = Plan(standalone: question, searches: [question], usesPrevious: false)
        guard !history.isEmpty || Self.looksComparative(question) else { return plain }
        let conversation = history.isEmpty ? "(none)" : history.suffix(3).map {
            "Q: \($0.question)\nA: \(String($0.answer.prefix(400)))"
        }.joined(separator: "\n")
        var messages = [ChatMessage(.system, Self.planInstructions)]
        for (user, reply) in Self.planExamples {
            messages.append(ChatMessage(.user, user))
            messages.append(ChatMessage(.assistant, reply))
        }
        messages.append(ChatMessage(.user, "Conversation:\n\(conversation)\n\nLast question: \(question)"))
        guard let reply = try? await chat.complete(messages, maxTokens: 160, jsonSchema: Self.planSchema, slot: .planning),
              let plan = try? JSONDecoder().decode(Plan.self, from: Data(reply.utf8)) else {
            return history.last.map { Plan(standalone: question, searches: ["\($0.question) \(question)"], usesPrevious: true) } ?? plain
        }
        let searches = plan.searches.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A rewrite needs some words in it (the planner once answered ":"); otherwise the question stands as asked.
        let rewritten = plan.standalone.trimmingCharacters(in: .whitespaces)
        let standalone = rewritten.filter(\.isLetter).count >= 3 ? rewritten : question
        return Plan(standalone: standalone.isEmpty ? question : standalone,
                    searches: searches.isEmpty ? [standalone.isEmpty ? question : standalone] : Array(searches.prefix(3)),
                    usesPrevious: plan.usesPrevious && !history.isEmpty)
    }

    /// The first, simpler follow-up handling: one free-text rewrite, searched once (`planning = false`).
    private func naivePlan(_ question: String, after history: [Exchange]) async -> Plan {
        guard let last = history.last else { return Plan(standalone: question, searches: [question], usesPrevious: false) }
        let conversation = history.suffix(3).map { "Q: \($0.question)\nA: \(String(Self.withoutCitations($0.answer).prefix(300)))" }
            .joined(separator: "\n")
        let messages = [ChatMessage(.system, """
            Rewrite the user's last question so it can be understood on its own, without the conversation: replace words \
            like it, that, they, them, there, he, she and "the same" with what they refer to. Keep it short and keep the \
            user's wording otherwise. If it already stands on its own, return it unchanged. Reply with the question only.
            """), ChatMessage(.user, "Conversation:\n\(conversation)\n\nLast question: \(question)")]
        var rewritten = "\(last.question) \(question)"
        if let reply = try? await chat.complete(messages, maxTokens: 80, slot: .planning) {
            let line = reply.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'`").union(.whitespaces)) ?? ""
            if line.count >= 3 && line.count <= 300 { rewritten = line }
        }
        return Plan(standalone: rewritten, searches: [rewritten], usesPrevious: false)
    }

    // MARK: - Asking

    /// Finds the passages, then streams the answer (a single question, as the panel asks it).
    public func ask(_ question: String) async throws -> (passages: [Passage], answer: AsyncThrowingStream<String, Error>) {
        let turn = try await ask(question, history: [], scope: nil)
        return (turn.passages, turn.answer)
    }

    /// A question in a conversation, searched within `scope` (a chosen folder or file; nil: everything): the passages
    /// found and the recent turns go to the model with the one set of instructions. Room for a long answer (a draft)
    /// is there; a question still gets a short one, and the model stops when it's done.
    public func ask(_ question: String, history: [Exchange], scope: String?) async throws -> Turn {
        let plan = planning ? await plan(question, after: history) : await naivePlan(question, after: history)
        // What the last answer cited, when this question leans on it; if it cited nothing, its first passages.
        var carry: [Passage] = []
        if planning && plan.usesPrevious, let last = history.last {
            carry = Array((last.cited.isEmpty ? last.passages : last.cited).prefix(4))
        }
        let found = try await passages(for: plan.searches, question: plan.standalone, scope: scope, carry: carry)
        let messages = Self.messages(question: question, passages: found, history: history, standalone: plan.standalone,
                                     historyBudget: historyBudget)
        return Turn(plan: plan, passages: found, carried: min(carry.count, found.count),
                    answer: try await chat.stream(messages, maxTokens: 1500))
    }

    /// Passages for one or more searches. Several rankings merge by reciprocal rank fusion (a file found by two
    /// searches, or high in one, comes first); `carry` goes in front, renumbered; copies are skipped.
    public func passages(for searches: [String], question: String, scope: String? = nil, carry: [Passage] = []) async throws -> [Passage] {
        let asked = Self.words(question + " " + searches.joined(separator: " "))
        var score: [String: Double] = [:]
        var best: [String: (rank: Int, result: SearchResult)] = [:]
        for query in searches {
            var results = try await searcher.search(query, limit: scope == nil ? 20 : 40)
            if let scope { results = results.filter { $0.path == scope || $0.path.hasPrefix(scope + "/") } }
            for (rank, result) in results.enumerated() {
                score[result.path, default: 0] += 1 / Double(60 + rank)
                if best[result.path].map({ rank < $0.rank }) ?? true { best[result.path] = (rank, result) }
            }
        }
        let ranked = best.values.map(\.result).sorted { score[$0.path]! > score[$1.path]! }

        var out: [Passage] = []
        var used = 0
        // Copies of a file (the same PDF saved three times, a photo in two folders) would fill the room with the same
        // words: a passage whose text was already quoted is skipped, and a file of nothing but copies doesn't count.
        var seen = Set<String>()
        // A carried passage was cut for the last question: when the same page turns up again, it's cut again around
        // this one, in the carried passage's place (keyed by file and page: the sick-leave rule was lost when the
        // fresh cut of a page was taken for a copy of the carried one, whose start it shared).
        var carriedAt: [String: Int] = [:]
        for passage in carry where !seen.contains(Self.fingerprint(passage.text)) {
            seen.insert(Self.fingerprint(passage.text))
            carriedAt[Self.place(passage.source.path, passage.label)] = out.count
            out.append(passage.renumbered(out.count + 1))
            used += passage.text.count
        }
        var files = 0
        for result in ranked where files < maxFiles && budget - used > 300 {
            var pieces = (try? pieces(of: result, question: question)) ?? []
            for piece in pieces {
                guard let i = carriedAt[Self.place(piece.source.path, piece.label)] else { continue }
                let text = Self.excerpt(piece.text, length: max(out[i].text.count, 1000), about: asked)
                used += text.count - out[i].text.count
                out[i] = Passage(number: i + 1, label: piece.label, text: text, source: piece.source)
                seen.insert(Self.fingerprint(piece.text))
            }
            pieces = pieces.filter { carriedAt[Self.place($0.source.path, $0.label)] == nil && !seen.contains(Self.fingerprint($0.text)) }
            guard !pieces.isEmpty else { continue }
            files += 1
            for (piece, share) in zip(pieces, Self.shares(pieces.map(\.text.count), room: min(perFile, budget - used))) where share > 0 {
                seen.insert(Self.fingerprint(piece.text))
                let text = Self.excerpt(piece.text, length: share, about: asked)
                out.append(Passage(number: out.count + 1, label: piece.label, text: text, source: piece.source))
                used += text.count
            }
        }
        return out
    }

    /// Where a passage is from: its file and its page, slide or moment.
    static func place(_ path: String, _ label: String) -> String {
        let at = label.range(of: ", ").map { String(label[$0.upperBound...]) } ?? ""
        return path + "#" + at
    }

    /// A piece cut to `length`: the stretch with the most of the question's words, not just the start. A leave
    /// policy's three long pages each got ~1,000 characters, and the sick-leave certificate rule sat past the cut.
    /// The stretch starts at a sentence where it can; "…" marks what was left out.
    static func excerpt(_ text: String, length: Int, about words: Set<String>) -> String {
        guard text.count > length else { return text }
        let chars = Array(text)
        guard !words.isEmpty else { return String(chars[0..<length]) + "…" }
        // Score windows every 100 characters by how many question words they hold.
        var bestStart = 0, bestScore = -1
        var start = 0
        while start < chars.count {
            let window = String(chars[start..<min(start + length, chars.count)])
            let score = Self.words(window).intersection(words).count
            if score > bestScore { bestScore = score; bestStart = start }
            if start + length >= chars.count { break }
            start += 100
        }
        // Back up to the start of the sentence the window begins in (at most 200 characters).
        var from = bestStart
        let floor = max(0, bestStart - 200)
        while from > floor && !".!?\n".contains(chars[from - 1]) { from -= 1 }
        if from == floor && floor > 0 { from = bestStart }
        let to = min(from + length, chars.count)
        let body = String(chars[from..<to]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (from > 0 ? "…" : "") + body + (to < chars.count ? "…" : "")
    }

    /// One search's passages (the CLI's `ask`, tests).
    public func passages(for question: String, scope: String? = nil) async throws -> [Passage] {
        try await passages(for: [question], question: question, scope: scope)
    }

    /// The recent turns, newest kept first, within `historyBudget` characters (their old citations removed: those
    /// numbers belong to old passages), then this question's passages and the question, spelled out in full when it
    /// was a follow-up.
    public static func messages(question: String, passages: [Passage], history: [Exchange] = [], standalone: String? = nil,
                                historyBudget: Int = 2400) -> [ChatMessage] {
        let block = passages.map { "[\($0.number)] \($0.label)\n\($0.text)" }.joined(separator: "\n\n")
        var kept: [Exchange] = []
        var used = 0
        for exchange in history.reversed() {
            let size = exchange.question.count + exchange.answer.count
            if used + size > historyBudget && !kept.isEmpty { break }
            kept.insert(exchange, at: 0)
            used += size
        }
        var out = [ChatMessage(.system, instructions)]
        // The earlier questions, not the earlier answers: the follow-up was already rewritten to stand on its own, and
        // any earlier answer in view (even cut to 300 characters) got copied word for word when the same passages came
        // back ("When is the office move?" after a meeting summary returned the summary again).
        let earlier = kept.suffix(3).map { "- \($0.question)" }.joined(separator: "\n")
        let asked = standalone.map { $0 != question ? "\($0)\n(as typed: \"\(question)\")" : question } ?? question
        // The reminder comes last: the earlier answers above are shown without their old citations, and a small model
        // copied that style (6 of 22 follow-ups uncited in fam converse-eval) until told again here.
        let passagesText = passages.isEmpty ? "(none found)" : block
        let context = earlier.isEmpty ? "" : "Earlier in this conversation the user asked:\n\(earlier)\n\n"
        out.append(ChatMessage(.user, "Passages:\n\n\(passagesText)\n\n\(context)Message: \(asked)\n\nCite the passages you use like [1]."))
        return out
    }

    // MARK: - Citations

    static func withoutCitations(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*\\[\\d+\\]", with: "", options: .regularExpression)
    }

    /// The passage numbers an answer cites: [3], and [1, 2] or [1][2].
    public static func citations(in answer: String) -> Set<Int> {
        let pattern = try! NSRegularExpression(pattern: "\\[(\\d+(?:\\s*,\\s*\\d+)*)\\]")
        let ns = answer as NSString
        var out = Set<Int>()
        for match in pattern.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            for part in ns.substring(with: match.range(at: 1)).split(separator: ",") {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)) { out.insert(n) }
            }
        }
        return out
    }

    /// The answer with citations of passages that don't exist removed, and whether what's left cites nothing although
    /// it isn't the "couldn't find" reply: then it isn't backed by your files, and the window says so.
    public static func checked(_ answer: String, passageCount: Int) -> (text: String, unsupported: Bool) {
        let pattern = try! NSRegularExpression(pattern: "\\s*\\[(\\d+)\\]")
        let ns = answer as NSString
        var text = ""
        var last = 0
        var valid = 0
        for match in pattern.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            text += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let n = Int(ns.substring(with: match.range(at: 1))) ?? 0
            if (1...max(passageCount, 1)).contains(n) && passageCount > 0 { text += ns.substring(with: match.range); valid += 1 }
            last = match.range.location + match.range.length
        }
        text += ns.substring(from: last)
        let refused = text.lowercased().contains("couldn't find") || text.lowercased().contains("could not find")
        // Only a substantive answer is flagged: "Hi!" or "You're welcome." needs no source.
        let substantive = text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80
        return (text, valid == 0 && passageCount > 0 && !refused && substantive)
    }

    /// Splits a file's room between its pieces: a short piece gets all it needs, and what it leaves goes to the
    /// others, so one long page can't crowd out the rest. A cut-off scrap under 200 characters is dropped; a short
    /// piece that fits whole is kept (the testbed handbook's pages are ~100 characters each).
    static func shares(_ lengths: [Int], room: Int) -> [Int] {
        var shares = [Int](repeating: 0, count: lengths.count)
        var open = Array(lengths.indices)
        var left = room
        while !open.isEmpty && left > 0 {
            let even = left / open.count
            let small = open.filter { lengths[$0] - shares[$0] <= even }
            if small.isEmpty {
                for i in open { shares[i] += even }
                left -= even * open.count
                break
            }
            for i in small { left -= lengths[i] - shares[i]; shares[i] = lengths[i] }
            open.removeAll { small.contains($0) }
        }
        return zip(shares, lengths).map { share, length in share >= min(200, length) ? share : 0 }
    }

    /// The same text, however it's spaced or cased.
    static func fingerprint(_ text: String) -> String {
        String(text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(400))
    }

    /// The question's own words (not "what", "my", "the"), for picking a long file's most relevant pages.
    static func words(_ text: String) -> Set<String> {
        let common: Set<String> = ["what", "when", "where", "which", "who", "whom", "whose", "why", "how", "does", "did",
                                   "the", "and", "for", "are", "was", "were", "is", "my", "me", "in", "of", "to", "a",
                                   "an", "on", "at", "do", "i", "it", "this", "that", "with", "from", "about", "have",
                                   "has", "can", "according", "under", "your", "you", "there", "much", "many"]
        // Words with a digit count however short ("Q2" picked slide 1 over the Q2 slide when it was dropped).
        return Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { ($0.count > 2 || ($0.count == 2 && $0.contains { $0.isNumber })) && !common.contains($0) })
    }

    // MARK: - Pieces of a file

    private struct Piece { let label: String; let text: String; let source: SearchResult }

    private func pieces(of result: SearchResult, question: String) throws -> [Piece] {
        let rows = try db.texts(path: result.path).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !rows.isEmpty else { return [] }
        let name = result.name
        func at(_ kind: SegmentKind, _ locator: Double) -> SearchResult {
            SearchResult(path: result.path, fileKind: result.fileKind, score: result.score, segmentKind: kind,
                         locator: locator, snippet: nil, exactMatch: result.exactMatch)
        }

        // A recording or video: its transcript around the moment that matched (the first minute if none did).
        if rows.contains(where: { $0.kind == .audio }) {
            let lines = rows.filter { $0.kind == .audio }
            let whole = lines.reduce(0) { $0 + $1.text.count } <= perFile
            let center = result.seconds ?? 0
            let chosen = whole ? lines : lines.filter { $0.locator >= center - 20 && $0.locator <= center + 60 }
            let picked = chosen.isEmpty ? Array(lines.prefix(12)) : chosen
            let start = picked.first?.locator ?? 0
            let text = picked.map { "[\(SearchResult.clock($0.locator))] \($0.text)" }.joined(separator: "\n")
            return [Piece(label: whole ? name : "\(name), from \(SearchResult.clock(start))", text: text, source: at(.audio, start))]
        }

        // Pages and slides, each its own passage. A short file (3 pages or fewer) is quoted whole, in order: a payslip's
        // net pay is on page 1 even when page 2 matched. A longer one: the page that matched, and the two that share
        // the most words with the question (a notice-period clause, wherever it is).
        if rows.contains(where: { $0.kind == .page }) {
            let byPage = Dictionary(grouping: rows.filter { $0.kind == .page }, by: \.locator)
            let pages = byPage.keys.sorted()
            let word = result.fileKind == .office ? "slide" : "page"
            let ordered: [Double]
            if pages.count <= 3 {
                ordered = pages
            } else {
                let matched = result.page.map(Double.init)
                    ?? (result.segmentKind == .page || result.segmentKind == .pageImage ? result.locator : pages[0])
                let asked = Self.words(question)
                let overlap = { (page: Double) in Self.words(byPage[page]!.map(\.text).joined(separator: " ")).intersection(asked).count }
                let others = pages.filter { $0 != matched && overlap($0) > 0 }.sorted { overlap($0) > overlap($1) }
                ordered = [matched] + others.prefix(2).sorted()
            }
            return ordered.map { page in
                let text = byPage[page]!.map(\.text).joined(separator: "\n")
                let label = pages.count > 1 ? "\(name), \(word) \(Int(page) + 1)" : name
                return Piece(label: label, text: text, source: at(.page, page))
            }
        }

        // A picture's text.
        if rows.allSatisfy({ $0.kind == .image }) {
            return [Piece(label: "\(name) (text in the picture)", text: rows.map(\.text).joined(separator: "\n"), source: result)]
        }

        // A document in chunks (offsets in characters, overlapping by up to 150): the matching chunk and the ones
        // after it, with the overlap trimmed, up to the per-file room.
        let chunks = rows.filter { $0.kind == .text }.sorted { $0.locator < $1.locator }
        let startIndex = chunks.lastIndex { $0.locator <= result.locator } ?? 0
        var text = ""
        var end = -1.0
        for chunk in chunks[startIndex...] where text.count < perFile {
            let overlap = max(0, Int(end - chunk.locator))
            let fresh = overlap > 0 ? String(chunk.text.dropFirst(min(overlap, chunk.text.count))) : chunk.text
            text += (text.isEmpty ? "" : " ") + fresh
            end = chunk.locator + Double(chunk.text.count)
        }
        let label = startIndex > 0 ? "\(name) (part)" : name
        return [Piece(label: label, text: text, source: at(.text, chunks[startIndex].locator))]
    }
}
