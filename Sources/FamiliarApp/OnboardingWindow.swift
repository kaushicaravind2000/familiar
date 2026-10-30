import AppKit
import AVFoundation
import FamiliarCore
import SwiftUI

/// First launch, in four short steps: what Familiar is (and every model starts downloading), which folders to
/// read, the two permissions speech needs, and a first dictation to try. Each permission is asked for right where
/// it's explained, with a tick when it's given; anything can be skipped and done later in Settings. The detailed setup
/// screen (`SetupWindowController`) stays in Settings for changing models.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Welcome to Familiar"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView())
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // Closed before the end: what was chosen so far stands, and the folders are read.
        if !AppState.shared.setupDone { AppState.shared.finishSetup() }
        DispatchQueue.main.async { AppWindows.updateActivationPolicy() }
    }
}

private enum Step: Int, CaseIterable { case welcome, files, permissions, tryIt }

struct OnboardingView: View {
    @ObservedObject private var app = AppState.shared
    @State private var step: Step = .welcome
    private let speechPossible = Transcriber.isSupported

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep(next: { app.setUpEverything(); go(.files) })
                case .files: FilesStep(next: { app.finishSetup(); go(speechPossible ? .permissions : nil) })
                case .permissions: PermissionsStep(next: { go(.tryIt) })
                case .tryIt: TryStep(done: { go(nil) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44).padding(.top, 44)
            if step != .welcome { DownloadStrip(app: app).padding(.horizontal, 44).padding(.bottom, 14) }
            dots.padding(.bottom, 18)
        }
        .frame(width: 640, height: 580)
        .onAppear {
            // For testing: `-debugOnboardingStep 2` opens on that step (screenshots), without doing the ones before.
            if let s = Step(rawValue: UserDefaults.standard.integer(forKey: "debugOnboardingStep")) { step = s }
        }
    }

    /// The next step, or the end (nil): the window closes and the app opens.
    private func go(_ next: Step?) {
        guard let next else {
            OnboardingWindowController.shared.close()
            MainWindowController.shared.show(page: .search)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases.filter { speechPossible || ($0 != .permissions && $0 != .tryIt) }, id: \.self) { s in
                Circle().fill(s == step ? Color.accentColor : Color.primary.opacity(0.15)).frame(width: 7, height: 7)
            }
        }
    }
}

// MARK: Welcome

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            VStack(spacing: 8) {
                Text("Your Mac, searchable and listening").font(.system(size: 26, weight: .semibold))
                Text("Find any file by describing it, ask questions about your files and meetings, and type by talking. All of it runs on this Mac: nothing you have, say or ask leaves it.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                Feature(icon: "magnifyingglass", title: "Search", text: "Documents, PDFs, pictures, recordings, by what's in them.")
                Feature(icon: "bubble.left.and.text.bubble.right", title: "Ask", text: "Answers from your files and meetings, with the sources.")
                Feature(icon: "waveform", title: "Speak", text: "Hold a key to type with your voice; record meetings with notes.")
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Button(action: next) { Text("Get Started").frame(width: 200) }
                .controlSize(.large).keyboardShortcut(.defaultAction)
            Text("The models download now, while you finish setting up (about \(totalGB) GB, once).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var totalGB: String {
        var bytes = EmbeddingModelFiles.totalBytes + ChatModelFiles.model.bytes
        if Transcriber.isSupported { bytes += SpeechModelFiles.totalBytes }
        return String(format: "%.0f", Double(bytes) / 1_000_000_000)
    }
}

private struct Feature: View {
    let icon: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Files

private struct FilesStep: View {
    @ObservedObject private var app = AppState.shared
    let next: () -> Void
    @State private var chosen: Set<URL> = []
    @State private var extra: [URL] = []
    @State private var asking = false

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let suggested: [(URL, String, Bool)] = {
        let fm = FileManager.default
        return [(FileManager.SearchPathDirectory.documentDirectory, "doc.text", true),
                (.desktopDirectory, "menubar.dock.rectangle", true),
                (.downloadsDirectory, "arrow.down.circle", true),
                (.picturesDirectory, "photo", false),
                (.moviesDirectory, "film", false)]
            .compactMap { dir, icon, on in fm.urls(for: dir, in: .userDomainMask).first.map { ($0, icon, on) } }
            .filter { fm.fileExists(atPath: $0.0.path) }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "What should Familiar read?",
                      text: "It reads these folders once, then keeps up as files change. Your files stay where they are, untouched.")
            VStack(spacing: 0) {
                ForEach(Self.suggested, id: \.0) { url, icon, _ in
                    FolderRow(url: url, icon: icon, on: binding(url))
                    Divider()
                }
                ForEach(extra, id: \.self) { url in
                    FolderRow(url: url, icon: "folder", on: binding(url))
                    Divider()
                }
                Button { chooseFolder() } label: {
                    Label("Another folder…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            Text("macOS asks once for each of these folders. Choose Allow.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(asking ? "Waiting for macOS…" : "Continue") { allowAndContinue() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || asking)
            }
        }
        .onAppear {
            chosen = Set(Self.suggested.filter(\.2).map(\.0))
            for url in app.folders { chosen.insert(url) }
        }
    }

    private func binding(_ url: URL) -> Binding<Bool> {
        Binding(get: { chosen.contains(url) }, set: { if $0 { chosen.insert(url) } else { chosen.remove(url) } })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard let window = OnboardingWindowController.shared.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            for url in panel.urls where !extra.contains(url) && !Self.suggested.contains(where: { $0.0 == url }) {
                extra.append(url)
                chosen.insert(url)
            }
        }
    }

    /// macOS's "allow access to your Documents folder" questions come now, one after another, while the person is
    /// looking at this, instead of at some moment during indexing: each folder is opened once, off the main thread.
    private func allowAndContinue() {
        asking = true
        let urls = Array(chosen)
        Task.detached {
            for url in urls { _ = try? FileManager.default.contentsOfDirectory(atPath: url.path) }
            await MainActor.run {
                let app = AppState.shared
                let gone = app.folders.filter { !urls.contains($0) }
                gone.forEach(app.remove)
                app.add(urls.filter { !app.folders.contains($0) })
                asking = false
                next()
            }
        }
    }
}

private struct FolderRow: View {
    let url: URL, icon: String
    @Binding var on: Bool
    var body: some View {
        Toggle(isOn: $on) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
                Text(FileManager.default.displayName(atPath: url.path))
                Spacer()
                Text((url.path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

// MARK: Permissions

private struct PermissionsStep: View {
    @ObservedObject private var dictation = Dictation.shared
    let next: () -> Void
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibility = AXIsProcessTrusted()
    @State private var askedAccessibility = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "Two permissions for speech",
                      text: "Needed to type by talking and to record meetings. You can skip this and turn them on later in Settings.")
            VStack(spacing: 0) {
                PermissionRow(icon: "mic", title: "Microphone", text: "To hear you: push to talk and meetings.",
                              granted: microphone == .authorized,
                              denied: microphone == .denied || microphone == .restricted,
                              button: "Allow", action: allowMicrophone,
                              deniedAction: { open("Privacy_Microphone") })
                Divider()
                PermissionRow(icon: "keyboard", title: "Accessibility",
                              text: askedAccessibility && !accessibility
                                ? "In the list that opened, turn on Familiar. This page ticks when it's done."
                                : "To notice the push-to-talk key and type what you said into any app.",
                              granted: accessibility, denied: false,
                              button: askedAccessibility ? "Open Settings Again" : "Allow", action: allowAccessibility,
                              deniedAction: {})
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            Text("Meetings also ask to record the Mac's sound (the other people on a call) the first time you record one.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(microphone == .authorized && accessibility ? "Continue" : "Skip for Now") { next() }
                    .controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .onReceive(poll) { _ in
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibility = AXIsProcessTrusted()
        }
    }

    private func allowMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    /// Push to talk goes on (its key is watched once the permission comes), and macOS's own dialog points at the
    /// Accessibility list; the list itself is opened too, in case that dialog was turned down before.
    private func allowAccessibility() {
        if !dictation.enabled { dictation.enabled = true } else { dictation.askForAccess() }
        if askedAccessibility { dictation.allowAgain() }   // a stale entry from an earlier install
        askedAccessibility = true
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

private struct PermissionRow: View {
    let icon: String, title: String, text: String
    let granted: Bool, denied: Bool
    let button: String
    let action: () -> Void
    let deniedAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(denied ? "Turned off. Turn on Familiar in Privacy & Security." : text)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else if denied {
                Button("Open Settings", action: deniedAction)
            } else {
                Button(button, action: action)
            }
        }
        .padding(14)
    }
}

// MARK: Try it

private struct TryStep: View {
    @ObservedObject private var dictation = Dictation.shared
    @ObservedObject private var app = AppState.shared
    let done: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "Try it: hold \(dictation.key.short) and talk",
                      text: "Say a sentence, then let go. What you said is typed below, as it would be in any app. Tap the key twice to talk hands-free.")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.title3)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                if text.isEmpty {
                    Text(placeholder).font(.title3).foregroundStyle(.tertiary).padding(.horizontal, 15).padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 8) {
                Text("From any app").font(.headline)
                Shortcut(keys: dictation.key.short, text: "Hold to type by talking")
                Shortcut(keys: GlobalShortcut.search.display, text: "Search your files, or press Tab to ask a question")
                Text("Record a meeting from the menu-bar icon. Shortcuts can be changed in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Start Using Familiar", action: done).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private var placeholder: String {
        if !dictation.trusted { return "Push to talk needs the Accessibility permission (previous step)." }
        if !Transcriber.isPrepared {
            if case .preparing(let value) = app.speechState { return "Getting speech ready… \(Int(value * 100))%" }
            return "Getting speech ready…"
        }
        return "Hold \(dictation.key.short), say something, let go."
    }
}

private struct Shortcut: View {
    let keys: String, text: String
    var body: some View {
        HStack(spacing: 10) {
            Text(keys).font(.system(.callout, design: .rounded).weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                .frame(minWidth: 96, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: Shared

private struct StepTitle: View {
    let title: String, text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The models downloading behind the steps: one line, one bar.
private struct DownloadStrip: View {
    @ObservedObject var app: AppState

    var body: some View {
        if let (done, label) = progress {
            HStack(spacing: 10) {
                ProgressView(value: done).frame(width: 140)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
        }
    }

    /// Nil once everything is in.
    private var progress: (Double, String)? {
        let search = EmbeddingModelFiles.totalBytes, chat = ChatModelFiles.model.bytes
        let speech = Transcriber.isSupported ? SpeechModelFiles.totalBytes : 0
        var have: Double = 0
        var waiting: [String] = []
        switch app.modelState {
        case .ready: have += Double(search)
        case .downloading(let done, _): have += Double(done); waiting.append("search")
        default: waiting.append("search")
        }
        if speech > 0 {
            if Transcriber.isPrepared { have += Double(speech) } else {
                if case .preparing(let value) = app.speechState { have += value * Double(speech) }
                waiting.append("speech")
            }
        }
        switch app.chatState {
        case .ready: have += Double(chat)
        case .downloading(let done, _): have += Double(done); waiting.append("chat")
        default: waiting.append("chat")
        }
        guard !waiting.isEmpty else { return nil }
        let total = Double(search + chat + speech)
        return (have / total, String(format: "Downloading models (%@): %.1f of %.1f GB", waiting.joined(separator: ", "),
                                     have / 1e9, total / 1e9))
    }
}
