import AppKit
import Carbon
import FamiliarCore
import SwiftUI
import UniformTypeIdentifiers

/// Setup on first launch, Settings after: the model download, the folders to search, indexing.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    static let shared = SettingsController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Familiar"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(app: AppState.shared))
            window.setContentSize(NSSize(width: 600, height: 700))
            window.minSize = NSSize(width: 520, height: 520)
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)   // a Dock icon while the window is open, so it can be found again
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Opens the folder chooser through the same code as "Add Folder…" (tests).
    func debugChooseFolders() {
        show()
        NotificationCenter.default.post(name: .chooseFolders, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { AppWindows.updateActivationPolicy() }   // the main window may still be open
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppState
    @ObservedObject private var dictation = Dictation.shared

    /// Dialogs open as sheets on the Settings window, never as app-wide modal panels (see `SourcesList`).
    private func presentSheet(_ present: (NSWindow) -> Void) {
        SettingsController.shared.show()
        guard let window = SettingsController.shared.window else { return }
        present(window)
    }

    private var sources: SourcesList {
        SourcesList(app: app, window: { SettingsController.shared.show(); return SettingsController.shared.window })
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                modelSection
                foldersSection
                if app.setupDone { indexSection } else { startButton }
                askSection.id("ask")
                dictationSection
                StorageSection(app: app).id("storage")
                generalSection.id("general")
                Text("Everything stays on this Mac. Familiar only reads your files: it never changes, moves or uploads them. It goes online only to download its models from Hugging Face: EmbeddingGemma, and the answer and speech models if you turn them on.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 24)
        }
        .onAppear {
            // For testing: `-debugSettingsSection ask` (or storage, general) scrolls to that section.
            if let section = UserDefaults.standard.string(forKey: "debugSettingsSection"), ["ask", "storage", "general"].contains(section) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(section, anchor: .top) }
            }
        }
        }
        .frame(minWidth: 520, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .chooseFolders)) { _ in sources.chooseSources() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.setupDone ? "Familiar" : "Welcome to Familiar").font(.title2.weight(.semibold))
                Text("Find files by what's in them: documents, PDFs, pictures, recordings and videos. Describe it in your own words and press \(GlobalShortcut.display) from any app.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section(title: "1. The model", icon: "cpu") {
            VStack(alignment: .leading, spacing: 8) {
                Text("EmbeddingGemma 2 by Google DeepMind runs on this Mac and understands text, pictures and sound in 100+ languages. It's an 865 MB download, once.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch app.modelState {
                case .ready:
                    Label("Downloaded and ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing:
                    Button("Download the Model") { app.download() }.controlSize(.large)
                case .downloading(let done, let total):
                    ProgressView(value: Double(done), total: Double(total))
                    HStack {
                        Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        Spacer()
                        if let eta = app.downloadETA { Text("\(eta.roughly) left") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                case .verifying:
                    ProgressView().controlSize(.small)
                    Text("Checking the download…").font(.caption).foregroundStyle(.secondary)
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try Again") { app.download() }
                }
            }
        }
    }

    // MARK: Folders

    private var foldersSection: some View {
        Section(title: "2. What to search", icon: "folder") {
            sources
        }
    }

    private var startButton: some View {
        HStack {
            Spacer()
            Button {
                app.finishSetup()
            } label: {
                Text(app.modelState == .ready ? "Start Indexing" : "Start Once the Model Is Ready").frame(minWidth: 200)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(app.folders.isEmpty)
        }
    }

    // MARK: Index

    private var indexSection: some View {
        Section(title: "3. Index", icon: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 8) {
                if let notice = app.indexNotice {
                    Label(notice, systemImage: "wrench.and.screwdriver").foregroundStyle(.orange)
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(app.statusLine).font(.callout)
                    Spacer()
                    if let eta = app.indexETA { Text("\(eta.roughly) left").font(.caption).foregroundStyle(.secondary) }
                }
                if app.progress.phase == .indexing || app.progress.phase == .paused, app.progress.total > 0 {
                    ProgressView(value: Double(app.progress.done), total: Double(app.progress.total))
                    if let current = app.progress.current {
                        Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } else if app.progress.phase == .scanning {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(spacing: 14) {
                    stat("Files", app.counts.files)
                    stat("Searchable pieces", app.counts.segments)
                    if app.counts.failed > 0 { stat("Couldn't read", app.counts.failed) }
                }
                if !app.counts.byKind.isEmpty {
                    Text(kindsLine).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if app.isIndexing || app.paused {
                        Button(app.paused ? "Resume" : "Pause") { app.togglePause() }
                    } else {
                        Button("Check for New Files") { app.indexNow() }
                            .disabled(app.modelState != .ready || app.folders.isEmpty)
                    }
                    Spacer()
                    Button("Rebuild Index…") { confirmRebuild() }
                }
            }
        }
    }

    private var kindsLine: String {
        let names: [String: String] = ["text": "notes", "document": "documents", "office": "slides & sheets", "pdf": "PDFs",
                                       "image": "pictures", "audio": "recordings", "video": "videos"]
        return app.counts.byKind.sorted { $0.value > $1.value }
            .map { "\($0.value.formatted()) \(names[$0.key] ?? $0.key)" }.joined(separator: " · ")
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func confirmRebuild() {
        let alert = NSAlert()
        alert.messageText = "Rebuild the index?"
        alert.informativeText = "Familiar forgets what it has read and reads every folder again. Your files aren't touched."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        presentSheet { window in
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { app.rebuild() }
            }
        }
    }

    // MARK: Ask

    private var askSection: some View {
        Section(title: "4. Ask your files", icon: "bubble.left.and.text.bubble.right") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ask a question and get a short answer from your files, with links to where it came from. Press Tab in the search panel to switch between Search and Ask. A second model writes the answers: Qwen3.5-4B, a 2.7 GB download that runs on this Mac and uses about 3.3 GB of memory while you're asking.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch app.chatState {
                case .ready:
                    Label("Answer model downloaded and ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing:
                    Button("Download the Answer Model (2.7 GB)") { app.downloadChat() }
                case .downloading(let done, let total):
                    ProgressView(value: Double(done), total: Double(total))
                    Text("\(ByteCountFormatter.string(fromByteCount: done, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                case .verifying:
                    ProgressView().controlSize(.small)
                    Text("Checking the download…").font(.caption).foregroundStyle(.secondary)
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try Again") { app.downloadChat() }
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Transcribe recordings and videos", isOn: $app.transcribeOn)
                        .disabled(app.speechState == .unsupported)
                    Group {
                        switch app.speechState {
                        case .unsupported:
                            Text("Needs macOS 14 or later.")
                        case .off:
                            Text("Writes down what's said, so you can ask about meetings and voice memos and find their exact words. Parakeet runs on the Neural Engine (a 1.2 GB download, once). English.")
                        case .preparing(let value):
                            HStack(spacing: 8) {
                                ProgressView(value: value).frame(maxWidth: 220)
                                Text(value < 0.99 ? "Downloading the speech model…" : "Preparing it for this Mac…")
                            }
                        case .ready:
                            Text("On. Recordings and videos get a transcript as they're indexed.")
                        case .failed(let why):
                            Text(why).foregroundStyle(.orange)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                }
            }
        }
    }

    // MARK: Push to talk

    private var dictationSection: some View {
        Section(title: "Push to talk", icon: "mic") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Type what you say, in any app", isOn: $dictation.enabled)
                        .disabled(app.speechState == .unsupported)
                    Text("Hold \(dictation.key.short) and speak; let go and it's typed where your cursor is. Tap it twice to talk hands-free, and press it again to finish. Esc throws it away. English, on this Mac, with the meetings' speech model.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                if dictation.enabled {
                    Picker("Key", selection: $dictation.key) {
                        ForEach(Dictation.Key.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 320)
                    if dictation.key == .function {
                        Text("Set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”, or macOS also opens its own emoji or dictation.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Remove “um” and “uh”", isOn: $dictation.removeFillers)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Use the Mac's microphone with Bluetooth headphones", isOn: $dictation.avoidsBluetooth)
                        Text("A Bluetooth headset's microphone switches it to call mode: the first second is lost, your voice sounds like a phone line, and music in the headphones gets worse. Meetings too.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 20)
                    }
                    if !dictation.trusted {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Needs Accessibility permission, to notice the key and type into other apps.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.caption)
                            Button("Allow Again") { dictation.allowAgain() }
                            Text("If Familiar is already switched on in the list, this replaces its entry (macOS keeps the old one after an update).")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section(title: "General", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shortcuts from any app").font(.subheadline.weight(.semibold))
                    ForEach(GlobalShortcut.allCases, id: \.self) { ShortcutField(hotkey: $0) }
                    Text("Click a shortcut and press the keys you want. Push to talk's key is under Push to talk. In the Familiar window: ⌘1 Search, ⌘2 Chat, ⌘3 Meetings, ⌘4 Sources, ⌘N new chat, ⌘R record.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Open Familiar at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                VStack(alignment: .leading, spacing: 2) {
                    Picker("On battery", selection: $app.batteryBehavior) {
                        ForEach(BatteryBehavior.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 320)
                    Text("Indexing keeps the graphics chip busy. In Low Power Mode it pauses, and when the Mac runs hot it slows down or pauses until it cools. Searching is never slowed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Read data files (csv, tsv, logs)", isOn: $app.readDataFiles)
                    Text("Off by default: they're mostly exports and machine output, which crowd search results. Keys, certificates and password files are never read.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Memory use", selection: $app.memoryChoice) {
                        Text("Automatic (\(MemoryProfile.automatic == .low ? "Low" : "Standard") for \(MemoryProfile.physicalGB) GB)")
                            .tag(MemoryProfile?.none)
                        Text("Standard").tag(MemoryProfile?.some(.standard))
                        Text("Low").tag(MemoryProfile?.some(.low))
                    }
                    .frame(maxWidth: 360)
                    Text("Low uses about 0.7 GB less while indexing, unloads the model sooner, and keeps search's copy of the index in a quarter of the memory. Automatic picks it on Macs with 12 GB or less.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Keep a search model loaded", isOn: $app.searchServerOn)
                    Text("Searches stay instant while files are being indexed, and never wait for the model to start. Uses about 330 MB of memory. Off: searches share the indexing model.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                HStack {
                    Button("Set Up This Mac…") { SetupWindowController.shared.show() }
                    Button("Open Search") { QuickPanelController.shared.show() }
                        .disabled(!app.setupDone || app.modelState != .ready)
                    Button("Show Index in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.index])
                    }
                }
            }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }
}

extension Notification.Name {
    /// Opens the folder chooser (the test hook `-debugChooseFolders`).
    static let chooseFolders = Notification.Name("FamiliarChooseFolders")
}

/// One chosen folder or file: what's in it, how it's doing, and what to do about it. Clicking it opens the folder in
/// Finder (or shows the file there).
private struct SourceRow: View {
    @ObservedObject var app: AppState
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    private var isFolder: Bool { AppState.isFolder(url.path) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                if let line = contents { Text(line).font(.caption).foregroundStyle(.secondary) }
                status
            }
            Menu {
                Button(isFolder ? "Open in Finder" : "Show in Finder") { open() }
                Button("Check Again") { app.checkAgain(url) }
                Divider()
                Button("Remove…", role: .destructive) { onRemove() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.075 : 0.04)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open() }
        .help(isFolder ? "Open in Finder" : "Show in Finder")
    }

    private func open() {
        if isFolder { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// "353 files · 247 pictures · 41 PDFs · 65 documents".
    private var contents: String? {
        guard let counts = app.sourceCounts[url.path], counts.files > 0 else { return nil }
        let k = counts.byKind
        var parts = ["\(counts.files.formatted()) file\(counts.files == 1 ? "" : "s")"]
        let groups: [(String, String, Int)] = [
            ("picture", "pictures", k["image"] ?? 0), ("PDF", "PDFs", k["pdf"] ?? 0),
            ("document", "documents", (k["text"] ?? 0) + (k["document"] ?? 0) + (k["office"] ?? 0)),
            ("recording", "recordings", k["audio"] ?? 0), ("video", "videos", k["video"] ?? 0),
        ]
        if isFolder {
            for (one, many, n) in groups where n > 0 { parts.append("\(n.formatted()) \(n == 1 ? one : many)") }
        }
        if counts.failed > 0 { parts.append("\(counts.failed) skipped or unreadable") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch app.state(of: url) {
        case .searchable:
            Label("Searchable", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking for new and changed files…") }
                .font(.caption).foregroundStyle(.secondary)
        case .indexing(let done, let total):
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 180)
                Text("Reading \(done.formatted()) of \(total.formatted())").font(.caption).foregroundStyle(.secondary)
            }
        case .waiting(let reason):
            HStack(spacing: 8) {
                Label("Waiting: \(reason)", systemImage: "pause.circle.fill").foregroundStyle(.orange).font(.caption)
                if app.paused {
                    Button("Resume") { app.togglePause() }.controlSize(.small)
                } else {
                    Button("Index Anyway") { app.startIndexingAnyway() }.controlSize(.small)
                }
            }
        case .refused:
            HStack(spacing: 8) {
                Label("macOS didn't allow access", systemImage: "lock.fill").foregroundStyle(.orange).font(.caption)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }.controlSize(.small)
            }
        case .missing(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        case .empty:
            Text(isFolder ? "Nothing Familiar reads in here yet" : "Not readable: a type Familiar doesn't read, or skipped (like a key or password file)")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The chosen folders and files: add (button, drop, suggestions), open in Finder, check again, remove, and macOS's
/// refusals. Shown in Settings ("2. What to search") and on the main window's Sources page.
struct SourcesList: View {
    @ObservedObject var app: AppState
    /// The window dialogs attach to as sheets.
    let window: () -> NSWindow?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Folders and files Familiar may read. Click one to open it in Finder.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { chooseSources() } label: { Label("Add…", systemImage: "plus") }
            }
            VStack(spacing: 6) {
                if app.folders.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 24)).foregroundStyle(.secondary)
                        Text("Drop folders or files here, or choose Add…").font(.callout).foregroundStyle(.secondary)
                        Text("macOS will ask you to allow access to some folders.").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                }
                ForEach(app.folders, id: \.self) { url in
                    SourceRow(app: app, url: url, onRemove: { confirmRemove(url) })
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(app.folders.isEmpty ? 0.18 : 0),
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: app.folders.isEmpty ? [5, 4] : [])))
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                addDropped(providers)
                return true
            }
            let suggestions = suggested.filter { s in !app.folders.contains { s.path.hasPrefix($0.path) || $0.path.hasPrefix(s.path + "/") } }
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("Add:").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(suggestions, id: \.self) { url in
                            Button { app.add([url]) } label: {
                                Label(url.lastPathComponent, systemImage: "plus").font(.callout).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            if !app.deniedFolders.isEmpty { deniedNotice }
        }
    }

    /// Files and folders dropped on the list.
    private func addDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { app.add(urls) }
    }

    private func confirmRemove(_ url: URL) {
        let alert = NSAlert()
        let files = app.sourceCounts[url.path]?.files ?? 0
        alert.messageText = "Stop searching “\(url.lastPathComponent)”?"
        alert.informativeText = files > 0
            ? "Its \(files.formatted()) file\(files == 1 ? "" : "s") leave the index. The files themselves aren't touched."
            : "The files themselves aren't touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        presentSheet { window in
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { app.remove(url) }
            }
        }
    }

    /// Folders macOS wouldn't open: their files aren't searchable until access is allowed.
    private var deniedNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("macOS didn't allow Familiar to open \(app.deniedFolders.count == 1 ? "this folder" : "these folders"), so the files in \(app.deniedFolders.count == 1 ? "it" : "them") can't be searched:",
                  systemImage: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            ForEach(app.deniedFolders.prefix(5), id: \.self) { path in
                Text((path as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            if app.deniedFolders.count > 5 { Text("and \(app.deniedFolders.count - 5) more").font(.caption).foregroundStyle(.secondary) }
            Text("Allow Familiar under Files & Folders (or Full Disk Access), then choose Check for New Files.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }
                Button("Check for New Files") { app.indexNow() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private var suggested: [URL] {
        let fm = FileManager.default
        return [.desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory, .moviesDirectory, .musicDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    /// Dialogs open as sheets on the window this list is in, never as app-wide modal panels: a modal panel stops the
    /// whole app until it's answered and can open behind other windows, which looked like a hang and blocked quitting.
    private func presentSheet(_ present: (NSWindow) -> Void) {
        guard let window = window() else { return }
        present(window)
    }

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Search These"
        panel.message = "Choose folders or files for Familiar to read."
        presentSheet { window in
            panel.beginSheetModal(for: window) { response in
                if response == .OK { app.add(panel.urls) }
            }
        }
    }
}

/// One shortcut from any app: click it, press the keys (Esc cancels). Combinations macOS uses, or without ⌘, ⌥ or ⌃,
/// aren't taken; one another app holds is kept but said so, since it won't work until that app lets it go.
private struct ShortcutField: View {
    let hotkey: GlobalShortcut
    @State private var combo: KeyCombo?
    @State private var recording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                Text(hotkey.label)
                Spacer()
                if combo != hotkey.defaultCombo && !recording {
                    Button("Default") { set(hotkey.defaultCombo) }.buttonStyle(.link).font(.caption)
                }
                Button { recording ? stop() : start() } label: {
                    Text(recording ? "Press keys…" : (combo?.display ?? "None"))
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(minWidth: 90)
                }
                // Always there (hidden when there's nothing to clear), so the shortcut buttons line up.
                Button { set(nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).help("No shortcut")
                    .opacity(combo != nil && !recording ? 1 : 0).disabled(combo == nil || recording)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .onAppear {
            combo = hotkey.combo
            if GlobalShortcut.taken.contains(hotkey), let combo { message = "Another app uses \(combo.display), so it doesn't work here. Choose another." }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        message = nil
        recording = true
        GlobalShortcut.unregisterAll()   // or pressing the current one would open the panel instead of being recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
                let new = KeyCombo(event)
                if let problem = new.problem {
                    message = problem
                } else if let other = GlobalShortcut.allCases.first(where: { $0 != hotkey && $0.combo == new }) {
                    message = "\(new.display) is already \(other.label.lowercased())."
                } else {
                    set(new)
                    stop()
                }
                return nil
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        GlobalShortcut.registerAll()
    }

    private func set(_ new: KeyCombo?) {
        hotkey.combo = new
        combo = new
        message = new != nil && GlobalShortcut.taken.contains(hotkey) ? "Another app uses \(new!.display), so it doesn't work here. Choose another." : nil
        AppLog.write("shortcut for \(hotkey): \(new?.display ?? "none")")
    }
}

/// What Familiar keeps on disk: each model with its size (all but search's can be removed, and downloaded again
/// later), the index, and meetings, whose audio can be deleted after a while. Sizes are measured when it appears.
private struct StorageSection: View {
    @ObservedObject var app: AppState
    @State private var sizes = Sizes()
    @State private var keepDays = Storage.meetingAudioDays
    @State private var confirm: Confirm?
    @State private var problem: String?

    private struct Sizes {
        var search: Int64 = 0, chat: Int64 = 0, speech: Int64 = 0, unused: Int64 = 0, index: Int64 = 0
        var audio: Int64 = 0, meetings = 0
    }

    private enum Confirm: Identifiable {
        case chat, speech, unused, audio(Int, [URL])
        var id: String {
            switch self { case .chat: return "chat"; case .speech: return "speech"; case .unused: return "unused"; case .audio(let d, _): return "audio\(d)" }
        }
    }

    var body: some View {
        Section(title: "Storage", icon: "internaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                row("Search model", sizes.search, note: "EmbeddingGemma 2. Search needs it.")
                row("Answer model", sizes.chat, note: "Qwen3.5-4B, for Ask.",
                    remove: sizes.chat > 0 ? { confirm = .chat } : nil)
                row("Speech models", sizes.speech, note: "Parakeet, echo removal and speaker separation, for push to talk and meetings.",
                    remove: sizes.speech > 0 ? { confirm = .speech } : nil)
                if sizes.unused > 0 {
                    row("Older models", sizes.unused, note: "From earlier versions; not used any more.", remove: { confirm = .unused })
                }
                row("Index", sizes.index, note: "What Familiar has read from your files.")
                Divider()
                row("Meeting audio", sizes.audio,
                    note: sizes.meetings == 0 ? "No recordings." : "\(sizes.meetings) meeting\(sizes.meetings == 1 ? "" : "s"), about 30 MB an hour.")
                VStack(alignment: .leading, spacing: 2) {
                    Picker("Keep meeting audio", selection: Binding(get: { keepDays }, set: { choose($0) })) {
                        Text("Always").tag(0)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .frame(maxWidth: 320)
                    Text("Older recordings are deleted; their transcripts and notes stay, so they can still be read, searched and asked about, but not played.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            }
        }
        .onAppear { measure() }
        .confirmationDialog(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { what in
            Button(button(what), role: .destructive) { act(what) }
            Button("Cancel", role: .cancel) {}
        } message: { what in Text(message(what)) }
    }

    private func row(_ title: String, _ bytes: Int64, note: String, remove: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "None")
                .foregroundStyle(.secondary).monospacedDigit()
            Button("Remove…") { remove?() }
                .opacity(remove == nil ? 0 : 1).disabled(remove == nil)   // there or not, the sizes line up
        }
    }

    private var title: String {
        switch confirm {
        case .chat: return "Remove the answer model?"
        case .speech: return "Remove the speech models?"
        case .unused: return "Remove the older models?"
        case .audio(let days, let urls): return "Delete the audio of \(urls.count) meeting\(urls.count == 1 ? "" : "s") older than \(days) days?"
        case nil: return ""
        }
    }

    private func message(_ what: Confirm) -> String {
        switch what {
        case .chat: return "Ask stops working until it's downloaded again (2.7 GB, from the Chat page)."
        case .speech: return "Push to talk and transcribing recordings turn off, and meetings can't be recorded until they're downloaded again (1.2 GB). Saved meetings stay."
        case .unused: return "Nothing uses them."
        case .audio: return "Their transcripts and notes stay. The audio can't be brought back."
        }
    }

    private func button(_ what: Confirm) -> String {
        switch what { case .audio: return "Delete Audio"; default: return "Remove" }
    }

    /// A shorter time asks first when it would delete recordings now.
    private func choose(_ days: Int) {
        let old = Storage.meetingAudio(olderThan: days)
        if old.isEmpty { apply(days) } else { confirm = .audio(days, old) }
    }

    private func apply(_ days: Int) {
        keepDays = days
        Storage.meetingAudioDays = days
        app.deleteOldMeetingAudio()
        measure()
    }

    private func act(_ what: Confirm) {
        problem = nil
        Task {
            switch what {
            case .chat: await app.removeChatModel()
            case .speech:
                do { try await app.removeSpeechModels() } catch { problem = error.localizedDescription }
            case .unused: Storage.removeUnusedSpeech(); AppLog.write("storage: removed the older models")
            case .audio(let days, _): apply(days)
            }
            measure()
        }
    }

    /// Sizes, measured off the main thread (a few hundred files; meeting audio can be many).
    private func measure() {
        Task.detached {
            let speech = Storage.speechFolder
            var s = Sizes()
            s.search = EmbeddingModelFiles.all.reduce(0) { $0 + Storage.size(of: $1.installed) }
            s.chat = Storage.size(of: ChatModelFiles.model.installed)
            s.unused = Storage.unusedSpeech.reduce(0) { $0 + Storage.size(of: $1) }
            s.speech = max(0, Storage.size(of: speech) - s.unused)
            s.index = ["", "-wal", "-shm"].reduce(0) { $0 + Storage.size(of: URL(fileURLWithPath: AppPaths.index.path + $1)) }
            let audio = Storage.meetingAudio()
            s.audio = audio.reduce(0) { $0 + Storage.size(of: $1.url) }
            s.meetings = audio.count
            let measured = s
            await MainActor.run { sizes = measured }
        }
    }
}
