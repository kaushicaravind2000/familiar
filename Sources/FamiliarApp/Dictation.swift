import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import FamiliarCore
import SwiftUI

/// Push to talk: hold a key (right ⌥ by default) and speak, let go and what you said is typed where your cursor is,
/// in any app. Tap the key twice to talk hands-free; press it again to finish. Esc, or another key pressed with it
/// (a shortcut, not dictation), throws the recording away.
///
/// The sound streams to the speech helper while you talk (Parakeet, the meetings' model), so the pill shows the words
/// as they're said. Once you let go, the whole recording is read again as one clip, every word heard with what came
/// after it, which is more accurate than the stream (and takes under a tenth of a second); the streamed words stand in
/// if that fails. The text is tidied (`DictationText`) and pasted through the clipboard, which gets its contents back
/// afterwards. The helper is loaded when push to talk is turned on and stays loaded, so a dictation starts at once.
///
/// Watching the key and pasting into other apps both need Accessibility permission (macOS asks once). Without it the
/// key does nothing; when only pasting fails, the text is left on the clipboard. Nothing is kept: no audio, and the
/// log has word counts and timings, not words.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Key: String, CaseIterable, Identifiable {
        case rightOption, rightCommand, function
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rightOption: return "Right ⌥ Option"
            case .rightCommand: return "Right ⌘ Command"
            case .function: return "fn (Globe)"
            }
        }
        var short: String {
            switch self {
            case .rightOption: return "right ⌥"
            case .rightCommand: return "right ⌘"
            case .function: return "fn"
            }
        }
        fileprivate var keyCode: UInt16 {
            switch self {
            case .rightOption: return UInt16(kVK_RightOption)
            case .rightCommand: return UInt16(kVK_RightCommand)
            case .function: return UInt16(kVK_Function)
            }
        }
        /// Whether the key is down, from an event's flags: the right-hand bits (NX_DEVICERALTKEYMASK,
        /// NX_DEVICERCMDKEYMASK), so the left key held at the same time doesn't count.
        fileprivate func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
            switch self {
            case .rightOption: return flags.rawValue & 0x40 != 0
            case .rightCommand: return flags.rawValue & 0x10 != 0
            case .function: return flags.contains(.function)
            }
        }
    }

    enum State: Equatable { case idle, listening(handsFree: Bool), finishing }

    @Published private(set) var state: State = .idle
    /// What's been heard so far: the finished sentences and the one still being spoken.
    @Published private(set) var heardText = ""
    /// A short message in the indicator ("Copied…", "Preparing…"), shown for a moment.
    @Published private(set) var notice: String?
    /// Accessibility permission, which watching the key and pasting need.
    @Published private(set) var trusted = AXIsProcessTrusted()

    @Published var enabled: Bool = SettingsStore.defaults.bool(forKey: "dictation") {
        didSet {
            guard enabled != oldValue else { return }
            SettingsStore.defaults.set(enabled, forKey: "dictation")
            if enabled { askForAccess() }
            install()
        }
    }
    @Published var key: Key = SettingsStore.defaults.string(forKey: "dictationKey").flatMap(Key.init) ?? .rightOption {
        didSet { SettingsStore.defaults.set(key.rawValue, forKey: "dictationKey") }
    }
    @Published var removeFillers: Bool = SettingsStore.defaults.object(forKey: "dictationFillers") as? Bool ?? true {
        didSet { SettingsStore.defaults.set(removeFillers, forKey: "dictationFillers") }
    }

    @Published var avoidsBluetooth: Bool = MicrophoneSource.avoidsBluetooth {
        didSet { MicrophoneSource.avoidsBluetooth = avoidsBluetooth }
    }

    /// Off in a test copy fed from a file (`-debugDictation`): no microphone, and the text is logged, not pasted.
    static var allowsDevices = true

    private var monitors: [Any] = []
    private var trustPoll: Timer?
    private var pressedAt: Date?
    private var lastTap: Date?
    private var endOnRelease = false
    private var mic: AudioSource?
    private let sound = Pending()
    private var session: TranscriberSession?
    private var pump: Task<Void, Never>?
    /// A thrown-away recording's reset of the helper's stream, which the next recording waits for.
    private var resetting: Task<Void, Never>?
    private var lines: [Transcriber.Line] = []
    private var partial = ""
    private var startedAt = Date()

    private init() {}

    // MARK: The key

    /// Watches the key while push to talk is on (the menu bar app starts it at launch).
    func install() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        trustPoll?.invalidate(); trustPoll = nil
        guard enabled, Self.allowsDevices else { unloadIfOff(); return }
        trusted = AXIsProcessTrusted()
        if !trusted {
            // Monitors added before the permission is given never see a key: wait for it, then add them.
            trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard AXIsProcessTrusted() else { return }
                    Dictation.shared.install()
                }
            }
            return
        }
        warmUp()
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { event in
            MainActor.assumeIsolated { Dictation.shared.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            MainActor.assumeIsolated { Dictation.shared.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    /// macOS's own dialog, pointing at Privacy & Security → Accessibility.
    func askForAccess() {
        guard Self.allowsDevices, !AXIsProcessTrusted() else { return }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// After an update macOS can keep a stale Accessibility entry, from the build before: switched on, but for an app
    /// that's no longer this one, so switching it off and on doesn't help. This removes Familiar' entry and asks
    /// afresh, with the list open, so turning it on is one switch.
    func allowAgain() {
        guard Self.allowsDevices else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "io.github.kaushicaravind2000.Familiar"]
        try? reset.run()
        reset.waitUntilExit()
        AppLog.write("dictation: Accessibility entry reset, asking again")
        askForAccess()
        openAccessibilitySettings()
        install()
    }

    /// Push to talk is on but the permission is gone (an update): say so once at launch, with the fix, rather than
    /// the key silently doing nothing.
    func checkAccessAtLaunch() {
        guard enabled, Self.allowsDevices, !AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard !AXIsProcessTrusted() else { return }
            let alert = NSAlert()
            alert.messageText = "Push to talk needs permission again"
            alert.informativeText = "After an update, macOS asks again for Accessibility, which push to talk uses to notice its key and type what you say. Choose Allow Again, then turn on Familiar in the list that opens."
            alert.addButton(withTitle: "Allow Again")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { Dictation.shared.allowAgain() }
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard state != .idle && state != .finishing else { return }
            if event.keyCode == UInt16(kVK_Escape) { cancel("cancelled"); return }
            // Another key while holding it: a shortcut (right ⌥ + a letter types a symbol), not dictation.
            if pressedAt != nil, state == .listening(handsFree: false) { pressedAt = nil; cancel(nil) }
        case .flagsChanged:
            if event.keyCode == key.keyCode {
                key.isDown(event.modifierFlags) ? pressed() : released()
            } else if pressedAt != nil, state == .listening(handsFree: false) {
                pressedAt = nil; cancel(nil)   // another modifier with it: a shortcut
            }
        default: break
        }
    }

    private func pressed() {
        if state == .listening(handsFree: true) { endOnRelease = true; return }   // pasted once the key is up
        guard state == .idle else { return }
        pressedAt = Date()
        begin()
    }

    private func released() {
        if endOnRelease { endOnRelease = false; Task { await finish() }; return }
        guard let at = pressedAt else { return }
        pressedAt = nil
        guard state == .listening(handsFree: false) else { return }
        guard Date().timeIntervalSince(at) < 0.3 else { Task { await finish() }; return }
        // A tap. The second of two quick taps keeps this recording going, hands-free.
        if let lastTap, at.timeIntervalSince(lastTap) < 0.5 {
            self.lastTap = nil
            state = .listening(handsFree: true)
        } else {
            lastTap = Date()
            cancel(nil)
        }
    }

    // MARK: Recording

    /// Starts listening: `source` replaces the microphone (tests).
    func begin(source: AudioSource? = nil) {
        guard state == .idle else { return }
        guard Transcriber.isSupported else { show("Push to talk needs macOS 14 or later."); return }
        guard Transcriber.isPrepared else {
            show("Preparing the speech model. Try again in a minute.")
            Task { try? await AppState.shared.prepareSpeechModel() }
            return
        }
        if source == nil {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
                show("Allow the microphone, then try again.")
                return
            default:
                show("Familiar isn't allowed to use the microphone (System Settings → Privacy & Security).")
                return
            }
        }
        lines = []; partial = ""; heardText = ""; notice = nil
        _ = sound.take()
        startedAt = Date()
        let source = source ?? MicrophoneSource()
        do {
            let sound = self.sound
            try source.start { samples in sound.append(samples) }
        } catch {
            show("The microphone didn't start: \(error.localizedDescription)")
            return
        }
        mic = source
        state = .listening(handsFree: false)
        DictationIndicator.shared.show()
        let session = self.session ?? makeSession()
        self.session = session
        // The helper starts (if it isn't running) while you talk; the sound waits for it, so none is lost.
        pump = Task { [sound, resetting] in
            await resetting?.value
            do { try await session.start() } catch {
                await MainActor.run { Dictation.shared.cancel("The speech model didn't start.") }
                return
            }
            while !Task.isCancelled {
                await session.stream("me", samples: sound.take())
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func heard(_ new: [Transcriber.Line], partial: String) {
        guard state != .idle else { return }
        lines += new
        self.partial = partial
        heardText = (lines.map(\.text) + [partial]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Let go: the last words, tidied, typed into the app you were in.
    func finish() async {
        guard case .listening = state, let session else { return }
        state = .finishing
        let released = Date()
        mic?.stop(); mic = nil
        pump?.cancel(); await pump?.value; pump = nil
        do {
            try await session.start()
            // Half a second of quiet after the last word: a key let go as the last word ends cuts the sentence off,
            // and the model writes its full stop or question mark only once it hears the sentence end.
            await session.stream("me", samples: sound.take() + [Float](repeating: 0, count: 8_000))
            let last = try await session.finish("me")
            try? await Task.sleep(nanoseconds: 50_000_000)   // let sentences already on their way arrive first
            var heard = lines + last
            var how = "streamed"
            if let whole = try? await session.whole("me"), !whole.isEmpty { heard = whole; how = "whole clip" }
            let text = DictationText.clean(heard.map(\.text).joined(separator: " "), removeFillers: removeFillers)
            let ready = Date().timeIntervalSince(released)
            let pasted = deliver(text)
            AppLog.write(String(format: "dictation: %d words from %.1f s of speech (%@), ready %.2f s after letting go%@",
                                text.split(separator: " ").count, released.timeIntervalSince(startedAt), how, ready,
                                pasted ? "" : " (left on the clipboard)"))
            if !Self.allowsDevices { AppLog.write("dictation text: \(text)") }   // test copies only
        } catch {
            show("Dictation failed: \(error.localizedDescription)")
            AppLog.write("dictation failed: \(error.localizedDescription)")
        }
        state = .idle
        if notice == nil { DictationIndicator.shared.hide() }
        unloadIfOff()
    }

    /// A shortcut that uses the push-to-talk key (⌥Space with right ⌥) went off: the key was held for it, not to talk.
    /// Carbon's shortcuts take their key press, so `handle` never sees the Space that would otherwise cancel.
    func cancelHeldKey() {
        guard pressedAt != nil, state == .listening(handsFree: false) else { return }
        pressedAt = nil
        cancel(nil)
    }

    /// Throws the recording away (Esc, a shortcut, a single tap), with an optional message.
    func cancel(_ message: String?) {
        guard state != .idle else { return }
        mic?.stop(); mic = nil
        pump?.cancel(); pump = nil
        _ = sound.take()
        state = .idle
        if let session { resetting = Task { _ = try? await session.finish("me") } }   // the stream starts afresh
        if let message, message != "cancelled" { show(message) } else { DictationIndicator.shared.hide() }
        unloadIfOff()
    }

    /// Loads the speech helper ahead of the first dictation (a second or two; the first time after an update, while
    /// the Neural Engine prepares the model, longer), so pressing the key never waits for it.
    private func warmUp() {
        guard Transcriber.isSupported, Transcriber.isPrepared else { return }
        let session = self.session ?? makeSession()
        self.session = session
        Task { try? await session.start() }
    }

    private func makeSession() -> TranscriberSession {
        TranscriberSession(onLive: { _, lines, partial in
            Task { @MainActor in Dictation.shared.heard(lines, partial: partial) }
        })
    }

    /// The speech helper let go now (its models are being removed).
    func unload() async {
        await session?.stop()
        session = nil
    }

    /// Push to talk turned off: the helper is let go.
    private func unloadIfOff() {
        guard !enabled, state == .idle else { return }
        Task { await session?.stop() }
        session = nil
    }

    private func show(_ message: String) {
        notice = message
        DictationIndicator.shared.show()
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                let d = Dictation.shared
                guard d.notice == shown else { return }
                d.notice = nil
                if d.state == .idle { DictationIndicator.shared.hide() }
            }
        }
    }

    // MARK: Pasting

    /// Types the text where the cursor is: through the clipboard and ⌘V, then the clipboard gets its contents back.
    /// Without Accessibility permission the text stays on the clipboard. Whether it was pasted.
    private func deliver(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard Self.allowsDevices else { return true }
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)
        guard AXIsProcessTrusted() else {
            show("Copied. Press ⌘V to paste (allow Accessibility in Settings to paste by itself).")
            return false
        }
        let ours = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        // Back to what was on the clipboard, unless something else was copied meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard board.changeCount == ours, !saved.isEmpty else { return }
            board.clearContents()
            board.writeObjects(saved)
        }
        return true
    }
}

/// Sound from the microphone thread, taken by the sender every 0.2 s.
private final class Pending: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    func append(_ more: [Float]) { lock.lock(); samples += more; lock.unlock() }
    func take() -> [Float] { lock.lock(); defer { samples = []; lock.unlock() }; return samples }
}

// MARK: The indicator

/// A small pill at the bottom of the screen while you talk: listening, the words so far, then a moment's "writing".
/// It never takes the focus (the text goes to the app you were in) and lets clicks through.
@MainActor
final class DictationIndicator {
    static let shared = DictationIndicator()
    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = NSSize(width: 560, height: 120)
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 24, width: size.width, height: size.height),
                           display: false)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: DictationPill(dictation: .shared))
        return panel
    }
}

private struct DictationPill: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                switch dictation.state {
                case .finishing:
                    ProgressView().controlSize(.small)
                    Text("Writing…").foregroundStyle(.secondary)
                case .listening(let handsFree):
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(words.isEmpty ? (handsFree ? "Listening hands-free · press \(dictation.key.short) to finish" : "Listening…") : words)
                        .lineLimit(2).truncationMode(.head)
                        .foregroundStyle(words.isEmpty ? .secondary : .primary)
                case .idle:
                    Text(dictation.notice ?? "").foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// The last of what's been heard, so the pill stays one or two lines.
    private var words: String {
        let text = dictation.heardText
        return text.count > 140 ? "…" + text.suffix(140) : text
    }
}
