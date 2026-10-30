import AppKit
import Combine
import FamiliarCore

/// The menu-bar item: indexing status, search, pause, settings.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppState
    private var observers: Set<AnyCancellable> = []

    init(model: AppState) {
        self.model = model
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        model.$progress.combineLatest(model.$modelState).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &observers)
        model.$paused.combineLatest(model.$pace).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }.store(in: &observers)
    }

    private func updateIcon() {
        let busy = model.isIndexing || { if case .downloading = model.modelState { return true }; return false }()
        let pausedNow = model.paused || (model.pace.speed == .paused && model.isIndexing)
        // The cat, as in the app icon; paw prints while it's out reading files. Older macOS without the cat symbols
        // gets the magnifying glass.
        let name = pausedNow ? "pause.circle" : busy ? "pawprint.fill" : "cat.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Familiar")
            ?? NSImage(systemSymbolName: busy ? "doc.text.magnifyingglass" : "magnifyingglass", accessibilityDescription: "Familiar")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Familiar: \(model.statusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let eta = model.indexETA {
            let line = NSMenuItem(title: "\(eta.roughly) left", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())

        let search = NSMenuItem(title: "Search or Ask…", action: #selector(openSearch),
                                keyEquivalent: GlobalShortcut.search.combo?.keyEquivalent ?? "")
        search.keyEquivalentModifierMask = GlobalShortcut.search.combo?.modifierMask ?? []
        search.target = self
        menu.addItem(search)
        let open = NSMenuItem(title: "New Chat", action: #selector(newChat), keyEquivalent: "")
        open.target = self
        open.isEnabled = model.setupDone && model.modelState == .ready
        menu.addItem(open)
        let main = NSMenuItem(title: "Open Familiar", action: #selector(openMain), keyEquivalent: "")
        main.target = self
        main.isEnabled = open.isEnabled
        menu.addItem(main)
        let recording = MeetingRecorder.shared.state == .recording
        let record = NSMenuItem(title: recording ? "Stop Recording Meeting" : "Record a Meeting", action: #selector(toggleRecording),
                                keyEquivalent: GlobalShortcut.record.combo?.keyEquivalent ?? "")
        record.keyEquivalentModifierMask = GlobalShortcut.record.combo?.modifierMask ?? []
        record.target = self
        record.isEnabled = recording || !MeetingRecorder.shared.isActive
        menu.addItem(record)

        if model.isIndexing || model.paused {
            let pause = NSMenuItem(title: model.paused ? "Resume Indexing" : "Pause Indexing", action: #selector(togglePause),
                                   keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
        } else {
            let now = NSMenuItem(title: "Check for New Files", action: #selector(indexNow), keyEquivalent: "")
            now.target = self
            now.isEnabled = model.modelState == .ready && !model.folders.isEmpty
            menu.addItem(now)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        // Its own target, so nothing in the window chain can grey it out.
        let quit = NSMenuItem(title: "Quit Familiar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func quitApp() { (NSApp.delegate as? AppDelegate)?.quit() }
    @objc private func openSearch() { QuickPanelController.shared.show() }
    @objc private func openMain() { MainWindowController.shared.show() }
    @objc private func newChat() { MainWindowController.shared.startNewChat() }
    @objc private func toggleRecording() { MainWindowController.shared.toggleRecording() }
    @objc private func openSettings() { SettingsController.shared.show() }
    @objc private func togglePause() { model.togglePause() }
    @objc private func indexNow() { model.indexNow() }
}
