import AVFoundation
import CoreML
import FluidAudio
import Foundation

// familiar-speech <audio-or-video> --models <dir> [--json] [--speakers]
// familiar-speech --prepare --models <dir>   load (and so compile) the models once, printing "progress <0…1>" lines
// familiar-speech --serve --models <dir>     keep the models loaded and take JSON lines on stdin:
//     {"cmd":"audio","track":"me","pcm":"<base64 16 kHz mono Int16>"}   stream a track's sound; when something new is
//         heard, a line {"track":"me","lines":[…],"partial":"…"} comes back (lines are finished sentences, partial the
//         one still being spoken)
//     {"cmd":"echo","on":true}                   the meeting also has the call's sound ("others"): the microphone is
//         cleaned of it before it's transcribed (LocalVQE echo cancellation), so the call coming out of the speakers
//         isn't transcribed as "me"
//     {"cmd":"finish","track":"me","id":3}       the track's last words: {"id":3,"track":"me","lines":[…],"done":true}
//     {"cmd":"whole","track":"me","id":6}        the finished track read again as one clip (more accurate than the
//         stream): {"id":6,"track":"me","sentences":[…]}, every sentence of the track, to replace the streamed ones.
//         Without the full-attention encoder installed, {"id":6,"error":…}; the streamed lines stand.
//     {"cmd":"file","id":4,"path":"…","speakers":false}   a whole file: {"id":4,"sentences":[…],"duration":s}
//     {"cmd":"label","id":5,"path":"…","lines":[…]}      who spoke each line of a file: {"id":5,"sentences":[…]}
//   Any failure answers {"id":…,"error":"…"} (or {"track":…,"error":…}).
//   Speech to text with a unified (streaming and offline) 0.6B FastConformer on the Neural Engine, streamed: the
//   encoder reads 0.56 s at a time with 0.56 s of look-ahead, so words arrive about a second after they're said, with
//   punctuation and capitals.
//   The models are the pinned files the app downloaded into <dir> (Models/Speech).
//   --speakers  label who spoke when (pyannote-style offline diarization)
//   A file is read as one clip with the full-attention encoder when it's installed (more accurate than streaming);
//   --stream    stream it instead, as a meeting is heard (for comparing the two)
//   --speech parakeet-unified-en   English: NVIDIA Parakeet Unified 0.6B (the default)
//   --speech nemotron-unified --language <code>   for experiments only (the app doesn't offer it; it was less accurate
//       than Parakeet in English): 25 languages, NVIDIA Nemotron-Labs Unified ASR 0.6B, told which
//       language to expect (en, de, fr, es…; "auto" lets it work it out). One encoder serves every language; each
//       language is its own small joint model (joint-<code>/), the language prompt folded in.

let arguments = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}
let flags: Set = ["--json", "--speakers", "--prepare", "--serve", "--clean", "--stream"]
let valued: Set = ["--models", "--speech", "--language", "--tier"]
let positional = arguments.enumerated().filter { i, a in
    !a.hasPrefix("--") && (i == 0 || !valued.contains(arguments[i - 1]))
}.map(\.element)
let preparing = arguments.contains("--prepare"), serving = arguments.contains("--serve")
guard let modelsPath = value("--models"), let path = positional.first ?? (preparing || serving ? "" : nil) else {
    FileHandle.standardError.write(Data("usage: familiar-speech <file> --models <dir> [--json] [--speakers] | --prepare | --serve\n".utf8))
    exit(2)
}
for a in arguments where a.hasPrefix("--") && !flags.contains(a) && !valued.contains(a) {
    FileHandle.standardError.write(Data("unknown option \(a)\n".utf8)); exit(2)
}
let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
let models = URL(fileURLWithPath: (modelsPath as NSString).expandingTildeInPath, isDirectory: true)
let asJSON = arguments.contains("--json"), speakers = arguments.contains("--speakers"), streamed = arguments.contains("--stream")

func note(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

let speechModel = value("--speech") ?? "parakeet-unified-en"
let language = value("--language") ?? "en"
guard ["parakeet-unified-en", "nemotron-unified"].contains(speechModel) else {
    FileHandle.standardError.write(Data("unknown speech model \(speechModel)\n".utf8)); exit(2)
}

/// The folder FluidAudio loads: Parakeet's as it is; for Nemotron, links to the shared encoder, decoder and vocabulary
/// beside the language's joint (made once, kept with the models so the Neural Engine's compiled copy is reused).
func speechFolder() throws -> URL {
    let folder = models.appendingPathComponent(speechModel)
    guard speechModel == "nemotron-unified" else { return folder }
    let joint = folder.appendingPathComponent("joint-\(language)")
    guard FileManager.default.fileExists(atPath: joint.path) else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "no speech model for the language \(language)"])
    }
    let links = folder.appendingPathComponent("languages/\(language)")
    try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
    let names = ModelNames.ParakeetUnified.self
    let shared = [names.streamingEncoderFile(precision: .int8, contextSuffix: unifiedConfig.contextSuffix),
                  names.decoderFile, names.vocab]
    for (name, target) in shared.map({ ($0, folder.appendingPathComponent($0)) })
        + [(names.jointDecisionFile, joint.appendingPathComponent(names.jointDecisionFile))] {
        let link = links.appendingPathComponent(name)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path { continue }
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }
    return links
}

/// The streaming tier: 70 frames of left context, 7 (0.56 s) per step, 7 of look-ahead. In FluidAudio's sweep it had
/// the lowest word error rate of the streaming tiers (2.25%) at 1.12 s latency. The blank token comes after the
/// vocabulary: 1024 for Parakeet's, 4095 for Nemotron's.
let vocabularySize = (try? Data(contentsOf: models.appendingPathComponent("\(speechModel)/vocab.json")))
    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.count ?? 1024
let tier = (value("--tier") ?? "70_7_7").split(separator: "_").compactMap { Int($0) }
let unifiedConfig = UnifiedConfig(leftFrames: tier[0], chunkFrames: tier[1], rightFrames: tier[2], blankIdx: vocabularySize)
let echoFolder = models.appendingPathComponent("localvqe")
let sampleRate = 16_000

/// The soundtrack of any file AVFoundation plays (m4a, mp3, wav, mov, mp4…) as 16 kHz mono 32-bit floats, the form
/// the models take. AVAssetReader does the resampling and mixing down.
func samples(of url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    var all: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / 4)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        all.append(contentsOf: chunk)
    }
    if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    return all
}

struct Word: Encodable { let word: String; let start: Double; let end: Double }
struct Sentence: Codable { let start: Double; let end: Double; let text: String; var speaker: String? }
struct Run: Encodable {
    let file: String; let duration: Double; let loadSeconds: Double; let transcribeSeconds: Double
    let realTimeFactor: Double; let peakMemoryMB: Double; let computeUnits: String
    let text: String; let sentences: [Sentence]; let words: [Word]
}

let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!

func pcmBuffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buffer
}

/// One stream of speech (a meeting track, or a file read through), turned into sentences as it goes. The model hands
/// back sub-word tokens with times; they become words (a token starting with a space starts a word, so a word split
/// across two steps is held until it's complete), and words become sentences: a new one after . ? !, after a pause
/// of more than a second, after 40 words, or when nothing more has been said for 2.5 s.
final class Stream {
    let asr: StreamingUnifiedAsrManager
    private var tokens: [TokenTiming] = []
    private var words: [WordTiming] = []
    private var heard = 0   // samples appended
    /// Everything it was fed since the last reset (as 16-bit, half the memory: an hour is 115 MB), for the whole-clip
    /// pass once the track has finished.
    private(set) var kept: [Int16] = []
    private var heardSeconds: Double { Double(heard) / Double(sampleRate) }
    private let lookAhead = Double(unifiedConfig.latencyMs) / 1000

    init(_ asr: StreamingUnifiedAsrManager) { self.asr = asr }

    static func load() async throws -> Stream {
        let asr = StreamingUnifiedAsrManager(config: unifiedConfig)
        try await asr.loadModels(from: try speechFolder())
        return Stream(asr)
    }

    func reset() async throws {
        try await asr.reset()
        tokens = []; words = []; heard = 0; kept = []
    }

    /// New sound in; the sentences it finished, and the one still going.
    func feed(_ samples: [Float]) async throws -> (lines: [Sentence], partial: String) {
        var at = 0
        while at < samples.count {   // in slices of 10 s, so a whole file doesn't sit in one buffer
            let end = min(at + 10 * sampleRate, samples.count)
            if let buffer = pcmBuffer(samples[at..<end]) { try await asr.appendAudio(buffer) }
            try await asr.processBufferedAudio()
            at = end
        }
        heard += samples.count
        kept += samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        let new = await asr.consumeTokenTimings()
        // No new token for 0.8 s past the look-ahead: the last word is complete, though no next word has started.
        let lastEnd = new.last?.endTime ?? tokens.last?.endTime ?? 0
        take(new, final: heardSeconds - lookAhead - lastEnd > 0.8)
        let pending = tokens.map(\.token).joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
        let lines = sentences(final: false)
        return (lines, (words.map(\.word) + (pending.isEmpty ? [] : [pending])).joined(separator: " "))
    }

    /// The last words, once the sound has ended.
    func finish() async throws -> [Sentence] {
        _ = try await asr.finish()
        take(await asr.consumeTokenTimings(), final: true)
        return sentences(final: true)
    }

    private func take(_ new: [TokenTiming], final: Bool) {
        tokens += new.filter { !$0.token.isEmpty && $0.token != "<blank>" && $0.token != "<pad>" }
        // Everything up to the last word start is complete words; that last word may still grow.
        let starts = tokens.indices.filter { $0 == 0 || tokens[$0].token.hasPrefix(" ") || tokens[$0].token.hasPrefix("▁") }
        let cut = final ? tokens.count : (starts.last ?? 0)
        guard cut > 0 else { return }
        words += buildWordTimings(from: Array(tokens[0..<cut]))
        tokens.removeFirst(cut)
    }

    private func sentences(final: Bool) -> [Sentence] {
        var out: [Sentence] = []
        var current: [WordTiming] = []
        var closedThrough = 0
        func close(through index: Int) {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.word).joined(separator: " ")
            if text.contains(where: { $0.isLetter || $0.isNumber }) {   // a lone "." after a pause isn't a sentence
                out.append(Sentence(start: first.startTime, end: last.endTime, text: text))
            }
            current = []
            closedThrough = index + 1
        }
        for (i, w) in words.enumerated() {
            if let last = current.last, w.startTime - last.endTime > 1 { close(through: i - 1) }
            current.append(w)
            if let c = w.word.last, ".?!".contains(c) { close(through: i) }
            else if current.count >= 40 { close(through: i) }
        }
        // Quiet for 2.5 s past the look-ahead: what was said is a finished line even without a full stop.
        let silentFor = heardSeconds - (words.last?.endTime ?? 0) - lookAhead
        if final || (!current.isEmpty && tokens.isEmpty && silentFor > 2.5) { close(through: words.count - 1) }
        words.removeFirst(closedThrough)
        return out
    }
}

/// A whole clip at once, through the same model's full-attention encoder: every word is heard with everything said
/// before and after it, not 0.56 s of look-ahead, so it's more accurate than the stream, but only once the sound has
/// ended. Long clips go through in 15 s windows overlapping by 2 s.
final class Whole {
    let asr: UnifiedAsrManager
    init(_ asr: UnifiedAsrManager) { self.asr = asr }

    static var available: Bool {
        FileManager.default.fileExists(atPath: models.appendingPathComponent(
            "\(speechModel)/\(ModelNames.ParakeetUnified.offlineEncoderInt8File)").path)
    }

    static func load() async throws -> Whole {
        let asr = UnifiedAsrManager(config: unifiedConfig)
        try await asr.loadModels(from: try speechFolder())
        return Whole(asr)
    }

    /// Its sentences, split by the stream's rules: after . ? !, after a pause of more than a second, or after 40 words.
    func sentences(_ audio: [Float]) async throws -> [Sentence] {
        guard audio.count >= sampleRate / 4 else { return [] }
        let words = buildWordTimings(from: try await asr.transcribeWithTimings(audio).tokenTimings)
        var out: [Sentence] = [], current: [WordTiming] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.word).joined(separator: " ")
            if text.contains(where: { $0.isLetter || $0.isNumber }) {
                out.append(Sentence(start: first.startTime, end: last.endTime, text: text))
            }
            current = []
        }
        for w in words {
            if let last = current.last, w.startTime - last.endTime > 1 { close() }
            current.append(w)
            if let c = w.word.last, ".?!".contains(c) || current.count >= 40 { close() }
        }
        close()
        return out
    }
}

func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576   // bytes on macOS
}

/// Each sentence goes to the speaker who talks most during it.
func label(_ lines: inout [Sentence], audio: [Float], diarizer: OfflineDiarizerManager) async throws {
    let turns = try await diarizer.process(audio: audio).segments
    for i in lines.indices {
        var overlap: [String: Double] = [:]
        for t in turns {
            let o = min(lines[i].end, Double(t.endTimeSeconds)) - max(lines[i].start, Double(t.startTimeSeconds))
            if o > 0 { overlap[t.speakerId, default: 0] += o }
        }
        lines[i].speaker = overlap.max { $0.value < $1.value }?.key
    }
}

func loadDiarizer() async throws -> OfflineDiarizerManager {
    let d = OfflineDiarizerManager()
    try await d.prepareModels(directory: models.appendingPathComponent("diarizer"))
    return d
}

/// A whole file through a stream: its sentences.
func transcribe(_ audio: [Float], with stream: Stream) async throws -> [Sentence] {
    try await stream.reset()
    guard audio.count >= sampleRate / 4 else { return [] }
    let fed = try await stream.feed(audio)
    return fed.lines + (try await stream.finish())
}

/// The microphone cleaned of the call's sound: LocalVQE (v1.3, 256 ms per call, on the CPU) takes the microphone and
/// the call's sound for the same moments and returns the microphone without the call. The two tracks come from one
/// audio clock, so a sample of one lines up with the same sample of the other; the microphone is held until the call's
/// sound for the same moments has arrived, and if the call's sound falls more than 2 s behind, the gap counts as silence.
/// What's left of the call after cleaning is very quiet (about 55 dB down) but still speech, and the speech model
/// evens out loudness, so it would hear it again: wherever the cleaned microphone is 30 dB or more below what came in,
/// nobody in the room is speaking, and that stretch is silenced (a gate, held open 200 ms after speech so word endings
/// stay). Your own voice comes through the cleaning almost unchanged (about 1 dB down), however softly you speak.
final class EchoCanceller {
    private let stream: LocalVqeStream
    private var mic: [Float] = []
    private var reference: [Float] = []
    /// Microphone sound already cleaned, waiting to be matched with the cleaned output (it comes out in whole calls).
    private var unmatched: [Float] = []
    private var openFrames = 0
    private let frame = 320   // 20 ms

    init() async throws {
        stream = try await LocalVqeManager(modelDirectory: echoFolder).makeStream()
    }

    func addReference(_ samples: [Float]) { reference += samples }

    /// More microphone sound in; the cleaned microphone sound that's ready.
    func clean(_ samples: [Float]) async throws -> [Float] {
        mic += samples
        if mic.count - reference.count > 2 * sampleRate { reference += [Float](repeating: 0, count: mic.count - reference.count) }
        let n = min(mic.count, reference.count)
        guard n > 0 else { return [] }
        unmatched += mic[0..<n]
        let out = try await stream.enhance(mic: Array(mic[0..<n]), reference: Array(reference[0..<n]))
        mic.removeFirst(n); reference.removeFirst(n)
        return gate(out)
    }

    /// Silences the stretches where only the call's leftover remains. Output sample i is input sample i.
    private func gate(_ out: [Float]) -> [Float] {
        var out = out
        let count = min(out.count, unmatched.count)
        var at = 0
        while at < count {
            let end = min(at + frame, count)
            var inEnergy: Float = 0, outEnergy: Float = 0
            for i in at..<end { inEnergy += unmatched[i] * unmatched[i]; outEnergy += out[i] * out[i] }
            // 30 dB down in power is a thousandth.
            if outEnergy > inEnergy * 0.001 && outEnergy > Float(end - at) * 1e-8 { openFrames = 10 } else if openFrames > 0 { openFrames -= 1 }
            if openFrames == 0 { for i in at..<end { out[i] = 0 } }
            at = end
        }
        unmatched.removeFirst(count)
        return out
    }

    /// The rest, at the end of the meeting (the call's sound missing at the end counts as silence).
    func finish() async throws -> [Float] {
        reference += [Float](repeating: 0, count: max(0, mic.count - reference.count))
        let out = try await clean([])
        return out + gate(try await stream.flush())
    }
}

func clock(_ t: Double) -> String { String(format: "%02d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }

if preparing {
    do {
        note("progress 0.100")
        _ = try await Stream.load()
        note("progress 0.500")
        if Whole.available { _ = try await Whole.load() }
        note("progress 0.800")
        _ = try await loadDiarizer()
        _ = try await EchoCanceller()
        note("progress 1.000")
        print("ready")
        exit(0)
    } catch {
        note("error: \(error.localizedDescription)")
        exit(1)
    }
}

// familiar-speech --clean <mic.wav> <call.wav> <out.wav> --models <dir>: the microphone cleaned of the call, as the
// meeting stream does it (for testing echo cancellation on recordings).
if arguments.contains("--clean") {
    let files = positional.map { URL(fileURLWithPath: $0) }
    do {
        let mic = try await samples(of: files[0]), call = try await samples(of: files[1])
        let echo = try await EchoCanceller()
        echo.addReference(call)
        let out = try await echo.clean(mic) + (try await echo.finish())
        do {   // the file is finished when it's released, before exit
            let file = try AVAudioFile(forWriting: files[2], settings: speechFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            if let buffer = pcmBuffer(out[...]) { try file.write(from: buffer) }
        }
        exit(0)
    } catch {
        note("error: \(error.localizedDescription)")
        exit(1)
    }
}

if serving {
    struct Request: Decodable {
        let cmd: String?; let id: Int?; let track: String?; let pcm: String?; let on: Bool?
        let path: String?; let speakers: Bool?; let lines: [Sentence]?
    }
    struct Reply: Encodable {
        var id: Int?; var track: String?; var lines: [Sentence]?; var partial: String?; var done: Bool?
        var sentences: [Sentence]?; var duration: Double?; var error: String?
    }
    func send(_ reply: Reply) {
        print(String(decoding: (try? JSONEncoder().encode(reply)) ?? Data(#"{"error":"encoding"}"#.utf8), as: UTF8.self))
        fflush(stdout)
    }
    do {
        var streams: [String: Stream] = [:]
        var fileStream: Stream?
        var diarizer: OfflineDiarizerManager?
        var lastPartial: [String: String] = [:]
        var echo: EchoCanceller?
        var finished: [String: [Int16]] = [:]   // each finished track's sound, until it's read whole
        // One stream loaded up front, so the first words of a meeting don't wait for the model; and the whole-clip
        // encoder, so a finished dictation doesn't either.
        streams["me"] = try await Stream.load()
        let wholeClip = Whole.available ? try await Whole.load() : nil
        print(#"{"ready":true}"#); fflush(stdout)
        while let line = readLine() {
            guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
                send(Reply(error: "unreadable request")); continue
            }
            do {
                switch request.cmd ?? "file" {
                case "echo":
                    echo = request.on == true ? try await EchoCanceller() : nil
                case "audio":
                    guard let track = request.track, let pcm = request.pcm, let data = Data(base64Encoded: pcm) else { continue }
                    let ints = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                    let stream: Stream
                    if let s = streams[track] { stream = s } else { stream = try await Stream.load(); streams[track] = stream }
                    var sound = ints.map { Float($0) / 32768 }
                    if let echo {
                        if track == "me" { sound = try await echo.clean(sound) } else { echo.addReference(sound) }
                    }
                    let (lines, partial) = try await stream.feed(sound)
                    if !lines.isEmpty || partial != lastPartial[track] {
                        lastPartial[track] = partial
                        send(Reply(track: track, lines: lines, partial: partial))
                    }
                case "finish":
                    guard let track = request.track else { continue }
                    var lines: [Sentence] = []
                    if track == "me", let rest = try await echo?.finish(), !rest.isEmpty {
                        lines += try await streams[track]?.feed(rest).lines ?? []
                    }
                    if track == "me" { echo = nil }
                    lines += try await streams[track]?.finish() ?? []
                    finished[track] = streams[track]?.kept
                    try await streams[track]?.reset()
                    lastPartial[track] = nil
                    send(Reply(id: request.id, track: track, lines: lines, done: true))
                case "whole":
                    guard let track = request.track else { continue }
                    guard let wholeClip else { throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "the whole-clip model isn't installed"]) }
                    let audio = (finished.removeValue(forKey: track) ?? []).map { Float($0) / 32767 }
                    send(Reply(id: request.id, track: track, sentences: try await wholeClip.sentences(audio)))
                case "label":
                    guard let path = request.path else { continue }
                    var lines = request.lines ?? []
                    if !lines.isEmpty {
                        if diarizer == nil { diarizer = try await loadDiarizer() }
                        try await label(&lines, audio: try await samples(of: URL(fileURLWithPath: path)), diarizer: diarizer!)
                    }
                    send(Reply(id: request.id, sentences: lines))
                default:   // "file", and the older {"path": …} form
                    guard let path = request.path else { continue }
                    let audio = try await samples(of: URL(fileURLWithPath: path))
                    var lines: [Sentence]
                    if let wholeClip { lines = try await wholeClip.sentences(audio) } else {
                        if fileStream == nil { fileStream = try await Stream.load() }
                        lines = try await transcribe(audio, with: fileStream!)
                    }
                    if request.speakers == true, !lines.isEmpty {
                        if diarizer == nil { diarizer = try await loadDiarizer() }
                        try await label(&lines, audio: audio, diarizer: diarizer!)
                    }
                    send(Reply(id: request.id, sentences: lines, duration: Double(audio.count) / Double(sampleRate)))
                }
            } catch {
                send(Reply(id: request.id, track: request.track, error: error.localizedDescription))
            }
        }
        exit(0)
    } catch {
        note("error: \(error.localizedDescription)")
        exit(1)
    }
}

do {
    let audio = try await samples(of: file)
    let duration = Double(audio.count) / Double(sampleRate)
    guard duration > 0 else { note("no sound in \(file.lastPathComponent)"); exit(1) }

    // Load: the first run compiles for the Neural Engine; later runs load the compiled copy.
    let loadStarted = Date()
    let whole = Whole.available && !streamed
    let stream = whole ? nil : try await Stream.load()
    let wholeClip = whole ? try await Whole.load() : nil
    let diarizer = speakers ? try await loadDiarizer() : nil
    let loadSeconds = Date().timeIntervalSince(loadStarted)

    let started = Date()
    var lines: [Sentence]
    if let wholeClip { lines = try await wholeClip.sentences(audio) } else { lines = try await transcribe(audio, with: stream!) }
    if let diarizer, !lines.isEmpty { try await label(&lines, audio: audio, diarizer: diarizer) }
    let seconds = Date().timeIntervalSince(started)
    let run = Run(file: file.path, duration: duration, loadSeconds: loadSeconds, transcribeSeconds: seconds,
                  realTimeFactor: duration / max(seconds, 0.001), peakMemoryMB: peakMemoryMB(),
                  computeUnits: "encoder (\(whole ? "whole clip" : "streamed")): cpuAndNeuralEngine; decoder, joint: cpuOnly",
                  text: lines.map(\.text).joined(separator: " "), sentences: lines, words: [])
    if asJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(run), as: UTF8.self))
    } else {
        for s in lines { print("[\(clock(s.start))–\(clock(s.end))]" + (s.speaker.map { " \($0):" } ?? "") + " " + s.text) }
    }
    note(String(format: "%.1f s of sound in %.2f s (%.0f× real time); models loaded in %.1f s; peak memory %.0f MB",
                duration, seconds, run.realTimeFactor, loadSeconds, run.peakMemoryMB))
} catch {
    note("error: \(error.localizedDescription)")
    exit(1)
}
