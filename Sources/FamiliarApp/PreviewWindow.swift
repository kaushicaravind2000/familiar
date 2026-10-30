import AVKit
import AppKit
import PDFKit
import Quartz
import FamiliarCore

/// The big preview (Space): PDFs at the matching page with the words highlighted, recordings and videos playing from
/// the moment, pictures whole, anything else through Quick Look.
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    static let shared = PreviewWindowController()
    private(set) var window: NSPanel!
    private var current: SearchResult?
    private var player: AVPlayer?
    private var keyMonitor: Any?

    private override init() {
        super.init()
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                         styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
    }

    var isVisible: Bool { window.isVisible }

    func toggle(_ result: SearchResult, query: String) {
        if window.isVisible && current == result { close() } else { show(result, query: query) }
    }

    func show(_ result: SearchResult, query: String) {
        current = result
        player?.pause()
        player = nil
        window.title = result.name + (result.place.map { " — \($0)" } ?? "")
        window.contentView = view(for: result, query: query)
        if !window.isVisible { window.center() }
        window.orderFront(nil)
        installKeyMonitor()
    }

    func close() {
        player?.pause()
        player = nil
        window.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowWillClose(_ notification: Notification) { close() }

    /// While the preview is up, Space closes it and the arrows move through the results (as in Quick Look).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.keyCode {
            case 49, 53: self.close(); return nil
            case 125: QuickPanelController.shared.previewDidMove(1); return nil
            case 126: QuickPanelController.shared.previewDidMove(-1); return nil
            default: return event
            }
        }
    }

    private func view(for result: SearchResult, query: String) -> NSView {
        switch result.fileKind {
        case .pdf:
            let view = PDFView()
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            if let document = PDFDocument(url: result.url) {
                view.document = document
                if let index = result.page, let page = document.page(at: index) { view.go(to: page) }
                // Highlight the query's words on that page.
                let words = query.split(separator: " ").map(String.init).filter { $0.count > 3 }
                var selections: [PDFSelection] = []
                for word in words.prefix(6) {
                    for selection in document.findString(word, withOptions: .caseInsensitive).prefix(40)
                    where selection.pages.contains(where: { document.index(for: $0) == result.page }) {
                        selection.color = NSColor.systemYellow.withAlphaComponent(0.5)
                        selections.append(selection)
                    }
                }
                view.highlightedSelections = selections
            }
            return view
        case .audio, .video:
            let view = AVPlayerView()
            view.controlsStyle = .floating
            let player = AVPlayer(url: result.url)
            self.player = player
            view.player = player
            let start = max(0, (result.seconds ?? 0) - 1)
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async { player.play() }
            }
            return view
        default:
            let view = QLPreviewView(frame: .zero, style: .normal)!
            view.previewItem = result.url as NSURL
            return view
        }
    }
}
