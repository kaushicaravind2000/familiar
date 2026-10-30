import AppKit
import FamiliarCore

/// Opening a result: at its moment for recordings and videos (QuickTime Player), in its app otherwise.
@MainActor
enum ResultActions {
    static func open(_ result: SearchResult, query: String) {
        // A meeting opens on the Meetings page, where it can be played and asked about.
        if Meetings.isMeetingFile(result.path) {
            MainWindowController.shared.show(page: .meetings)
            MeetingsModel.shared.open(result.path)
            return
        }
        if let seconds = result.seconds, openInQuickTime(result.url, at: seconds) { return }
        NSWorkspace.shared.open(result.url)
    }

    static func reveal(_ result: SearchResult) {
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    static func copy(_ result: SearchResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([result.url as NSURL])
    }

    /// QuickTime Player opens the file and jumps to the moment (macOS asks once whether Familiar may control it).
    private static func openInQuickTime(_ url: URL, at seconds: Double) -> Bool {
        let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        guard FileManager.default.fileExists(atPath: quickTime.path) else { return false }
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let start = max(0, seconds - 1)
        let source = """
            tell application "QuickTime Player"
                activate
                set theDocument to open POSIX file "\(path)"
                delay 0.3
                set current time of theDocument to \(start)
                play theDocument
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}
