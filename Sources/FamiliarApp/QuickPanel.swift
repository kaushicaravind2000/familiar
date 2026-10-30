import AppKit
import Combine
import FamiliarCore
import SwiftUI

/// The search state behind the panel: the query, the results and the selection; in Ask mode, the question, the
/// answer as it's written and the passages it quotes.
@MainActor
final class PanelModel: ObservableObject {
    enum Mode { case search, ask }
    @Published var mode: Mode = .search { didSet { if mode != oldValue { modeChanged() } } }
    @Published var query = "" { didSet { if query != oldValue && mode == .search { scheduleSearch() } } }
    @Published var filter: KindFilter = .all { didSet { if filter != oldValue { scheduleSearch(delay: 0) } } }
    @Published private(set) var results: [SearchResult] = []
    @Published var selection = 0
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    /// After an arrow key, Space previews the selection instead of typing a space.
    var navigating = false
    private var task: Task<Void, Never>?

    @Published private(set) var askedQuestion: String?
    @Published private(set) var answer = ""
    @Published private(set) var passages: [Passage] = []
    @Published private(set) var findingPassages = false
    @Published private(set) var answering = false
    @Published private(set) var askError: String?
    @Published var sourceSelection = 0
    private var askTask: Task<Void, Never>?
    private var indexWatch: AnyCancellable?

    init() {
        // While the index grows (the first pass, a new file), the search on screen catches up with it.
        indexWatch = AppState.shared.$counts.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, !self.query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            self.scheduleSearch(delay: 0, keepSelection: true)
        }
    }

    private func scheduleSearch(delay: UInt64 = 180_000_000, keepSelection: Bool = false) {
        guard mode == .search else { return }
        task?.cancel()
        if !keepSelection { navigating = false }
        let query = self.query, filter = self.filter
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []; searching = false; error = nil
            return
        }
        task = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            searching = true
            do {
                let found = try await AppState.shared.searcher.search(query, filter: filter)
                guard !Task.isCancelled else { return }
                let selectedPath = selected?.path
                results = found
                selection = keepSelection ? (found.firstIndex { $0.path == selectedPath } ?? 0) : 0
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            searching = false
        }
    }

    var selected: SearchResult? { results.indices.contains(selection) ? results[selection] : nil }
    var selectedPassage: Passage? { passages.indices.contains(sourceSelection) ? passages[sourceSelection] : nil }
    /// The text in the field is a new question (↩ asks it), not the one already answered (↩ opens a source).
    var questionIsNew: Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !q.isEmpty && q != askedQuestion
    }

    private func modeChanged() {
        if mode == .search {
            scheduleSearch(delay: 0)
        } else {
            task?.cancel()
            searching = false
            // Load the answer model while the question is typed: the first answer doesn't wait for it.
            if ChatModelFiles.isInstalled { Task.detached { try? await ChatService.shared.ensureRunning() } }
        }
    }

    func ask() {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        askTask?.cancel()
        askedQuestion = question
        answer = ""; passages = []; askError = nil; sourceSelection = 0
        findingPassages = true; answering = true
        AppState.shared.chatStarted()
        AppLog.write("ask: a question (\(question.count) characters)")
        askTask = Task {
            do {
                let (found, stream) = try await AppState.shared.asker.ask(question)
                guard !Task.isCancelled else { return }
                passages = found
                findingPassages = false
                for try await piece in stream {
                    guard !Task.isCancelled else { return }
                    answer += piece
                }
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { askError = error.localizedDescription }
            }
            guard !Task.isCancelled else { return }
            findingPassages = false
            answering = false
        }
    }

    func stopAnswering() {
        askTask?.cancel()
        findingPassages = false
        answering = false
    }

    func moveSource(_ delta: Int) {
        guard !passages.isEmpty else { return }
        sourceSelection = max(0, min(passages.count - 1, sourceSelection + delta))
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, selection + delta))
        navigating = true
    }
}

/// A floating panel, like Spotlight: it takes keystrokes without bringing the app forward, and closes when it loses
/// focus.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickPanelController()
    let model = PanelModel()
    private var panel: QuickPanel!
    private var keyMonitor: Any?

    private override init() {
        super.init()
        panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let host = NSHostingView(rootView: PanelView(model: model, app: AppState.shared))
        panel.contentView = host
    }

    func toggle() { panel.isVisible ? close() : show() }

    func show() {
        if !panel.isVisible { position() }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .focusSearchField, object: nil)
        installKeyMonitor()
        // Wake the model while the person types, so the first search doesn't wait for it to load.
        let embedder = AppState.shared.searcher.embedder
        if EmbeddingModelFiles.isInstalled { Task.detached { try? await embedder.ensureRunning() } }
    }

    func close() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Focus moving to the preview keeps the search open: it belongs to it.
        if UserDefaults.standard.bool(forKey: "debugKeepPanel") { return }   // for screenshots in tests
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let key = NSApp.keyWindow
            if key === PreviewWindowController.shared.window || key === self.panel { return }
            // No key window while Familiar is active: focus is in passage (macOS bringing the app forward).
            if key == nil && NSApp.isActive { return }
            PreviewWindowController.shared.close()
            self.close()
        }
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - frame.height * 0.12))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// The panel's keys: ↓↑ move, ↩ opens, ⌘↩ shows in Finder, Space previews (after moving), ⌘C copies the file,
    /// ⌘1–5 pick a filter, Esc closes, Tab switches between Search and Ask.
    private func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 48 && !command {
            model.mode = model.mode == .search ? .ask : .search
            return true
        }
        if model.mode == .ask { return handleAsk(event, command: command) }
        switch event.keyCode {
        case 125, 126:
            model.move(event.keyCode == 125 ? 1 : -1)
            if PreviewWindowController.shared.isVisible, let result = model.selected {
                PreviewWindowController.shared.show(result, query: model.query)
            }
            return true
        case 53:
            if PreviewWindowController.shared.isVisible { PreviewWindowController.shared.close() } else { close() }
            return true
        case 36, 76:
            guard let result = model.selected else { return true }
            if command { ResultActions.reveal(result) } else { ResultActions.open(result, query: model.query) }
            close()
            return true
        case 49 where model.navigating && !command:
            if let result = model.selected { PreviewWindowController.shared.toggle(result, query: model.query) }
            return true
        default:
            break
        }
        if command, let key = event.charactersIgnoringModifiers {
            if key == "c", let result = model.selected, panelTextIsNotSelected() {
                ResultActions.copy(result); return true
            }
            if let n = Int(key), (1...KindFilter.allCases.count).contains(n) {
                model.filter = KindFilter.allCases[n - 1]; return true
            }
        }
        return false
    }

    /// In Ask: ↩ asks a new question, or opens the selected source of the one answered; ↓↑ pick a source; ⌘↩ shows
    /// it in Finder; ⌘C copies the answer; Esc stops an answer being written, then closes.
    private func handleAsk(_ event: NSEvent, command: Bool) -> Bool {
        switch event.keyCode {
        case 125, 126:
            model.moveSource(event.keyCode == 125 ? 1 : -1)
            return true
        case 53:
            if model.answering { model.stopAnswering() } else { close() }
            return true
        case 36, 76:
            if model.questionIsNew || model.askedQuestion == nil { model.ask(); return true }
            guard let passage = model.selectedPassage else { return true }
            if command { ResultActions.reveal(passage.source) } else { ResultActions.open(passage.source, query: model.query) }
            close()
            return true
        default:
            break
        }
        if command, event.charactersIgnoringModifiers == "j" { continueInChat(); return true }
        if command, event.charactersIgnoringModifiers == "c", !model.answer.isEmpty, panelTextIsNotSelected() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.answer, forType: .string)
            return true
        }
        return false
    }

    /// ⌘J: the question and its answer become a new chat in the main window, where follow-ups can be asked.
    func continueInChat() {
        guard let question = model.askedQuestion, !model.answer.isEmpty, !model.answering else { return }
        MainWindowController.shared.chats.continueFromPanel(question: question, answer: model.answer, passages: model.passages)
        close()
        MainWindowController.shared.show(page: .chat)
    }

    func openPassage(_ number: Int) {
        guard let passage = model.passages.first(where: { $0.number == number }) else { return }
        ResultActions.open(passage.source, query: model.query)
        close()
    }

    private func panelTextIsNotSelected() -> Bool {
        guard let editor = panel.firstResponder as? NSTextView else { return true }
        return editor.selectedRange().length == 0
    }

    /// Called when the preview moved through results with its own arrows.
    func previewDidMove(_ delta: Int) {
        model.move(delta)
        if let result = model.selected { PreviewWindowController.shared.show(result, query: model.query) }
    }
}

extension Notification.Name {
    static let focusSearchField = Notification.Name("FamiliarFocusSearchField")
}

// MARK: - Views

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var app: AppState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.mode == .ask ? "bubble.left.and.text.bubble.right" : "magnifyingglass")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary).frame(width: 26)
                TextField(model.mode == .ask ? "Ask a question about your files" : "Describe what you're looking for", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .focused($fieldFocused)
                if model.searching || model.answering { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 6) {
                modeSwitch
                Divider().frame(height: 14).padding(.horizontal, 4)
                if model.mode == .search {
                ForEach(Array(KindFilter.allCases.enumerated()), id: \.element) { index, filter in
                    Button { model.filter = filter } label: {
                        Text(filter.rawValue).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(model.filter == filter ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.07)))
                            .foregroundStyle(model.filter == filter ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help("⌘\(index + 1)")
                }
                }
                Spacer()
                Text(app.statusLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 18).padding(.bottom, 10)

            Divider()
            content
            Divider()
            footer
        }
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .frame(minWidth: 560, minHeight: 300)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            fieldFocused = true
        }
        .onAppear { fieldFocused = true }
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach([PanelModel.Mode.search, .ask], id: \.self) { mode in
                Button { model.mode = mode } label: {
                    Label(mode == .search ? "Search" : "Ask", systemImage: mode == .search ? "magnifyingglass" : "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(model.mode == mode ? Color.primary.opacity(0.14) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .fixedSize()   // never squeezed by the filters into "Searc / h"
        .help("Tab switches between Search and Ask")
    }

    @ViewBuilder private var content: some View {
        if model.mode == .ask && app.modelState == .ready && !app.folders.isEmpty {
            askContent
        } else if app.modelState != .ready {
            message(icon: "arrow.down.circle", title: "Getting the model ready", detail: app.statusLine)
        } else if app.folders.isEmpty {
            message(icon: "folder.badge.plus", title: "Choose folders to search", detail: "Open Settings to pick them.")
        } else if let error = model.error {
            message(icon: "exclamationmark.triangle", title: "Search didn't work", detail: error)
        } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            message(icon: "sparkle.magnifyingglass", title: "Search by what's inside",
                    detail: "Try “the clause about pets in the lease”, “dog on the beach” or “where they talk about sleep”.")
        } else if model.results.isEmpty && !model.searching {
            message(icon: "questionmark.folder", title: "Nothing close", detail: "Try other words, or check that the folder is chosen in Settings.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            ResultRow(result: result, selected: index == model.selection)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    ResultActions.open(result, query: model.query)
                                    QuickPanelController.shared.close()
                                }
                                .simultaneousGesture(TapGesture().onEnded { model.selection = index })
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { value in   // the one-argument form also runs on macOS 13
                    guard model.results.indices.contains(value) else { return }
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(model.results[value].id) }
                }
            }
        }
    }

    @ViewBuilder private var askContent: some View {
        if app.chatState != .ready {
            VStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("Ask needs the answer model").font(.headline)
                switch app.chatState {
                case .downloading(let done, let total):
                    ProgressView(value: Double(done), total: Double(total)).frame(maxWidth: 300)
                    Text("Downloading: \(Int(Double(done) / Double(max(total, 1)) * 100))%").font(.callout).foregroundStyle(.secondary)
                case .verifying:
                    Text("Checking the download…").font(.callout).foregroundStyle(.secondary)
                case .failed(let why):
                    Text(why).font(.callout).foregroundStyle(.orange)
                    Button("Try Again") { app.downloadChat() }
                default:
                    Text("A 2.7 GB model that writes answers from your files, on this Mac. Nothing leaves it.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Download (2.7 GB)") { app.downloadChat() }.controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else if let question = model.askedQuestion {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(question).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    if model.findingPassages {
                        progressLine("Looking through your files…")
                    } else if model.answer.isEmpty && model.answering {
                        progressLine("Reading \(model.passages.count) passage\(model.passages.count == 1 ? "" : "s")…")
                    }
                    if !model.answer.isEmpty {
                        Text(Self.cited(model.answer, count: model.passages.count))
                            .font(.system(size: 15)).lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .environment(\.openURL, OpenURLAction { url in
                                if url.scheme == "sfcite", let n = Int(url.host ?? "") { QuickPanelController.shared.openPassage(n) }
                                return .handled
                            })
                    }
                    if let error = model.askError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                    if !model.answering && !model.answer.isEmpty {
                        Button { QuickPanelController.shared.continueInChat() } label: {
                            Label("Continue in Chat", systemImage: "bubble.left.and.text.bubble.right")
                        }
                        .help("Ask follow-ups in the main window (⌘J)")
                    }
                    if !model.passages.isEmpty {
                        Text("SOURCES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        VStack(spacing: 2) {
                            ForEach(Array(model.passages.enumerated()), id: \.element.id) { index, passage in
                                PassageRow(passage: passage, selected: index == model.sourceSelection)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { QuickPanelController.shared.openPassage(passage.number) }
                                    .simultaneousGesture(TapGesture().onEnded { model.sourceSelection = index })
                            }
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            message(icon: "sparkles", title: "Ask about your files",
                    detail: "Try “When does my health insurance renew?” or “What did we decide in the team meeting?”. Answers come from your files only, with links to where each part came from.")
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).font(.callout).foregroundStyle(.secondary) }
    }

    /// The answer as styled text: each [n] a link to passage n, and the little Markdown the model writes (headings,
    /// **bold**, *italics*, bullets) shown as such rather than as # and * marks.
    static func cited(_ answer: String, count: Int) -> AttributedString {
        let lines = answer.components(separatedBy: "\n").map { line -> String in
            if let r = line.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) {
                let title = line[r.upperBound...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                return title.isEmpty ? "" : "**\(title)**"
            }
            if let r = line.range(of: #"^(\s*)[-*+]\s+"#, options: .regularExpression) {
                let indent = line[r].prefix { $0 == " " || $0 == "\t" }.count >= 2 ? "    " : ""
                return indent + "• " + line[r.upperBound...]
            }
            return line
        }
        var markdown = lines.joined(separator: "\n")
        if count > 0 {
            markdown = markdown.replacingOccurrences(of: #"\[(\d+)\]"#, with: "[[$1]](sfcite://$1)", options: .regularExpression)
        }
        guard var styled = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(answer) }
        for run in styled.runs where run.link != nil {
            if let url = run.link, url.scheme == "sfcite", let n = Int(url.host ?? ""), (1...count).contains(n) {
                styled[run.range].foregroundColor = .accentColor
                styled[run.range].font = .system(size: 12, weight: .semibold)
            } else {
                styled[run.range].link = nil   // only citations are links
            }
        }
        return styled
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.mode == .ask {
                hint("↩", model.questionIsNew || model.askedQuestion == nil ? "Ask" : "Open source")
                hint("↓↑", "Sources"); hint("⌘J", "Continue in chat"); hint("⌘C", "Copy answer"); hint("⇥", "Search")
            } else {
                hint("↩", "Open"); hint("Space", "Preview"); hint("⌘↩", "Show in Finder"); hint("⌘C", "Copy file"); hint("⇥", "Ask")
            }
            Spacer()
            Button { SettingsController.shared.show() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ResultRow: View {
    let result: SearchResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(result: result, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if let place = result.place {
                        Text(place).font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.15)))
                    }
                    if result.exactMatch {
                        Image(systemName: "textformat").font(.system(size: 10)).help("Has your exact words")
                    }
                }
                Text(folderLine).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                if let snippet = result.snippet, !snippet.isEmpty {
                    Text(snippet.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12)).lineLimit(2)
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.primary.opacity(0.75))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
    }

    private var folderLine: String {
        let folder = (result.path as NSString).deletingLastPathComponent
        return (folder as NSString).abbreviatingWithTildeInPath
    }
}

/// One passage an answer may cite: its number, where it's from, and its first words.
struct PassageRow: View {
    let passage: Passage
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(passage.number)").font(.system(size: 11, weight: .bold)).frame(width: 20, height: 20)
                .background(Circle().fill(selected ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.15)))
            ThumbnailView(result: passage.source, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(passage.label).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(passage.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11.5)).lineLimit(2)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
