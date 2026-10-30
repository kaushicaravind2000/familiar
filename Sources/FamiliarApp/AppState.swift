import AppKit
import Combine
import FamiliarCore
import ServiceManagement

/// The app's state: the model download, the chosen folders, and indexing. One instance, on the main actor.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum ModelState: Equatable {
        case missing
        case downloading(done: Int64, total: Int64)
        case verifying
        case ready
        case failed(String)
    }

    @Published private(set) var modelState: ModelState = EmbeddingModelFiles.isInstalled ? .ready : .missing
    /// The answer model for Ask (Qwen3.5-4B, 2.7 GB): an optional download.
    @Published private(set) var chatState: ModelState = ChatModelFiles.isInstalled ? .ready : .missing
    enum SpeechState: Equatable { case off, unsupported, preparing(Double), ready, failed(String) }
    /// Transcribing recordings and videos while they're indexed (~1.2 GB, macOS 14+).
    @Published private(set) var speechState: SpeechState = .off
    @Published var transcribeOn: Bool = Transcriber.enabled {
        didSet {
            guard transcribeOn != oldValue else { return }
            Transcriber.enabled = transcribeOn
            applySpeech()
        }
    }
    /// What to search: folders (everything under them) and single files, as chosen in Settings.
    @Published private(set) var folders: [URL] = []
    /// What the index holds for each chosen folder or file (by path), for its row in Settings.
    @Published private(set) var sourceCounts: [String: IndexCounts] = [:]
    /// "Index anyway": indexing runs although power holds it back (Low Power Mode, or battery set to pause), at full
    /// speed on the charger and slowly on battery. A very hot Mac still pauses. Set by the button, and by adding a
    /// folder or file (you asked for it); cleared when the pass is done.
    @Published private(set) var indexAnyway = false
    @Published private(set) var progress = IndexProgress()
    @Published private(set) var counts = IndexCounts()
    /// Set after the index was found damaged and replaced; cleared once every folder has been read again.
    @Published private(set) var indexNotice: String?
    private var recovering = false
    /// Folders macOS refused to open in the last full scan (shown in Settings with a way to allow them).
    @Published private(set) var deniedFolders: [String] = []
    /// Paused from the menu or Settings.
    @Published private(set) var paused = false
    /// What power and heat allow right now (`PowerMonitor`); indexing slows or pauses on its own, and resumes.
    @Published private(set) var pace = Pace.full
    @Published var batteryBehavior: BatteryBehavior {
        didSet {
            SettingsStore.defaults.set(batteryBehavior.rawValue, forKey: "batteryBehavior")
            applyPace()
        }
    }
    private var power: PowerMonitor?
    /// On small Macs (Low profile), chatting pauses indexing and frees the indexing model, so the answer model and
    /// search fit in 8 GB; searches meanwhile use the small text-only model. Released ~75 s after the last question
    /// (just after the answer model unloads).
    @Published private(set) var chatHold = false
    private var chatHoldRelease: DispatchWorkItem?
    /// csv, tsv and log files (`Privacy.readsDataFiles`). Changing it checks every folder again: files now read are
    /// added, files no longer read leave the index.
    @Published var readDataFiles: Bool = SettingsStore.defaults.bool(forKey: "readDataFiles") {
        didSet {
            SettingsStore.defaults.set(readDataFiles, forKey: "readDataFiles")
            requestRescan()
        }
    }
    /// Memory use: nil is Automatic (Low on Macs with 12 GB or less, `MemoryProfile`).
    @Published var memoryChoice: MemoryProfile? {
        didSet {
            MemoryProfile.chosen = memoryChoice
            applyMemoryProfile()
        }
    }
    @Published var setupDone: Bool {
        didSet { SettingsStore.defaults.set(setupDone, forKey: "setupDone") }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    /// A text-only model kept loaded just for searches (~330 MB), so a search never waits behind indexing or for
    /// the model to start. Off: searches share the indexing server.
    @Published var searchServerOn: Bool {
        didSet {
            SettingsStore.defaults.set(searchServerOn, forKey: "searchServer")
            applySearchServer()
        }
    }

    let db: Catalog
    let searcher: Lookup
    let asker: Asker
    private var indexer: Ingestor!
    private var indexTask: Task<Void, Never>?
    private var downloader: ModelDownloader?
    private var chatDownloader: ModelDownloader?
    private var rescanPending = false
    /// The running pass reads every folder (not just changed paths).
    private var runningFull = false
    /// A full pass waits for power: it starts again when indexing may run.
    private var fullDeferred = false
    private var pendingChanges = Set<String>()
    private var watcher: FileEventStream?
    private var periodic: Timer?
    private var downloadStarted = Date()

    private init() {
        setupDone = SettingsStore.defaults.bool(forKey: "setupDone")
        // Never set: on by default, except on the low-memory profile, where it would hold ~0.3 GB all the time.
        searchServerOn = SettingsStore.defaults.object(forKey: "searchServer") as? Bool
            ?? MemoryProfile.current.searchServerByDefault
        memoryChoice = MemoryProfile.chosen
        batteryBehavior = BatteryBehavior(rawValue: SettingsStore.defaults.string(forKey: "batteryBehavior") ?? "") ?? .slow
        do {
            db = try Catalog()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Familiar can't open its index"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)   // in front, or it waits unseen behind other windows
            alert.runModal()
            exit(1)
        }
        searcher = Lookup(db: db)
        asker = Asker(db: db, searcher: searcher)
        db.onDamage = { DispatchQueue.main.async { AppState.shared.recoverIndex(reason: "SQLite reported it damaged") } }
        if db.recoveredAtOpen {
            indexNotice = "The index was damaged, so Familiar started a new one and is reading your folders again."
            AppLog.write("index damaged at open: replaced (the damaged copy is index.damaged.sqlite)")
        }
        // Spelled as the index spells paths (/tmp, not /private/tmp), or a folder's counts and state wouldn't match.
        folders = (SettingsStore.defaults.stringArray(forKey: "folders") ?? []).map { URL(fileURLWithPath: FolderScanner.normalized($0)) }
        indexer = Ingestor(db: db) { progress in
            DispatchQueue.main.async { AppState.shared.update(progress) }
        }
    }

    func start() {
        refreshCounts()
        applySearchServer()
        Task.detached(priority: .background) {
            Transcriber.verifyOnce()
            await MainActor.run { AppState.shared.applySpeech(rescan: false) }
        }
        power = PowerMonitor { AppState.shared.applyPace() }
        applyPace()
        // A full check of the index file in the background; damage found means starting a fresh one.
        Task.detached(priority: .background) { [db] in
            if !db.checkIntegrity() {
                await MainActor.run { AppState.shared.recoverIndex(reason: "the integrity check failed") }
            }
        }
        if EmbeddingModelFiles.isInstalled {
            modelState = .ready
            if setupDone { indexNow() }
        } else if setupDone {
            download()
        }
        watcher = FileEventStream { [weak self] paths, full in
            if full { self?.requestRescan() } else { self?.filesChanged(paths) }
        }
        watcher?.watch(watchedFolders)
        // A slow sweep as a backstop for changes the watcher misses (a disk plugged back in, a sleep). Meeting audio
        // past what Settings → Storage keeps goes then too, and at launch.
        deleteOldMeetingAudio()
        periodic = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            Task { @MainActor in
                AppState.shared.requestRescan()
                AppState.shared.deleteOldMeetingAudio()
            }
        }
    }

    func shutdown() {
        MeetingRecorder.shared.abandon()
        indexTask?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await EmbeddingService.shared.stop()
            await EmbeddingService.search.stop()
            await ChatService.shared.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - Model

    func download() {
        guard downloader == nil, !EmbeddingModelFiles.isInstalled else {
            if EmbeddingModelFiles.isInstalled { modelState = .ready }
            return
        }
        let downloader = ModelDownloader()
        self.downloader = downloader
        downloadStarted = Date()
        modelState = .downloading(done: 0, total: EmbeddingModelFiles.totalBytes)
        var lastUpdate = Date.distantPast
        downloader.onProgress = { done, total in
            DispatchQueue.main.async {
                guard Date().timeIntervalSince(lastUpdate) > 0.2 || done == total else { return }
                lastUpdate = Date()
                AppState.shared.modelState = done >= total ? .verifying : .downloading(done: done, total: total)
            }
        }
        Task {
            do {
                try await downloader.run()
                modelState = .ready
                applySearchServer()
                if setupDone { indexNow() }
            } catch {
                modelState = .failed(error.localizedDescription)
            }
            self.downloader = nil
        }
    }

    /// Downloads the answer model for Ask, the same way as EmbeddingGemma: resumable, checked against its SHA-256.
    func downloadChat() {
        guard chatDownloader == nil, !ChatModelFiles.isInstalled else {
            if ChatModelFiles.isInstalled { chatState = .ready }
            return
        }
        let downloader = ModelDownloader(files: ChatModelFiles.all)
        chatDownloader = downloader
        chatState = .downloading(done: 0, total: ChatModelFiles.model.bytes)
        AppLog.write("downloading the answer model")
        var lastUpdate = Date.distantPast
        downloader.onProgress = { done, total in
            DispatchQueue.main.async {
                guard Date().timeIntervalSince(lastUpdate) > 0.2 || done == total else { return }
                lastUpdate = Date()
                AppState.shared.chatState = done >= total ? .verifying : .downloading(done: done, total: total)
            }
        }
        Task {
            do {
                try await downloader.run()
                chatState = .ready
                AppLog.write("answer model ready")
            } catch {
                chatState = .failed(error.localizedDescription)
            }
            chatDownloader = nil
        }
    }

    /// Transcribing on: the speech model is downloaded and compiled once, then recordings and videos are read again
    /// so they get transcripts. Off: new ones are read without (the transcripts already made stay).
    func applySpeech(rescan: Bool = true) {
        guard Transcriber.isSupported else { speechState = .unsupported; return }
        guard transcribeOn else { speechState = .off; return }
        if Transcriber.isPrepared {
            speechState = .ready
            if rescan { requestRescan() }
            return
        }
        Task {
            do {
                try await prepareSpeechModel()
                if transcribeOn { requestRescan() }
            } catch {}
        }
    }

    /// The one preparation of the speech model under way: settings, setup and a meeting that starts while it runs all
    /// wait for the same one (two at once wrote the same download files and failed).
    private var speechPreparation: Task<Void, Error>?

    /// The speech model for meetings (they need it whether or not recordings in your folders are transcribed).
    func prepareSpeechModel() async throws {
        guard !Transcriber.isPrepared else { return }
        guard Transcriber.isSupported else { throw Transcriber.Failure.unsupported }
        if let speechPreparation { return try await speechPreparation.value }
        speechState = .preparing(0)
        AppLog.write("preparing the speech model")
        let task = Task {
            try await Transcriber.prepare { value in
                DispatchQueue.main.async {
                    if case .preparing = AppState.shared.speechState { AppState.shared.speechState = .preparing(value) }
                }
            }
        }
        speechPreparation = task
        defer { speechPreparation = nil }
        do {
            try await task.value
            speechState = transcribeOn ? .ready : .off
            AppLog.write("speech model ready")
        } catch {
            speechState = .failed(error.localizedDescription)
            AppLog.write("speech model failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// A meeting was saved: the Meetings folder becomes a source the first time (so meetings can be searched and
    /// asked about), and the new file is read right away.
    func meetingSaved(_ url: URL) {
        let folder = URL(fileURLWithPath: FolderScanner.normalized(Meetings.folder.path))
        if folders.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) {
            index(changes: [url.path])
        } else {
            add([folder])
        }
    }

    var downloadETA: TimeInterval? {
        guard case .downloading(let done, let total) = modelState, done > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(downloadStarted)
        guard elapsed > 3 else { return nil }
        return Double(total - done) / (Double(done) / elapsed)
    }

    /// Applies the memory profile now: search reloads its vectors in the new format on the next search, and the
    /// indexing server restarts with the new size when it's next needed.
    private func applyMemoryProfile() {
        let profile = MemoryProfile.current
        searcher.compact = profile.compactVectors
        AppLog.write("memory use: \(profile.rawValue)\(memoryChoice == nil ? " (automatic, \(MemoryProfile.physicalGB) GB)" : "")")
        Task.detached { await EmbeddingService.shared.reconfigure(.indexing(for: profile)) }
    }

    /// Points searches at the right server, and starts or stops the search server to match the setting.
    private func applySearchServer() {
        let on = searchServerOn
        searcher.embedder = on ? .search : .shared
        Task.detached {
            if on {
                if EmbeddingModelFiles.isInstalled { try? await EmbeddingService.search.ensureRunning() }
            } else {
                await EmbeddingService.search.stop()
            }
        }
    }

    // MARK: - Folders

    /// Adds folders and files to search. Something inside an already chosen folder adds nothing; a folder that
    /// contains chosen folders or files replaces them. What's added is read right away, even if power holds indexing
    /// back: you asked for it.
    func add(_ urls: [URL]) {
        var added: [URL] = []
        for url in urls.map({ URL(fileURLWithPath: FolderScanner.normalized($0.path)) }) where !folders.contains(url) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if folders.contains(where: { url.path.hasPrefix($0.path + "/") }) { continue }
            folders.removeAll { $0.path.hasPrefix(url.path + "/") }
            folders.append(url)
            added.append(url)
        }
        guard !added.isEmpty else { return }
        saveFolders()
        AppLog.write("added \(added.count) to search: \(added.map(\.lastPathComponent).joined(separator: ", "))")
        guard setupDone && modelState == .ready else { return }
        indexAnyway = true
        applyPace()
        index(changes: added.map(\.path))   // a folder is read through, a file on its own
    }

    /// Stops searching a folder or file: its part of the index is removed. The files themselves aren't touched.
    func remove(_ url: URL) {
        folders.removeAll { $0 == url }
        saveFolders()
        let path = url.path
        Task.detached { [db] in
            try? db.removeFiles(paths: [path])   // a chosen file
            try? db.removeFiles(under: path)     // everything under a chosen folder
            await MainActor.run { AppState.shared.refreshCounts() }
        }
    }

    /// Reads a chosen folder or file again: new and changed files in it are picked up.
    func checkAgain(_ url: URL) {
        index(changes: [url.path])
    }

    /// Indexes now although power holds it back (see `indexAnyway`).
    func startIndexingAnyway() {
        indexAnyway = true
        applyPace()
        if indexTask == nil { indexNow() }
    }

    nonisolated static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func saveFolders() {
        SettingsStore.defaults.set(folders.map(\.path), forKey: "folders")
        watcher?.watch(watchedFolders)
    }

    /// FSEvents watches folders: a chosen file is watched through the folder it's in (other changes there are
    /// ignored in `filesChanged`).
    private var watchedFolders: [URL] {
        var seen = Set<String>()
        return folders.map { Self.isFolder($0.path) ? $0 : $0.deletingLastPathComponent() }.filter { seen.insert($0.path).inserted }
    }

    /// How one chosen folder or file is doing, for its row in Settings.
    enum SourceState: Equatable {
        case missing(String)
        case refused
        case checking
        case indexing(done: Int, total: Int)
        case waiting(String)
        case searchable
        case empty
    }

    func state(of url: URL) -> SourceState {
        let path = url.path
        if !FileManager.default.fileExists(atPath: path) {
            return .missing(path.hasPrefix("/Volumes/") ? "Disk not connected: its files stay in the index"
                                                         : "Not found: it was moved, renamed or deleted")
        }
        if deniedFolders.contains(path) { return .refused }
        if let total = progress.rootTotals[path], total > (progress.rootDone[path] ?? 0), isIndexing {
            let done = progress.rootDone[path] ?? 0
            if progress.phase == .paused { return .waiting(paused ? "you paused indexing" : (pace.reason ?? "indexing is paused")) }
            return .indexing(done: done, total: total)
        }
        if progress.phase == .scanning && isIndexing { return .checking }
        return (sourceCounts[path]?.files ?? 0) > 0 ? .searchable : .empty
    }

    // MARK: - Indexing

    func finishSetup() {
        setupDone = true
        if modelState == .ready { indexNow() } else { download() }
    }

    /// The first-launch "Get Started": every model this Mac can run starts downloading at once, while the person
    /// chooses folders and permissions. Search and speech go first (search is what reading the folders needs; speech
    /// is what "try it" needs); the answer model, the biggest, follows once search has finished, so it doesn't slow them.
    func setUpEverything() {
        download()
        if Transcriber.isSupported { transcribeOn = true }
        Task {
            while modelState != .ready {
                if case .failed = modelState { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            downloadChat()
        }
    }

    /// A full pass over every folder.
    func indexNow() { index(changes: nil) }

    // MARK: Storage

    /// Meeting audio older than Settings → Storage keeps (the transcripts stay).
    func deleteOldMeetingAudio() {
        let deleted = Storage.deleteOldMeetingAudio(keeping: MeetingRecorder.shared.recordingFolder)
        if deleted > 0 { AppLog.write("storage: deleted the audio of \(deleted) meeting\(deleted == 1 ? "" : "s") older than \(Storage.meetingAudioDays) days") }
    }

    /// Ask's model (2.6 GB) off the disk; Chat offers to download it again.
    func removeChatModel() async {
        await ChatService.shared.stop()
        try? FileManager.default.removeItem(at: ChatModelFiles.model.installed)
        chatState = .missing
        AppLog.write("storage: removed the answer model")
    }

    /// The speech models (1.1 GB) off the disk. Push to talk and transcribing recordings go off, so nothing downloads
    /// them again by itself; turning either back on, or recording a meeting, does.
    func removeSpeechModels() async throws {
        guard !MeetingRecorder.shared.isActive else { throw StorageError.meetingRecording }
        Dictation.shared.enabled = false
        await Dictation.shared.unload()
        transcribeOn = false
        try Storage.removeSpeechModels()
        speechState = .off
        AppLog.write("storage: removed the speech models")
    }

    enum StorageError: LocalizedError {
        case meetingRecording
        var errorDescription: String? { "A meeting is being recorded. Stop it first." }
    }

    /// The folder watcher saw these paths change: read just them.
    func filesChanged(_ paths: [String]) {
        guard setupDone else { return }
        // Only what's under a chosen folder or is a chosen file (a file is watched through its whole folder).
        let roots = folders.map(\.path)
        let relevant = paths.filter { raw in
            let path = FolderScanner.normalized(raw)
            return roots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
        }
        guard !relevant.isEmpty else { return }
        index(changes: relevant)
    }

    /// Starts a pass (full when `changes` is nil). While one runs, requests wait and merge: any full request makes
    /// the next pass full; otherwise the next pass reads all the changes that came in meanwhile.
    private func index(changes: [String]?) {
        guard modelState == .ready, !folders.isEmpty else { return }
        if indexTask != nil {
            if let changes {
                pendingChanges.formUnion(changes)
                // A pass held back by power or heat would keep new files waiting for hours: it makes way, and comes
                // back after them (what it had read stays in the index).
                if !progress.urgent && pace.speed != .full && !paused {
                    AppLog.write("new files go first: the \(pace.speed == .paused ? "paused" : "slow") pass makes way")
                    rescanPending = true
                    indexTask?.cancel()
                }
            } else {
                rescanPending = true
            }
            return
        }
        runningFull = changes == nil
        if changes == nil { fullDeferred = false; AppLog.write("checking every folder") }
        let roots = folders
        if let changes { AppLog.write("checking \(changes.count) changed path\(changes.count == 1 ? "" : "s") instead of every folder") }
        // The pace goes in before the pass starts, so a pass started while paused doesn't read a file first.
        let userPaused = paused, powerPaused = pace.speed == .paused, slow = pace.speed == .slow
        indexTask = Task.detached(priority: .utility) { [indexer] in
            await indexer!.setPace(userPaused: userPaused, powerPaused: powerPaused, slow: slow)
            await indexer!.run(roots: roots, changes: changes)
            await MainActor.run { AppState.shared.indexFinished() }
        }
    }

    private func indexFinished() {
        indexTask = nil
        refreshCounts()
        if indexAnyway && progress.phase == .done && pendingChanges.isEmpty && !rescanPending {
            indexAnyway = false
            applyPace()
        }
        if progress.phase == .done && !recovering { indexNotice = nil }
        let heldBack = pace.speed != .full || paused
        if !pendingChanges.isEmpty && (heldBack || !rescanPending) {
            // New files first; a full pass that's due comes after them.
            let changes = Array(pendingChanges)
            pendingChanges.removeAll()
            index(changes: changes)
        } else if rescanPending {
            rescanPending = false
            pendingChanges.removeAll()
            if pace.speed == .paused && !paused {
                fullDeferred = true   // starts again when power allows (applyPace)
            } else if pace.speed == .slow {
                // Slow: give it a moment, so a burst of saves doesn't restart the big pass again and again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    let model = AppState.shared
                    if model.indexTask == nil { model.indexNow() } else { model.rescanPending = true }
                }
            } else {
                indexNow()
            }
        }
    }

    func requestRescan() {
        guard setupDone else { return }
        indexNow()
    }

    func togglePause() {
        paused.toggle()
        applyPace()
    }

    /// A question is being asked (Chat or the panel). On the Low profile: indexing pauses and its model is freed, and
    /// searches switch to the text-only model, until a while after the last question.
    func chatStarted() {
        guard MemoryProfile.current == .low else { return }
        chatHoldRelease?.cancel()
        if !chatHold {
            chatHold = true
            AppLog.write("chat on a small Mac: indexing waits, its model is freed")
            searcher.embedder = .search
            applyPace()
            Task.detached { await EmbeddingService.shared.stopWhenIdle() }
        }
        let release = DispatchWorkItem { AppState.shared.chatEnded() }
        chatHoldRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 75, execute: release)
    }

    private func chatEnded() {
        guard chatHold else { return }
        chatHold = false
        AppLog.write("chat idle: indexing resumes")
        applySearchServer()
        applyPace()
    }

    /// Tells the indexer how fast it may go: paused by hand, or by power and heat; slow on battery or when hot.
    func applyPace() {
        var pace = power?.pace(onBattery: batteryBehavior) ?? .full
        if chatHold { pace = Pace(speed: .paused, reason: "you're chatting") }
        // Index anyway: power holds it back, but you asked. A very hot Mac still pauses.
        if indexAnyway, pace.speed == .paused, power?.thermal != .critical {
            pace = power?.onBattery == true ? Pace(speed: .slow, reason: "on battery (indexing anyway)") : .full
        }
        if fullDeferred && pace.speed != .paused && !paused && indexTask == nil {
            fullDeferred = false
            DispatchQueue.main.async { AppState.shared.indexNow() }
        }
        if pace != self.pace {
            let speed: String
            switch pace.speed { case .full: speed = "full"; case .slow: speed = "slow"; case .paused: speed = "paused" }
            AppLog.write("indexing pace: \(speed)\(pace.reason.map { " (\($0))" } ?? "")")
        }
        self.pace = pace
        let userPaused = paused, powerPaused = pace.speed == .paused, slow = pace.speed == .slow
        Task { [indexer] in await indexer!.setPace(userPaused: userPaused, powerPaused: powerPaused, slow: slow) }
    }

    /// Replaces a damaged index with a fresh one and reads every folder again. The files themselves are untouched.
    func recoverIndex(reason: String) {
        guard !recovering else { return }
        recovering = true
        AppLog.write("index damaged (\(reason)): starting a new one; the damaged copy is index.damaged.sqlite")
        indexNotice = "The index was damaged, so Familiar started a new one and is reading your folders again."
        indexTask?.cancel()
        Task {
            _ = await indexTask?.value
            do { try db.recover() } catch { AppLog.write("couldn't replace the index: \(error.localizedDescription)") }
            searcher.invalidate()
            recovering = false
            refreshCounts()
            indexNow()
        }
    }

    /// Forgets everything and reads all folders again.
    func rebuild() {
        indexTask?.cancel()
        Task {
            _ = await indexTask?.value
            try? db.removeAll()
            refreshCounts()
            indexNow()
        }
    }

    private func update(_ progress: IndexProgress) {
        self.progress = progress
        if progress.phase == .indexing || progress.phase == .done, let denied = progress.denied, deniedFolders != denied {
            deniedFolders = denied
            if !denied.isEmpty { AppLog.write("macOS refused access to: \(denied.joined(separator: ", "))") }
        }
        if progress.done % 25 == 0 || progress.phase != .indexing { refreshCounts() }
    }

    func refreshCounts() {
        let paths = folders.map(\.path)
        Task.detached { [db] in
            let counts = (try? db.counts()) ?? IndexCounts()
            var perSource: [String: IndexCounts] = [:]
            for path in paths { perSource[path] = (try? db.counts(under: path)) ?? IndexCounts() }
            await MainActor.run {
                AppState.shared.counts = counts
                AppState.shared.sourceCounts = perSource
            }
        }
    }

    var isIndexing: Bool { indexTask != nil && (progress.phase == .indexing || progress.phase == .scanning || progress.phase == .paused) }

    /// One line for the menu and settings: what the indexer is doing.
    var statusLine: String {
        switch modelState {
        case .missing: return "The model isn't downloaded yet"
        case .downloading(let done, let total):
            return "Downloading the model: \(Int(Double(done) / Double(max(total, 1)) * 100))%"
        case .verifying: return "Checking the download…"
        case .failed(let why): return "Download failed: \(why)"
        case .ready: break
        }
        if folders.isEmpty { return "Choose folders to search" }
        switch progress.phase {
        case .scanning: return "Looking for new and changed files…"
        case .indexing:
            let slow = pace.speed == .slow ? " slowly (\(pace.reason ?? ""))" : ""
            return "Reading\(slow) \(progress.done.formatted()) of \(progress.total.formatted()) files"
        case .paused:
            let why = !paused && pace.speed == .paused ? " while \(pace.reason ?? "")" : ""
            return "Paused\(why) at \(progress.done.formatted()) of \(progress.total.formatted())"
        case .failed: return "Indexing stopped: \(progress.message ?? "")"
        case .idle, .done:
            let refused = deniedFolders.isEmpty ? "" : " · \(deniedFolders.count) folder\(deniedFolders.count == 1 ? "" : "s") not allowed"
            return "\(counts.files.formatted()) files searchable\(refused)"
        }
    }

    var indexETA: TimeInterval? {
        // At the slow pace the rate so far says little about what's left.
        guard progress.phase == .indexing, pace.speed == .full, progress.done >= 5, let started = progress.startedAt
        else { return nil }
        let rate = Double(progress.done) / Date().timeIntervalSince(started)
        return rate > 0 ? Double(progress.total - progress.done) / rate : nil
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Familiar: launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

extension TimeInterval {
    /// "about 3 min", "about 2 h".
    var roughly: String {
        if self < 60 { return "less than a minute" }
        if self < 3600 { return "about \(Int((self / 60).rounded())) min" }
        return String(format: "about %.1f h", self / 3600)
    }
}

/// A line in ~/Library/Application Support/Familiar/Logs/app.log.
enum AppLog {
    static func write(_ message: String) {
        LogFile.append("\(ISO8601DateFormatter().string(from: Date())) \(message)\n", to: "app.log")
    }
}
