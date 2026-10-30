import Foundation

/// Recorded meetings, each saved as one Markdown file in the Meetings folder: your notes and the timed, speaker-labelled
/// transcript. The folder is one of your sources, so meetings are indexed like any other file: found by search,
/// quoted by Ask. The audio sits beside them in a hidden `.recordings` folder (hidden files aren't indexed, so it isn't
/// read twice).
public enum Meetings {
    /// ~/Documents/Familiar Meetings. `FAMILIAR_MEETINGS` points a test copy elsewhere.
    public static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["FAMILIAR_MEETINGS"] { return URL(fileURLWithPath: path, isDirectory: true) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Familiar Meetings", isDirectory: true)
    }
    public static var recordings: URL { folder.appendingPathComponent(".recordings", isDirectory: true) }

    public struct Line: Sendable, Hashable {
        public let start: Double
        public let speaker: String
        public let text: String
        public init(start: Double, speaker: String, text: String) { self.start = start; self.speaker = speaker; self.text = text }
    }

    public struct Meeting: Sendable, Identifiable, Hashable {
        public var id: String { url.path }
        public let url: URL
        public var title: String
        public var date: Date
        public var duration: Double
        public var notes: String
        public var lines: [Line]
        /// The folder holding me.m4a and others.m4a, if the audio was kept.
        public var audio: URL?
        public init(url: URL, title: String, date: Date, duration: Double, notes: String, lines: [Line], audio: URL?) {
            self.url = url; self.title = title; self.date = date; self.duration = duration
            self.notes = notes; self.lines = lines; self.audio = audio
        }
    }

    /// "2026-10-23 15.30 Weekly sync": sorts by date in Finder, and says what it is.
    public static func baseName(title: String, date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm"
        let safe = title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return format.string(from: date) + " " + (safe.isEmpty ? "Meeting" : String(safe.prefix(80)))
    }

    public static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - The file

    /// The Markdown file. The front matter says it's a meeting (for the Meetings page); the rest reads well anywhere.
    public static func markdown(_ m: Meeting) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let human = DateFormatter()
        human.dateStyle = .long
        human.timeStyle = .short
        var out = "---\nfamiliar: meeting\ntitle: \(m.title.replacingOccurrences(of: "\n", with: " "))\ndate: \(iso.string(from: m.date))\nduration: \(Int(m.duration))\n"
        if let audio = m.audio { out += "audio: \(audio.path.replacingOccurrences(of: folder.path + "/", with: ""))\n" }
        out += "---\n\n# \(m.title)\n\n\(human.string(from: m.date)) · \(max(1, Int((m.duration / 60).rounded()))) min\n\n"
        let notes = m.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { out += "## Notes\n\n\(notes)\n\n" }
        out += "## Transcript\n\n"
        out += m.lines.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        return out + "\n"
    }

    public static func save(_ m: Meeting) throws {
        try FileManager.default.createDirectory(at: m.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown(m).write(to: m.url, atomically: true, encoding: .utf8)
    }

    /// Reads a meeting file back; nil for any other Markdown file.
    public static func load(_ url: URL) -> Meeting? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---\n") else { return nil }
        let parts = text.components(separatedBy: "\n---\n")
        guard parts.count >= 2 else { return nil }
        var front: [String: String] = [:]
        for line in parts[0].dropFirst(4).split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            front[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard front["familiar"] == "meeting" else { return nil }
        let body = parts.dropFirst().joined(separator: "\n---\n")
        var notes = ""
        if let n = body.range(of: "## Notes\n") {
            let end = body.range(of: "\n## Transcript", range: n.upperBound..<body.endIndex)?.lowerBound ?? body.endIndex
            notes = String(body[n.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines: [Line] = []
        if let t = body.range(of: "## Transcript\n") {
            let pattern = try! NSRegularExpression(pattern: #"^\[(?:(\d+):)?(\d+):(\d+)\] ([^:]{1,40}): (.*)$"#)
            for raw in body[t.upperBound...].split(separator: "\n") {
                let line = String(raw)
                let ns = line as NSString
                guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
                func n(_ i: Int) -> Double { m.range(at: i).location == NSNotFound ? 0 : Double(ns.substring(with: m.range(at: i))) ?? 0 }
                lines.append(Line(start: n(1) * 3600 + n(2) * 60 + n(3), speaker: ns.substring(with: m.range(at: 4)), text: ns.substring(with: m.range(at: 5))))
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return Meeting(url: url, title: front["title"] ?? url.deletingPathExtension().lastPathComponent,
                       date: front["date"].flatMap(iso.date(from:)) ?? Date.distantPast,
                       duration: Double(front["duration"] ?? "") ?? 0, notes: notes, lines: lines,
                       audio: front["audio"].map { folder.appendingPathComponent($0, isDirectory: true) })
    }

    /// Every meeting in the folder, newest first.
    public static func all() -> [Meeting] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.compactMap(load).sorted { $0.date > $1.date }
    }

    public static func isMeetingFile(_ path: String) -> Bool {
        path.hasPrefix(folder.path + "/") && path.hasSuffix(".md")
    }

    // MARK: - Two tracks into one transcript

    /// Your microphone ("Me") and the Mac's sound (everyone else) into one transcript in time order. Without
    /// headphones the microphone also hears the others from the speakers: a microphone line that says what a system
    /// line says at the same moment is that echo, and is dropped. System speakers are "Speaker 1", "Speaker 2"; when
    /// there's only one, "Others". With no system track (macOS before 14.2, or not allowed), the microphone track's
    /// own speaker labels are used.
    public static func merge(me: [Transcriber.Line], others: [Transcriber.Line], hasSystemTrack: Bool) -> [Line] {
        func names(_ lines: [Transcriber.Line], single: String) -> [String: String] {
            let ids = Array(Set(lines.compactMap(\.speaker))).sorted()
            if ids.count <= 1 { return Dictionary(uniqueKeysWithValues: ids.map { ($0, single) }) }
            return Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "Speaker \($0 + 1)") })
        }
        guard hasSystemTrack else {
            let labels = names(me, single: "Me")
            return me.map { Line(start: $0.start, speaker: $0.speaker.flatMap { labels[$0] } ?? "Me", text: $0.text) }
        }
        let labels = names(others, single: "Others")
        let theirs = others.map { Line(start: $0.start, speaker: $0.speaker.flatMap { labels[$0] } ?? "Others", text: $0.text) }
        let mine = me.filter { line in
            let words = Self.words(line.text)
            guard words.count >= 2 else { return true }
            return !others.contains { other in
                abs(other.start - line.start) < 4 || (line.start < other.end + 2 && other.start < line.end + 2)
                    ? Double(words.intersection(Self.words(other.text)).count) / Double(words.count) >= 0.6 : false
            }
        }.map { Line(start: $0.start, speaker: "Me", text: $0.text) }
        return (mine + theirs).sorted { $0.start < $1.start }
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
