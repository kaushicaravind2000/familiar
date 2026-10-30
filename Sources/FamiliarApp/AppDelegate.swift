import AppKit
import Carbon
import FamiliarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sent by a second copy that was opened: the running one shows its window.
    static let showNotification = Notification.Name("io.github.kaushicaravind2000.Familiar.show")
    private var statusMenu: MenuBarItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Quit requests (Dock, menu bar, other apps, logging out) are handled here and quit directly. AppKit's own
        // handler first checks the window chain and once refused ("Failed responder chain validation for terminate:"),
        // leaving an app that wouldn't quit. What the windows were doing is logged, to find that cause.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    @objc func handleQuit(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let validated = NSApp.target(forAction: #selector(NSApplication.terminate(_:))) != nil
        let key = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"
        let modal = NSApp.modalWindow.map { String(describing: type(of: $0)) } ?? "none"
        AppLog.write("quit requested (key window: \(key), modal: \(modal), terminate target found: \(validated))")
        quit()
    }

    @objc func quit() {
        if NSApp.modalWindow != nil { NSApp.abortModal() }   // a dialog left open must not keep the app from quitting
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Familiar at a time: opening it again (another copy, or the DMG's) hands over to the running one,
        // which shows its window, and this one quits.
        let me = ProcessInfo.processInfo.processIdentifier
        func other() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first { $0.processIdentifier != me && !$0.isTerminated }
        }
        if let running = other() {
            // Ask it to show its window with a message, not by opening it through macOS: if it is on its way out (just
            // told to quit), opening it would start it again.
            DistributedNotificationCenter.default().postNotificationName(Self.showNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            let deadline = Date().addingTimeInterval(3)
            while !running.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            // Still there: it's the one copy, and it got the message. Gone: it was quitting, so this one carries on.
            if !running.isTerminated {
                NSApp.terminate(nil)
                return
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false) }
        }
        installMainMenu()
        let model = AppState.shared
        statusMenu = MenuBarItem(model: model)
        // A test copy (FAMILIAR_NO_HOTKEY) leaves the shortcuts to the real app.
        if ProcessInfo.processInfo.environment["FAMILIAR_NO_HOTKEY"] == nil {
            GlobalShortcut.register([
                .search: {
                    Dictation.shared.cancelHeldKey()   // right ⌥ held for ⌥Space isn't a dictation
                    QuickPanelController.shared.toggle()
                },
                .record: { MainWindowController.shared.toggleRecording() },
            ])
        }
        model.start()
        if ProcessInfo.processInfo.environment["FAMILIAR_NO_HOTKEY"] == nil {
            Dictation.shared.install()
            if model.setupDone { Dictation.shared.checkAccessAtLaunch() }
        }
        if !model.setupDone {
            OnboardingWindowController.shared.show()   // first launch: a few short steps
        } else if !EmbeddingModelFiles.isInstalled {
            SetupWindowController.shared.show()
        } else if !launchedAtLogin(notification) {
            // Opened by hand: show something, or it looks like it didn't open (it lives in the menu bar). The
            // first pass shows its progress; after that, the main window (the panel stays on its shortcut).
            if ((try? model.db.counts().files) ?? 0) == 0 {
                SettingsController.shared.show()
            } else if UserDefaults.standard.string(forKey: "debugQuery") == nil && UserDefaults.standard.string(forKey: "debugAsk") == nil {
                MainWindowController.shared.show()
            }
        }
        // For testing: `-debugIndexAnyway YES` presses "Index Anyway" after a few seconds.
        if UserDefaults.standard.bool(forKey: "debugIndexAnyway") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { AppState.shared.startIndexingAnyway() }
        }
        // For testing: `-debugSettings YES` opens Settings.
        if UserDefaults.standard.bool(forKey: "debugSettings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SettingsController.shared.show() }
        }
        // For testing: `-debugAdd <path>` adds a folder or file, as "Add…" or a drop does.
        if let path = UserDefaults.standard.string(forKey: "debugAdd") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppState.shared.add([URL(fileURLWithPath: path)]) }
        }
        // For testing: `-debugChooseFolders YES` opens Settings' folder chooser, as "Add…" does.
        if UserDefaults.standard.bool(forKey: "debugChooseFolders") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SettingsController.shared.debugChooseFolders() }
        }
        // For testing: `open Familiar.app --args -debugQuery "words"` opens the panel with that search.
        if let query = UserDefaults.standard.string(forKey: "debugQuery") {
            // "a|ab|abc" types it step by step, as a person would.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { QuickPanelController.shared.show() }
            for (step, text) in query.split(separator: "|").enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6 + Double(step) * 0.25) {
                    QuickPanelController.shared.model.query = String(text)
                }
            }
        }
        // For testing: `-debugMeeting "me.m4a|others.m4a"` records a meeting from those files instead of the microphone
        // and the Mac's sound (`-debugMeetingSpeed 4`: four times real time), and stops when they end.
        if let files = UserDefaults.standard.string(forKey: "debugMeeting") {
            MeetingRecorder.allowsDevices = false
            let paths = files.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            let speed = max(1, UserDefaults.standard.double(forKey: "debugMeetingSpeed"))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                MainWindowController.shared.show(page: .meetings)
                let recorder = MeetingRecorder.shared
                recorder.title = UserDefaults.standard.string(forKey: "debugMeetingTitle") ?? "Test meeting"
                recorder.notes = "- hiring update\n- office move timing"
                let done = DoneCounter(paths.count)
                let sources = paths.map { url -> FileSource in let s = FileSource(url: url, speed: speed); s.finished = { done.tick() }; return s }
                await recorder.start(sources: (me: sources[0], others: sources.count > 1 ? sources[1] : nil))
                while !done.all { try? await Task.sleep(nanoseconds: 300_000_000) }
                await recorder.stop()
            }
        }
        // For testing: `-debugDictation speech.wav` dictates that file (at real-time speed) as if the key were held, and
        // logs the text instead of pasting it.
        if let path = UserDefaults.standard.string(forKey: "debugDictation") {
            Dictation.allowsDevices = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let source = FileSource(url: URL(fileURLWithPath: path), speed: 1)
                source.finished = { Task { @MainActor in await Dictation.shared.finish() } }
                Dictation.shared.begin(source: source)
            }
        }
        // For testing: `-debugOnboarding YES` opens the first-launch steps.
        if UserDefaults.standard.bool(forKey: "debugOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { OnboardingWindowController.shared.show() }
        }
        // For testing: `-debugSetup YES` opens the setup screen.
        if UserDefaults.standard.bool(forKey: "debugSetup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { SetupWindowController.shared.show() }
        }
        // For testing: `-debugMainPage sources` opens the main window on that page.
        if let page = UserDefaults.standard.string(forKey: "debugMainPage").flatMap(MainPage.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainWindowController.shared.show(page: page) }
        }
        // For testing: `-debugChat "question|follow-up|…"` opens a new chat and asks each in turn, waiting for answers.
        if let script = UserDefaults.standard.string(forKey: "debugChat") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                MainWindowController.shared.show(page: .chat)
                let chats = MainWindowController.shared.chats
                chats.newChat()
                for question in script.split(separator: "|") {
                    chats.send(String(question))
                    while chats.busy { try? await Task.sleep(nanoseconds: 200_000_000) }
                }
            }
        }
        // For testing: `-debugAsk "question"` opens the panel in Ask mode and asks it, as Tab, typing and ↩ would.
        if let question = UserDefaults.standard.string(forKey: "debugAsk") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                QuickPanelController.shared.show()
                QuickPanelController.shared.model.mode = .ask
                QuickPanelController.shared.model.query = question
                QuickPanelController.shared.model.ask()
            }
            // `-debugContinue YES`: once answered, ⌘J (Continue in Chat).
            if UserDefaults.standard.bool(forKey: "debugContinue") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    while QuickPanelController.shared.model.answering { try? await Task.sleep(nanoseconds: 200_000_000) }
                    QuickPanelController.shared.continueInChat()
                }
            }
        }
    }

    /// True when macOS opened it at login (Settings → Open at login), when it should stay quietly in the menu bar.
    private func launchedAtLogin(_ notification: Notification) -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (from Finder, Spotlight or the Dock) brings up the main window, or setup if it isn't done. With Settings
        // open (perhaps with a dialog on it), Settings comes forward instead, so that dialog isn't lost from view.
        if let settings = SettingsController.shared.window, settings.isVisible || settings.attachedSheet != nil {
            SettingsController.shared.show()
        } else if !AppState.shared.setupDone {
            OnboardingWindowController.shared.show()
        } else if EmbeddingModelFiles.isInstalled {
            MainWindowController.shared.show()
        } else {
            SetupWindowController.shared.show()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }

    /// An accessory app has no menu bar of its own, but its windows still need Edit's shortcuts (⌘C, ⌘V, ⌘A in
    /// text fields) and ⌘W / ⌘Q.
    /// The version, and the credits for every model and library (CREDITS.md, bundled), links clickable.
    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let url = Bundle.main.url(forResource: "CREDITS", withExtension: "md"),
           let credits = try? NSMutableAttributedString(
               markdown: Data(contentsOf: url),
               options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            credits.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                   .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: credits.length))
            // Bare addresses become links.
            if let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                for match in links.matches(in: credits.string, range: NSRange(location: 0, length: credits.length)) {
                    if let link = match.url { credits.addAttribute(.link, value: link, range: match.range) }
                }
            }
            options[.credits] = credits
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "About Familiar", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: "Quit Familiar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // Go: the main window's pages (⌘1–3), a new chat and recording.
        let goItem = NSMenuItem()
        let go = NSMenu(title: "Go")
        for (title, key, page) in [("Search", "1", MainPage.search), ("Chat", "2", MainPage.chat), ("Meetings", "3", MainPage.meetings),
                                   ("Sources", "4", MainPage.sources)] {
            let item = go.addItem(withTitle: title, action: #selector(goTo(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = page.rawValue
        }
        go.addItem(.separator())
        let newChat = go.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "n")
        newChat.target = self
        let record = go.addItem(withTitle: "Start or Stop Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        record.target = self
        let setup = go.addItem(withTitle: "Set Up This Mac…", action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        // No key here: its shortcut (⌥Space by default, changeable) works from any app, this one included.
        let search = go.addItem(withTitle: "Search or Ask…", action: #selector(openSearch), keyEquivalent: "")
        search.target = self
        goItem.submenu = go
        main.addItem(goItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func showSettings() { SettingsController.shared.show() }
    @objc private func goTo(_ sender: NSMenuItem) {
        if let page = (sender.representedObject as? String).flatMap(MainPage.init) { MainWindowController.shared.show(page: page) }
    }
    @objc private func newChat() { MainWindowController.shared.startNewChat() }
    @objc private func toggleRecording() { MainWindowController.shared.toggleRecording() }
    @objc private func openSearch() { QuickPanelController.shared.show() }
    @objc private func openSetup() { SetupWindowController.shared.show() }
}

/// Counts finished test sources (`-debugMeeting`).
final class DoneCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(_ count: Int) { left = count }
    func tick() { lock.lock(); left -= 1; lock.unlock() }
    var all: Bool { lock.lock(); defer { lock.unlock() }; return left <= 0 }
}
