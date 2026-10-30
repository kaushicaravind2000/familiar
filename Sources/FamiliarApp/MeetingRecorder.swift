import AVFoundation
import Foundation
import FamiliarCore

/// Records a meeting: your microphone ("Me") and the Mac's sound (everyone else) as two tracks, each streamed to the
/// speech model as it's recorded, so the transcript keeps up with the conversation (words about a second after
/// they're said). On stop, the last words are taken and the meeting is saved at once, with your notes, as a Markdown
/// file in the Meetings folder, which Familiar then indexes like any other file. Then, in the background, each track
/// is read again as one clip (more accurate than the stream: every word heard with what came after it), who said what
/// (Speaker 1, 2…) is worked out, and the file is updated.
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    enum State: Equatable { case idle, starting(String), recording, finishing(String), failed(String) }

    @Published private(set) var state: State = .idle
    @Published var title = ""
    @Published var notes = ""
    /// The transcript so far: finished sentences.
    @Published private(set) var live: [Meetings.Line] = []
    /// What each track ("me", "others") is saying right now, before the sentence is finished.
    @Published private(set) var partials: [String: String] = [:]
    @Published private(set) var startedAt: Date?
    /// False when the Mac's sound isn't being recorded (macOS before 14.2, or not allowed): only the microphone.
    @Published private(set) var systemTrack = false
    @Published private(set) var notice: String?
    /// The meeting just saved, for the Meetings page to show.
    @Published private(set) var saved: Meetings.Meeting?

    /// Off in a test copy fed from files (`-debugMeeting`): it must never record the real microphone or sound, even if
    /// its Record button is clicked. (A test run once did, after the button was pressed during the test.)
    static var allowsDevices = true

    /// The audio folder of the meeting being recorded, which deleting old audio leaves alone.
    var recordingFolder: URL? { isActive ? audioFolder : nil }

    var isActive: Bool {
        switch state { case .idle, .failed: return false; default: return true }
    }

    private var mic: AudioSource?
    private var system: AudioSource?
    private var me: TrackSink?
    private var others: TrackSink?
    private var session: TranscriberSession?
    private var liveTask: Task<Void, Never>?
    private var audioFolder: URL?
    private var meRaw: [Transcriber.Line] = []
    private var othersRaw: [Transcriber.Line] = []

    /// Starts recording. `sources` replaces the microphone and the Mac's sound (tests).
    func start(sources: (me: AudioSource, others: AudioSource?)? = nil) async {
        guard !isActive else { return }
        notice = nil
        live = []; meRaw = []; othersRaw = []
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = "Meeting" }
        do {
            if !Transcriber.isPrepared {
                state = .starting("Getting the speech model ready (1.2 GB, once)…")
                try await AppState.shared.prepareSpeechModel()
            }
            state = .starting("Starting…")
            let date = Date()
            // Named by the minute: a second meeting in the same minute gets its own folder ("… 2"), not the first's.
            let name = Meetings.baseName(title: "", date: date).trimmingCharacters(in: .whitespaces)
            var folder = Meetings.recordings.appendingPathComponent(name, isDirectory: true)
            var n = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = Meetings.recordings.appendingPathComponent("\(name) \(n)", isDirectory: true); n += 1
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            audioFolder = folder

            let micSource: AudioSource
            var systemSource: AudioSource?
            if sources == nil && !Self.allowsDevices {
                state = .failed("This test copy doesn't record from the microphone or the Mac's sound.")
                return
            }
            if let sources {
                micSource = sources.me
                systemSource = sources.others
            } else {
                try await Self.requestMicrophone()
                micSource = MicrophoneSource()
                if #available(macOS 14.2, *) { systemSource = SystemAudioSource() }
            }
            let meSink = try TrackSink(url: folder.appendingPathComponent("me.m4a"))
            try micSource.start { samples in meSink.append(samples) }
            me = meSink
            mic = micSource
            if let systemSource {
                do {
                    let othersSink = try TrackSink(url: folder.appendingPathComponent("others.m4a"))
                    try systemSource.start { samples in othersSink.append(samples) }
                    others = othersSink
                    system = systemSource
                    systemTrack = true
                } catch {
                    systemTrack = false
                    notice = "Recording your microphone only: \(error.localizedDescription)"
                }
            } else {
                systemTrack = false
                notice = "Recording your microphone only: recording the Mac's sound needs macOS 14.2 or later."
            }
            state = .starting("Loading the speech model…")
            let session = TranscriberSession { track, lines, partial in
                Task { @MainActor in MeetingRecorder.shared.heard(track, lines: lines, partial: partial) }
            }
            try await session.start()
            if systemTrack { try await session.cancelEcho() }
            self.session = session
            startedAt = date
            state = .recording
            AppLog.write("meeting: recording\(systemTrack ? " microphone and system audio" : " microphone only")")
            liveTask = Task { await self.transcribeAsItGoes() }
        } catch {
            stopSources()
            state = .failed(error.localizedDescription)
            AppLog.write("meeting: couldn't start: \(error.localizedDescription)")
        }
    }

    /// Stops recording, takes each track's last words and saves the meeting straight away; then, in the background,
    /// works out who said what and saves it again with speaker names.
    func stop() async {
        guard state == .recording, let startedAt, let audioFolder, let me, let session else { return }
        liveTask?.cancel()
        stopSources()
        state = .finishing("Saving…")
        me.close()
        others?.close()
        do {
            // The sound recorded since the last send, then each track's last words.
            await session.stream("me", samples: me.takeNew())
            if let others { await session.stream("others", samples: others.takeNew()) }
            meRaw += try await session.finish("me")
            if others != nil { othersRaw += try await session.finish("others") }
            try? await Task.sleep(nanoseconds: 100_000_000)   // let sentences already on their way arrive first
            partials = [:]
            let base = Meetings.baseName(title: title, date: startedAt)
            var url = Meetings.folder.appendingPathComponent(base + ".md")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = Meetings.folder.appendingPathComponent("\(base) \(n).md"); n += 1
            }
            let meeting = Meetings.Meeting(url: url, title: title.trimmingCharacters(in: .whitespaces), date: startedAt,
                                           duration: Double(max(me.total, others?.total ?? 0)) / 16_000, notes: notes,
                                           lines: Meetings.merge(me: meRaw, others: othersRaw, hasSystemTrack: systemTrack),
                                           audio: audioFolder)
            try Meetings.save(meeting)
            AppLog.write("meeting: saved (\(Int(meeting.duration)) s, \(meeting.lines.count) lines)")
            AppState.shared.meetingSaved(url)
            saved = meeting
            let (mine, theirs, hasSystem, othersURL) = (meRaw, othersRaw, systemTrack, others?.url)
            reset()
            Task { await Self.improve(meeting, me: mine, others: theirs, hasSystemTrack: hasSystem,
                                      meURL: me.url, othersURL: othersURL, session: session) }
        } catch {
            await session.stop()
            state = .failed("The recording is kept, but the transcript couldn't be written: \(error.localizedDescription)")
            AppLog.write("meeting: transcript failed: \(error.localizedDescription)")
        }
    }

    /// The saved meeting made better: each track read again as one clip, the streamed lines replaced; then who said
    /// what, the call's sound split by speaker (or, with no call sound, the microphone, for a meeting in a room), with
    /// Speaker 1, 2… in place of "Others"; and the meeting written again. The streamed transcript is already saved, so
    /// if any of this fails nothing is lost.
    private static func improve(_ meeting: Meetings.Meeting, me: [Transcriber.Line], others: [Transcriber.Line],
                                hasSystemTrack: Bool, meURL: URL, othersURL: URL?, session: TranscriberSession) async {
        defer { Task { await session.stop() } }
        var me = me, others = others
        var whole = 0
        if let lines = try? await session.whole("me"), !lines.isEmpty { me = lines; whole += 1 }
        if hasSystemTrack, let lines = try? await session.whole("others"), !lines.isEmpty { others = lines; whole += 1 }
        var labelled = false
        do {
            if hasSystemTrack, let othersURL, !others.isEmpty {
                others = try await session.label(othersURL, lines: others); labelled = true
            } else if !hasSystemTrack, !me.isEmpty {
                me = try await session.label(meURL, lines: me); labelled = true
            }
        } catch {
            AppLog.write("meeting: couldn't tell speakers apart: \(error.localizedDescription)")
        }
        guard whole > 0 || labelled else { return }
        do {
            let lines = Meetings.merge(me: me, others: others, hasSystemTrack: hasSystemTrack)
            let named = Meetings.Meeting(url: meeting.url, title: meeting.title, date: meeting.date, duration: meeting.duration,
                                         notes: meeting.notes, lines: lines, audio: meeting.audio)
            try Meetings.save(named)
            AppState.shared.meetingSaved(meeting.url)
            if MeetingRecorder.shared.saved?.url == meeting.url { MeetingRecorder.shared.saved = named }
            AppLog.write("meeting: \(whole) track\(whole == 1 ? "" : "s") read whole"
                         + (labelled ? ", speakers named (\(Set(lines.map(\.speaker)).count) voices)" : ""))
        } catch {
            AppLog.write("meeting: couldn't save the improved transcript: \(error.localizedDescription)")
        }
    }

    /// The app is quitting mid-recording: the audio files are finished so nothing recorded is lost (the transcript
    /// can't be written in the time a quit allows).
    func abandon() {
        guard state == .recording else { return }
        liveTask?.cancel()
        stopSources()
        me?.close()
        others?.close()
        AppLog.write("meeting: quit while recording; the audio is kept in \(audioFolder?.lastPathComponent ?? "?")")
    }

    private func reset() {
        state = .idle
        title = ""; notes = ""; live = []; partials = [:]; startedAt = nil
        me = nil; others = nil; session = nil; audioFolder = nil
    }

    private func stopSources() {
        mic?.stop(); system?.stop()
        mic = nil; system = nil
    }

    /// Four times a second, each track's new sound goes to the speech model; what it hears comes back through
    /// `heard`.
    private func transcribeAsItGoes() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let session else { return }
            if let me { await session.stream("me", samples: me.takeNew()) }
            if let others { await session.stream("others", samples: others.takeNew()) }
        }
    }

    /// A track's newly finished sentences and its sentence in progress.
    func heard(_ track: String, lines: [Transcriber.Line], partial: String) {
        guard state == .recording || state == .finishing("Saving…") else { return }
        if track == "me" { meRaw += lines } else { othersRaw += lines }
        partials[track] = partial
        if !lines.isEmpty { live = Meetings.merge(me: meRaw, others: othersRaw, hasSystemTrack: systemTrack) }
    }

    private static func requestMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw RecordingError.microphoneDenied
        default:
            throw RecordingError.microphoneDenied
        }
    }
}

/// One track of a meeting: written to disk as compressed audio (AAC, 16 kHz mono, ~14 MB an hour) as it arrives, and
/// held in memory until it's sent to the speech model (a quarter of a second at a time). Fed from the audio thread; everything happens on its own queue.
final class TrackSink: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "Familiar.track", qos: .userInitiated)
    private var file: AVAudioFile?
    private var pending: [Float] = []
    private var count = 0

    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Samples recorded so far.
    var total: Int { queue.sync { count } }

    func append(_ samples: [Float]) {
        queue.async {
            if let buffer = Self.buffer(samples) { try? self.file?.write(from: buffer) }
            self.pending += samples
            self.count += samples.count
        }
    }

    /// The sound not yet sent to the speech model.
    func takeNew() -> [Float] {
        queue.sync {
            defer { pending = [] }
            return pending
        }
    }

    /// Finishes the file (it's complete once closed).
    func close() { queue.sync { file = nil } }

    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

}
