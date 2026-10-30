import AppKit
import FamiliarCore
import SwiftUI

/// Setup: reads this Mac (model, chip, memory, macOS, free disk), shows what Familiar will set up on it and how,
/// and does it in one click. Shown on first launch, and any time from Settings or the Go menu.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Set Up Familiar"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(app: AppState.shared))
            window.setContentSize(NSSize(width: 720, height: 820))
            window.minSize = NSSize(width: 600, height: 560)
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
        DispatchQueue.main.async { AppWindows.updateActivationPolicy() }
    }
}

struct SetupView: View {
    @ObservedObject var app: AppState
    private let plan = SetupPlan()
    @State private var wantChat = true
    @State private var wantSpeech = true
    @State private var started = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                macCard
                VStack(alignment: .leading, spacing: 10) {
                    Text("What Familiar sets up on this Mac").font(.headline)
                    componentList
                    diskLine
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("What to search").font(.headline)
                    SourcesList(app: app, window: { SetupWindowController.shared.window })
                }
                footer
                Text("Everything runs on this Mac. The models download once from Hugging Face, each checked against a fixed fingerprint; your files never leave the Mac.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 28)
        }
        .frame(minWidth: 600, minHeight: 560)
        .onAppear {
            wantChat = app.chatState == .ready || app.chatState == .missing
            wantSpeech = isSpeechPossible
        }
    }

    private var isSpeechPossible: Bool { if case .unavailable = plan.speech { return false } else { return true } }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.setupDone ? "Familiar on this Mac" : "Set up Familiar").font(.title2.weight(.semibold))
                Text("Familiar checked your Mac and picked the setup that fits it. Change anything below, then press Set Up.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var macCard: some View {
        let mac = plan.mac
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: mac.isLaptop ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 34)).foregroundStyle(.secondary).frame(width: 48)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(mac.name).font(.headline)
                    Text(plan.tierTitle).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(tierColor.opacity(0.18)))
                        .foregroundStyle(tierColor)
                }
                Text([mac.chip, mac.coresText.isEmpty ? nil : mac.coresText].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text("\(mac.memoryGB) GB memory · \(mac.macOSText) · \(Int(mac.freeDiskGB.rounded())) GB free")
                    .foregroundStyle(.secondary)
                Text(plan.tierSummary).font(.callout).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07)))
    }

    private var tierColor: Color {
        switch plan.tier { case .light: return .orange; case .standard: return .blue; case .fast: return .green }
    }

    private var componentList: some View {
        VStack(spacing: 0) {
            ComponentRow(icon: "magnifyingglass", title: "Search", model: "EmbeddingGemma 2", size: EmbeddingModelFiles.totalBytes,
                         note: "Finds files by what's in them: documents, PDFs, pictures, recordings and videos.",
                         status: status(app.modelState), toggle: nil)
            Divider()
            ComponentRow(icon: "text.viewfinder", title: "Text in pictures and scans", model: "Apple Vision (built into macOS)", size: 0,
                         note: "Reads screenshots, photos of documents and scanned pages.", status: .ready, toggle: nil)
            Divider()
            ComponentRow(icon: "bubble.left.and.text.bubble.right", title: "Chat", model: "Qwen3.5-4B", size: ChatModelFiles.model.bytes,
                         note: plan.chatNote, status: wantChat ? status(app.chatState) : .off, toggle: $wantChat)
            Divider()
            ComponentRow(icon: "waveform", title: "Meetings & recordings", model: "Parakeet", size: SpeechModelFiles.totalBytes,
                         note: speechNote, status: speechStatus, toggle: isSpeechPossible ? $wantSpeech : nil)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07)))
    }

    private var speechNote: String {
        switch plan.speech {
        case .available: return "Records meetings (your mic and the call's sound) and writes down what's said; transcribes recordings in your folders."
        case .limited(let why), .unavailable(let why): return why
        }
    }

    private var speechStatus: ComponentRow.Status {
        if !isSpeechPossible { return .unavailable }
        if !wantSpeech { return .off }
        switch app.speechState {
        case .preparing(let value): return .working(value, "Getting it ready")
        case .failed(let why): return .failed(why)
        default: return Transcriber.isPrepared ? .ready : .willDownload
        }
    }

    private func status(_ state: AppState.ModelState) -> ComponentRow.Status {
        switch state {
        case .ready: return .ready
        case .missing: return .willDownload
        case .downloading(let done, let total): return .working(Double(done) / Double(max(total, 1)), "Downloading")
        case .verifying: return .working(1, "Checking the download")
        case .failed(let why): return .failed(why)
        }
    }

    /// What still has to be downloaded for the choices made, against the free disk.
    private var neededBytes: Int64 {
        var bytes: Int64 = 0
        if !EmbeddingModelFiles.isInstalled { bytes += EmbeddingModelFiles.totalBytes }
        if wantChat && !ChatModelFiles.isInstalled { bytes += ChatModelFiles.model.bytes }
        if wantSpeech && isSpeechPossible { bytes += SpeechModelFiles.all.filter { !$0.isInstalled }.reduce(0) { $0 + $1.bytes } }   // only what's missing
        return bytes
    }

    private var diskLine: some View {
        let need = Double(neededBytes) / 1_000_000_000
        let free = plan.mac.freeDiskGB
        let enough = free > need + 2
        return Label(need == 0 ? "Nothing more to download." :
                        String(format: "Downloads %.1f GB. This Mac has %.0f GB free%@", need, free, enough ? "." : ": free up some space first."),
                     systemImage: enough ? "internaldrive" : "exclamationmark.triangle")
            .font(.callout).foregroundStyle(enough ? Color.secondary : Color.orange)
    }

    private var everythingReady: Bool {
        app.modelState == .ready && (!wantChat || app.chatState == .ready)
            && (!wantSpeech || !isSpeechPossible || Transcriber.isPrepared) && app.setupDone
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { SettingsController.shared.show() }
            if app.folders.isEmpty {
                Text("Add at least one folder to search.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if app.setupDone && !started && everythingReady {
                // Already set up and nothing to change: close and go to the app.
                Button("Done") {
                    SetupWindowController.shared.close()
                    MainWindowController.shared.show()
                }
                .keyboardShortcut(.defaultAction).controlSize(.large)
            } else if started && everythingReady {
                Button("Open Familiar") {
                    SetupWindowController.shared.close()
                    MainWindowController.shared.show(page: .chat)
                }
                .keyboardShortcut(.defaultAction).controlSize(.large)
            } else {
                Button(started ? "Setting Up…" : (app.setupDone ? "Apply" : "Set Up")) { setUp() }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
                    .disabled(app.folders.isEmpty || (started && !everythingReady) || plan.mac.freeDiskGB < Double(neededBytes) / 1_000_000_000 + 2)
            }
        }
    }

    private func setUp() {
        started = true
        AppLog.write("setup: \(plan.mac.name), \(plan.mac.chip), \(plan.mac.memoryGB) GB, \(plan.mac.macOSText) → \(plan.tierTitle); chat \(wantChat), meetings \(wantSpeech)")
        if wantChat && !ChatModelFiles.isInstalled { app.downloadChat() }
        if wantSpeech && isSpeechPossible { app.transcribeOn = true }
        if app.setupDone { if !EmbeddingModelFiles.isInstalled { app.download() } } else { app.finishSetup() }
    }
}

/// One part of the setup: what it is, which model, its size, and where it stands.
private struct ComponentRow: View {
    enum Status: Equatable { case ready, willDownload, working(Double, String), failed(String), off, unavailable }

    let icon: String
    let title: String
    let model: String
    let size: Int64
    let note: String
    let status: Status
    let toggle: Binding<Bool>?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    Text("· \(model)\(size > 0 ? " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "")")
                        .foregroundStyle(.secondary)
                }
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                statusView
            }
            Spacer(minLength: 8)
            if let toggle { Toggle("", isOn: toggle).toggleStyle(.switch).labelsHidden() }
        }
        .padding(14)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .willDownload: Label("Downloads when you press Set Up", systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary)
        case .working(let value, let what):
            HStack(spacing: 8) {
                ProgressView(value: value).frame(maxWidth: 200)
                Text("\(what)… \(Int(value * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .off: Label("Off", systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary)
        case .unavailable: Label("Not available on this Mac", systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
}
