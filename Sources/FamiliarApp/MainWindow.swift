import AppKit
import FamiliarCore
import SwiftUI

/// The main window: Chat (conversations with your files, saved) and Sources (what Familiar reads). The search panel
/// stays the quick way in; this is for longer sessions.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private(set) var window: NSWindow?
    let chats = ChatsModel()
    let navigation = MainNavigation()

    func show(page: MainPage? = nil) {
        if let page { navigation.page = page }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Familiar"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(app: AppState.shared, chats: chats, navigation: navigation))
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.minSize = NSSize(width: 760, height: 480)
            window.center()
            window.setFrameAutosaveName("FamiliarMain")
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        chats.reload()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { AppWindows.updateActivationPolicy() }
    }

    /// ⌘N (or New Chat in the menu-bar menu): a new chat, cursor in the box.
    func startNewChat() {
        show(page: .chat)
        chats.newChat()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusChatInput, object: nil) }
    }

    /// ⌘R, the menu-bar menu, or its own shortcut if one is chosen in Settings: starts recording a meeting, or stops the
    /// one being recorded.
    func toggleRecording() {
        let recorder = MeetingRecorder.shared
        show(page: .meetings)
        Task {
            if recorder.state == .recording { await recorder.stop() }
            else if !recorder.isActive { await recorder.start() }
        }
    }
}

extension Notification.Name {
    static let focusChatInput = Notification.Name("FamiliarFocusChatInput")
}

/// A Dock icon while any of the app's windows is open (so it can be found again), none otherwise: it's a menu-bar app.
@MainActor
enum AppWindows {
    static func updateActivationPolicy() {
        let open = [MainWindowController.shared.window, SettingsController.shared.window, SetupWindowController.shared.window,
                    OnboardingWindowController.shared.window]
            .contains { $0?.isVisible == true }
        NSApp.setActivationPolicy(open ? .regular : .accessory)
    }
}

enum MainPage: String, Hashable { case search, chat, meetings, sources }

@MainActor
final class MainNavigation: ObservableObject {
    @Published var page: MainPage? = .chat
}

// MARK: - Chat state

/// The conversations: the saved list, the open chat's turns, and the answer being written. A question goes through
/// `Asker` with the chat's earlier turns (follow-ups are planned, the last answer's passages carried), and both the
/// question and the checked answer are saved as they finish.
@MainActor
final class ChatsModel: ObservableObject {
    struct Pending {
        let question: String
        var standalone: String?
        var searches: [String] = []
        var passages: [Passage] = []
        var answer = ""
        var finding = true
    }

    @Published private(set) var chats: [ChatSummary] = []
    @Published private(set) var selected: Int64?
    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var pending: Pending?
    @Published private(set) var error: String?
    /// The chosen folder or file this chat searches in; nil: everything.
    @Published var scope: String? { didSet { if let selected, scope != oldValue { store?.setScope(chat: selected, scope: scope) } } }
    private let store: ChatStore? = try? ChatStore()
    private var task: Task<Void, Never>?

    var busy: Bool { pending != nil }

    func reload() {
        chats = store?.chats() ?? []
        if let selected { turns = store?.turns(chat: selected) ?? [] }
    }

    func select(_ id: Int64?) {
        guard id != selected else { return }
        stop()
        selected = id
        turns = id.flatMap { store?.turns(chat: $0) } ?? []
        scope = chats.first { $0.id == id }?.scope
        error = nil
    }

    func newChat() {
        stop()
        selected = nil
        turns = []
        error = nil
    }

    func delete(_ id: Int64) {
        if id == selected { newChat() }
        store?.delete(chat: id)
        reload()
    }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy, let store else { return }
        error = nil
        let history = Self.exchanges(turns)
        let chat = selected ?? store.create(title: Self.title(question), scope: scope)
        selected = chat
        store.append(chat: chat, role: .user, content: question)
        reload()
        pending = Pending(question: question)
        AppState.shared.chatStarted()
        AppLog.write("chat: a question (\(question.count) characters, \(history.count) earlier turns)")
        let scope = self.scope
        task = Task {
            do {
                let turn = try await AppState.shared.asker.ask(question, history: history, scope: scope)
                guard !Task.isCancelled else { return }
                pending?.standalone = turn.plan.standalone != question ? turn.plan.standalone : nil
                pending?.searches = turn.plan.searches
                pending?.passages = turn.passages
                pending?.finding = false
                for try await piece in turn.answer {
                    guard !Task.isCancelled else { return }
                    pending?.answer += piece
                }
                finish(chat: chat)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                pending = nil
            }
        }
    }

    /// Stops the answer being written; what's written so far is kept, so the conversation stays whole.
    func stop() {
        guard let pending, let selected else { task?.cancel(); return }
        task?.cancel()
        if !pending.answer.isEmpty {
            let checked = Asker.checked(pending.answer, passageCount: pending.passages.count)
            store?.append(chat: selected, role: .assistant, content: checked.text + " …", passages: pending.passages)
        }
        self.pending = nil
        reload()
    }

    private func finish(chat: Int64) {
        guard let pending else { return }
        let checked = Asker.checked(pending.answer, passageCount: pending.passages.count)
        store?.append(chat: chat, role: .assistant, content: checked.text, passages: pending.passages)
        self.pending = nil
        reload()
    }

    /// A question answered in the search panel, carried on here as a new chat.
    func continueFromPanel(question: String, answer: String, passages: [Passage]) {
        guard let store else { return }
        stop()
        let chat = store.create(title: Self.title(question), scope: nil)
        store.append(chat: chat, role: .user, content: question)
        store.append(chat: chat, role: .assistant, content: Asker.checked(answer, passageCount: passages.count).text, passages: passages)
        selected = chat
        scope = nil
        reload()
    }

    /// Question-and-answer pairs, for the next follow-up.
    static func exchanges(_ turns: [ChatTurn]) -> [Asker.Exchange] {
        var out: [Asker.Exchange] = []
        var question: String?
        for turn in turns {
            if turn.role == .user { question = turn.content }
            else if let q = question { out.append(Asker.Exchange(question: q, answer: turn.content, passages: turn.passages)); question = nil }
        }
        return out
    }

    static func title(_ question: String) -> String {
        let flat = question.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(57)) + "…" : flat
    }
}

// MARK: - Views

struct MainView: View {
    @ObservedObject var app: AppState
    @ObservedObject var chats: ChatsModel
    @ObservedObject var navigation: MainNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                Label("Search", systemImage: "magnifyingglass").tag(MainPage.search)
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(MainPage.chat)
                Label("Meetings", systemImage: "waveform").tag(MainPage.meetings)
                Label("Sources", systemImage: "folder").tag(MainPage.sources)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(app.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Button { SettingsController.shared.show() } label: { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch navigation.page ?? .chat {
            case .search: SearchPage(app: app)
            case .chat: ChatPage(app: app, chats: chats)
            case .meetings: MeetingsPage(app: app, recorder: MeetingRecorder.shared, model: MeetingsModel.shared)
            case .sources: SourcesPage(app: app)
            }
        }
    }
}

struct ChatPage: View {
    @ObservedObject var app: AppState
    @ObservedObject var chats: ChatsModel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            chatList.frame(width: 230)
            Divider()
            conversation.frame(maxWidth: .infinity)
        }
        .onAppear { inputFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusChatInput)) { _ in inputFocused = true }
    }

    // The saved chats, newest first.
    private var chatList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer()
                Button { chats.newChat(); inputFocused = true } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("New chat (⌘N)")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            if chats.chats.isEmpty {
                Text("Your chats will be listed here.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { chats.selected }, set: { chats.select($0) })) {
                    ForEach(chats.chats) { chat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title).lineLimit(2)
                            Text(chat.updated, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(Optional(chat.id))
                        .contextMenu { Button("Delete Chat", role: .destructive) { chats.delete(chat.id) } }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder private var conversation: some View {
        VStack(spacing: 0) {
            if app.chatState != .ready {
                needsModel
            } else if chats.turns.isEmpty && chats.pending == nil {
                welcome
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(chats.turns) { turn in TurnView(turn: turn) }
                            if let pending = chats.pending { PendingView(pending: pending) }
                            if let error = chats.error {
                                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.horizontal, 28).padding(.vertical, 22)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: chats.pending?.answer) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: chats.turns.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
    }

    private var needsModel: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Chat needs the answer model").font(.title3.weight(.semibold))
            switch app.chatState {
            case .downloading(let done, let total):
                ProgressView(value: Double(done), total: Double(total)).frame(maxWidth: 320)
            case .verifying:
                Text("Checking the download…").foregroundStyle(.secondary)
            case .failed(let why):
                Text(why).foregroundStyle(.orange)
                Button("Try Again") { app.downloadChat() }
            default:
                Text("A 2.7 GB model that writes answers from your files, on this Mac. Nothing leaves it.").foregroundStyle(.secondary)
                Button("Download (2.7 GB)") { app.downloadChat() }.controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Ask about your files").font(.title2.weight(.semibold))
            Text("Answers come only from your files, with links to where each part came from. Ask follow-ups: “and when does it renew?”, “what about the second one?”")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            VStack(spacing: 6) {
                ForEach(["When does my insurance renew?", "What did we decide in the last meeting?", "Summarise my performance review"], id: \.self) { example in
                    Button { chats.send(example) } label: {
                        Text(example).frame(maxWidth: 360, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                Button("All files") { chats.scope = nil }
                if !app.folders.isEmpty { Divider() }
                ForEach(app.folders, id: \.self) { url in
                    Button(url.lastPathComponent) { chats.scope = url.path }
                }
            } label: {
                Label(chats.scope.map { ($0 as NSString).lastPathComponent } ?? "All files", systemImage: "scope")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which files this chat answers from")
            TextField(chats.turns.isEmpty ? "Ask a question about your files" : "Ask a follow-up", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            if chats.busy {
                Button { chats.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 24)) }
                    .buttonStyle(.plain).help("Stop (Esc)").keyboardShortcut(.escape, modifiers: [])
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                    .buttonStyle(.plain).foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || app.chatState != .ready)
                    .help("Send (↩)")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func send() {
        guard !chats.busy, app.chatState == .ready else { return }
        let text = draft
        draft = ""
        chats.send(text)
    }
}

/// One saved turn: your question on the right, the answer on the left with its sources.
struct TurnView: View {
    let turn: ChatTurn

    var body: some View {
        if turn.role == .user {
            QuestionBubble(text: turn.content)
        } else {
            AnswerView(text: turn.content, passages: turn.passages)
        }
    }
}

struct QuestionBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text).font(.system(size: 15)).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.16)))
        }
    }
}

struct AnswerView: View {
    let text: String
    let passages: [Passage]
    @State private var showAll = false

    var body: some View {
        let checked = Asker.checked(text, passageCount: passages.count)
        let cited = Asker.citations(in: checked.text)
        VStack(alignment: .leading, spacing: 8) {
            Text(PanelView.cited(checked.text, count: passages.count))
                .font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "sfcite", let n = Int(url.host ?? ""), let p = passages.first(where: { $0.number == n }) {
                        ResultActions.open(p.source, query: "")
                    }
                    return .handled
                })
            if checked.unsupported {
                Label("Not backed by your files: no passage was cited", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            let shown = showAll ? passages : passages.filter { cited.contains($0.number) }
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(shown) { passage in SourceChip(passage: passage) }
                }
            }
            // Only for an answer that drew on its passages: a "Hello!" doesn't need "Show all 6 passages read".
            if (passages.count > shown.count && !cited.isEmpty) || showAll {
                Button(showAll ? "Show cited sources only" : "Show all \(passages.count) passages read") { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

/// A source under an answer: its number and where it's from. Click opens the file there; ⌘-click shows it in Finder.
struct SourceChip: View {
    let passage: Passage
    @State private var hovering = false

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) { ResultActions.reveal(passage.source) } else { ResultActions.open(passage.source, query: "") }
        } label: {
            HStack(spacing: 8) {
                Text("\(passage.number)").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 14)
                Text(passage.label).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                if hovering {
                    Text(passage.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(passage.text)
    }

    private var icon: String {
        switch passage.source.fileKind {
        case .audio: return "waveform"
        case .video: return "film"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .office: return "tablecells"
        case .text, .document: return "doc.text"
        }
    }
}

/// The question being answered: what was searched, then the answer as it's written.
struct PendingView: View {
    let pending: ChatsModel.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            QuestionBubble(text: pending.question)
            VStack(alignment: .leading, spacing: 8) {
                if let standalone = pending.standalone {
                    Label("Searching for: \(standalone)", systemImage: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                }
                if pending.finding {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking through your files…").foregroundStyle(.secondary) }
                } else if pending.answer.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading \(pending.passages.count) passage\(pending.passages.count == 1 ? "" : "s")…").foregroundStyle(.secondary)
                    }
                } else {
                    Text(PanelView.cited(pending.answer, count: pending.passages.count))
                        .font(.system(size: 15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// What Familiar reads, with what's in the index.
struct SourcesPage: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sources").font(.largeTitle.weight(.semibold))
                Text("The folders and files Familiar reads. Search and Chat answer only from these.")
                    .foregroundStyle(.secondary)
                SourcesList(app: app, window: { MainWindowController.shared.window })
                HStack(spacing: 18) {
                    stat("Files", app.counts.files)
                    stat("Searchable pieces", app.counts.segments)
                    if app.counts.failed > 0 { stat("Couldn't read", app.counts.failed) }
                    Spacer()
                    Button("Check for New Files") { app.indexNow() }.disabled(app.isIndexing)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                Text(app.statusLine).font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted()).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
