import Foundation

/// Tidies what push to talk heard before it's pasted: hesitations ("um", "uh") out, a word said twice in a row once,
/// spaces and capitals right. The speech model already writes punctuation and capitals; this only cleans up after
/// the way people talk.
public enum DictationText {
    /// Hesitations, as the model writes them. "Ah" and "oh" stay: they're often meant.
    private static let filler = #"(?:u+m+|u+h+m*|e+r+m+|h+m+|m{2,}|mhm)(?=$|[\s,.!?;:])"#
    /// One that starts a sentence goes with its punctuation ("Hmm. Let's…" → "Let's…").
    private static let leadingFillers = try! NSRegularExpression(
        pattern: #"(?i)(?:^|(?<=[.!?]))\s*"# + filler + #"[,.!?]*"#)
    /// One within a sentence goes with the commas around it ("we should, uh, ship" → "we should ship").
    private static let fillers = try! NSRegularExpression(pattern: #"(?i),?\s*(?<![\w-])"# + filler + #",?"#)
    /// A short word said twice or more in a row ("I I think", "the the"). "had had" and "that that" are often meant.
    private static let repeats = try! NSRegularExpression(pattern: #"(?i)\b([a-z']{1,6})(?:\s+\1\b)+"#)
    private static let keptRepeats: Set = ["had", "that"]

    public static func clean(_ text: String, removeFillers: Bool = true) -> String {
        var s = text
        if removeFillers {
            var before = ""
            while before != s {   // "Um. Uh, so…": one sentence-start filler after another
                before = s
                s = replace(leadingFillers, in: s, with: "")
            }
            s = replace(fillers, in: s, with: "")
            s = repeats.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed().reduce(s) { s, match in
                guard let whole = Range(match.range, in: s), let word = Range(match.range(at: 1), in: s),
                      !keptRepeats.contains(s[word].lowercased()) else { return s }
                return s.replacingCharacters(in: whole, with: String(s[word]))
            }
        }
        // Spaces: one between words, none before punctuation.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" +([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([,;:])\1+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s,;:]+"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        // A sentence that lost its first word to a filler still starts with a capital.
        s = capitalizeSentences(s)
        return s
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext, ch.isLetter {
                out += ch.uppercased(); capitalizeNext = false
            } else {
                out.append(ch)
                if ".!?".contains(ch) { capitalizeNext = true } else if !ch.isWhitespace { capitalizeNext = false }
            }
        }
        return out
    }
}
