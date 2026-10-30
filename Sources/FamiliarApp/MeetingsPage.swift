import AppKit
import AVFoundation
import FamiliarCore
import SwiftUI

/// The saved meetings, newest first, and which one is open.
@MainActor
final class MeetingsModel: ObservableObject {
    static let shared = MeetingsModel()
    @Published private(set) var meetings: [Meetings.Meeting] = []
    @Published var selected: String?

    func reload() {
        meetings = Meetings.all()
        if let selected, !meetings.contains(where: { $0.id == selected }) { self.selected = nil }
    }

    func open(_ path: String) {
        reload()
        selected = meetings.first { $0.url.path == path }?.id
    }

    var current: Meetings.Meeting? { meetings.first { $0.id == selected } }
}

struct MeetingsPage: View {
    @ObservedObject var app: AppState
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var model: MeetingsModel

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 250)
            Divider()
            Group {
                if recorder.isActive || isFailed {
                    RecordingView(recorder: recorder)
                } else if let meeting = model.current {
                    MeetingDetail(meeting: meeting).id(meeting.id)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.reload()
            // The latest meeting is open when the page is: nothing to click to see it.
            if model.selected == nil, !recorder.isActive { model.selected = model.meetings.first?.id }
        }
        .onReceive(recorder.$saved) { meeting in
            guard let meeting else { return }
            model.open(meeting.url.path)
        }
    }

    private var isFailed: Bool { if case .failed = recorder.state { return true } else { return false } }

    private var list: some View {
        VStack(spacing: 0) {
            Button {
                if recorder.state == .recording { Task { await recorder.stop() } }
                else if !recorder.isActive { model.selected = nil; Task { await recorder.start() } }
            } label: {
                HStack {
                    Image(systemName: recorder.state == .recording ? "stop.circle.fill" : "record.circle")
                    Text(recorder.state == .recording ? "Stop Recording" : "Record a Meeting")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 9).fill(recorder.state == .recording ? Color.gray : Color.red))
            }
            .buttonStyle(.plain)
            .disabled(recorder.isActive && recorder.state != .recording)
            .padding(12)
            if model.meetings.isEmpty {
                Text("Recorded meetings will be listed here.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selected }, set: { model.selected = $0 })) {
                    ForEach(groups, id: \.0) { day, meetings in
                        SwiftUI.Section(day) {
                            ForEach(meetings) { meeting in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meeting.title).lineLimit(2)
                                    Text("\(meeting.date.formatted(date: .omitted, time: .shortened)) · \(max(1, Int((meeting.duration / 60).rounded()))) min")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                                .tag(Optional(meeting.id))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var groups: [(String, [Meetings.Meeting])] {
        var out: [(String, [Meetings.Meeting])] = []
        for meeting in model.meetings {
            let day = Calendar.current.isDateInToday(meeting.date) ? "Today"
                : Calendar.current.isDateInYesterday(meeting.date) ? "Yesterday"
                : meeting.date.formatted(date: .abbreviated, time: .omitted)
            if out.last?.0 == day { out[out.count - 1].1.append(meeting) } else { out.append((day, [meeting])) }
        }
        return out
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Record a meeting").font(.title2.weight(.semibold))
            Text("Familiar records your microphone and your Mac's sound (the other people on a call, in any app), writes down what's said on this Mac, and saves it with your notes. Afterwards you can search it and ask about it.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            Text("macOS will ask once to allow the microphone and system audio recording. Let people know you're recording.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding()
    }
}

/// While recording: the title, the time, the live transcript and your notes.
struct RecordingView: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TextField("Title", text: $recorder.title)
                    .textFieldStyle(.plain).font(.title2.weight(.semibold))
                Spacer()
                status
            }
            if let notice = recorder.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.orange)
            }
            if case .failed(let why) = recorder.state {
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Try Again") { Task { await recorder.start() } }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRANSCRIPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if recorder.live.isEmpty && speaking.isEmpty {
                                    Text(recorder.state == .recording ? "What's said appears here as it's spoken…" : "")
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(Array(recorder.live.enumerated()), id: \.offset) { _, line in
                                    TranscriptLine(line: line, onTap: nil)
                                }
                                // Sentences still being spoken, in grey until they're finished.
                                ForEach(speaking, id: \.speaker) { line in
                                    TranscriptLine(line: line, onTap: nil).opacity(0.5)
                                }
                                Color.clear.frame(height: 1).id("end")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: recorder.live.count) { _ in withAnimation { proxy.scrollTo("end") } }
                        .onChange(of: recorder.partials) { _ in proxy.scrollTo("end") }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text("YOUR NOTES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $recorder.notes)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .frame(width: 280)
            }
        }
        .padding(24)
    }

    /// What each track is saying right now, as transcript lines (no time yet).
    private var speaking: [Meetings.Line] {
        [("me", "Me"), ("others", "Others")].compactMap { track, name in
            guard let text = recorder.partials[track], !text.isEmpty else { return nil }
            return Meetings.Line(start: -1, speaker: recorder.systemTrack ? name : "Me", text: text)
        }
    }

    @ViewBuilder private var status: some View {
        switch recorder.state {
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                if let started = recorder.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Meetings.clock(context.date.timeIntervalSince(started))).monospacedDigit()
                    }
                }
                Image(systemName: recorder.systemTrack ? "speaker.wave.2.fill" : "mic.fill").foregroundStyle(.secondary)
                    .help(recorder.systemTrack ? "Recording your microphone and your Mac's sound" : "Recording your microphone only")
                Button("Stop") { Task { await recorder.stop() } }.keyboardShortcut(".", modifiers: .command)
            }
        case .starting(let what), .finishing(let what):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(what).foregroundStyle(.secondary) }
        default:
            EmptyView()
        }
    }
}

struct TranscriptLine: View {
    let line: Meetings.Line
    let onTap: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { onTap?() } label: {
                Text(line.start < 0 ? "…" : Meetings.clock(line.start)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).disabled(onTap == nil).help(onTap == nil ? "" : "Play from here")
            Text(line.speaker).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(line.speaker == "Me" ? Color.accentColor : Color.primary)
                .frame(width: 78, alignment: .leading)
            Text(line.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A saved meeting: play it, read it, ask about it.
struct MeetingDetail: View {
    let meeting: Meetings.Meeting
    @StateObject private var player = MeetingPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title).font(.title2.weight(.semibold))
                Text("\(meeting.date.formatted(date: .long, time: .shortened)) · \(max(1, Int((meeting.duration / 60).rounded()))) min")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if player.available {
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 26)) }
                        .buttonStyle(.plain).help(player.playing ? "Pause" : "Play")
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text("\(Meetings.clock(player.time)) / \(Meetings.clock(meeting.duration))").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    let chats = MainWindowController.shared.chats
                    chats.newChat()
                    chats.scope = meeting.url.path
                    MainWindowController.shared.navigation.page = .chat
                } label: { Label("Ask about this meeting", systemImage: "bubble.left.and.text.bubble.right") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !meeting.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOTES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(meeting.notes).font(.system(size: 14)).textSelection(.enabled)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TRANSCRIPT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if meeting.lines.isEmpty { Text("Nothing was said, or it couldn't be made out.").foregroundStyle(.secondary) }
                        ForEach(Array(meeting.lines.enumerated()), id: \.offset) { _, line in
                            TranscriptLine(line: line, onTap: player.available ? { player.play(from: line.start) } : nil)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .onAppear { player.load(meeting.audio) }
        .onDisappear { player.stop() }
    }
}

/// Plays a meeting's two tracks together (your microphone and the Mac's sound), kept in step.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published private(set) var playing = false
    /// Published: the play button appears once the audio has loaded (it loads after the view first draws).
    @Published private var players: [AVAudioPlayer] = []

    var available: Bool { !players.isEmpty }
    var time: Double { players.first?.currentTime ?? 0 }

    func load(_ folder: URL?) {
        guard let folder else { return }
        players = ["me.m4a", "others.m4a"].compactMap { try? AVAudioPlayer(contentsOf: folder.appendingPathComponent($0)) }
        players.forEach { $0.prepareToPlay() }
    }

    func toggle() { playing ? pause() : play(from: time) }

    func play(from seconds: Double) {
        guard let first = players.first else { return }
        let at = first.deviceCurrentTime + 0.05
        for player in players {
            player.currentTime = min(max(0, seconds - 0.5), player.duration)
            player.play(atTime: at)
        }
        playing = true
    }

    func pause() { players.forEach { $0.pause() }; playing = false }
    func stop() { players.forEach { $0.stop() }; playing = false }
}
