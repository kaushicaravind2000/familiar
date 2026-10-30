import Foundation

/// What Familiar keeps on disk, for Settings → Storage: the models (each removable but search's), the index, and
/// meetings' audio, which can be deleted after a while (the transcript and notes always stay).
public enum Storage {
    /// Bytes a file or folder takes on disk (allocated, so a sparse file counts as what it really uses).
    public static func size(of url: URL) -> Int64 {
        let url = url.resolvingSymlinksInPath()   // a model folder can be a link (test copies)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return Int64((try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = walker?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Models

    public static var speechFolder: URL { AppPaths.models.appendingPathComponent("Speech", isDirectory: true) }

    /// What's in Models/Speech that the app no longer uses: models from earlier versions (Parakeet TDT v3, the
    /// Nemotron experiment). Everything SpeechModelFiles pins, and the ready markers, are in use.
    public static var unusedSpeech: [URL] {
        let used = Set(SpeechModelFiles.all.compactMap { $0.folder.split(separator: "/").dropFirst().first.map(String.init) })
            .union(["ready", "verified"])
        let items = (try? FileManager.default.contentsOfDirectory(at: speechFolder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !used.contains($0.lastPathComponent) && !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Every speech model, and the marker saying they're ready: the next meeting or dictation downloads them again.
    public static func removeSpeechModels() throws {
        try FileManager.default.removeItem(at: speechFolder)
    }

    public static func removeUnusedSpeech() {
        for url in unusedSpeech { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Meeting audio

    /// Settings → Storage → "Keep meeting audio": days, or 0 for always.
    public static var meetingAudioDays: Int {
        get { SettingsStore.defaults.integer(forKey: "meetingAudioDays") }
        set { SettingsStore.defaults.set(newValue, forKey: "meetingAudioDays") }
    }

    /// Each meeting's audio folder in Meetings/.recordings, with when it was recorded.
    public static func meetingAudio() -> [(url: URL, date: Date)] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Meetings.recordings, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey])) ?? []
        return items.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            return (url, values?.creationDate ?? .distantFuture)
        }
    }

    /// The audio that keeping it `days` days would delete now (none for 0, always).
    public static func meetingAudio(olderThan days: Int, now: Date = Date()) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return meetingAudio().filter { $0.date < cutoff }.map(\.url)
    }

    /// Deletes meeting audio older than the setting allows, except `keeping` (a meeting being recorded). The count.
    @discardableResult
    public static func deleteOldMeetingAudio(keeping: URL? = nil) -> Int {
        let old = meetingAudio(olderThan: meetingAudioDays).filter { $0.standardizedFileURL != keeping?.standardizedFileURL }
        for url in old { try? FileManager.default.removeItem(at: url) }
        return old.count
    }
}
