import Foundation

/// What kind of file this is, by extension: decides which reader takes it.
public enum FileKind: String, Sendable, CaseIterable {
    case text, document, pdf, office, image, audio, video

    public static func of(_ url: URL) -> FileKind? {
        byExtension[url.pathExtension.lowercased()]
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        for e in ["txt", "text", "md", "markdown", "mdown", "rst", "org", "tex", "typ", "csv", "tsv", "log"] { map[e] = .text }
        for e in ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "pages"] { map[e] = .document }
        map["pdf"] = .pdf
        for e in ["xlsx", "pptx", "ods", "odp", "key", "numbers"] { map[e] = .office }
        for e in ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "avif"] { map[e] = .image }
        for e in ["mp3", "m4a", "wav", "aac", "aif", "aiff", "caf", "flac", "m4b"] { map[e] = .audio }
        for e in ["mp4", "mov", "m4v", "3gp"] { map[e] = .video }
        return map
    }()

    /// Bigger files than this are skipped (a 2 GB "text" file is a data dump, not a note).
    var maxBytes: Int64 {
        switch self {
        case .text: return 20 << 20
        case .document, .office: return 100 << 20
        case .pdf: return 500 << 20
        case .image: return 80 << 20
        case .audio: return 2 << 30
        case .video: return 20 << 30
        }
    }

    /// Quick kinds first, so most of the index is searchable soon; long recordings and videos last.
    var order: Int {
        switch self {
        case .text, .document, .office: return 0
        case .image: return 1
        case .pdf: return 2
        case .audio: return 3
        case .video: return 4
        }
    }

    public var label: String {
        switch self {
        case .text, .document, .office: return "Document"
        case .pdf: return "PDF"
        case .image: return "Picture"
        case .audio: return "Recording"
        case .video: return "Video"
        }
    }
}

public struct Candidate: Sendable {
    public let url: URL
    public let kind: FileKind
    public let size: Int64
    public let mtime: Double
}

/// Walks the chosen folders and lists the files worth reading. It never reads hidden folders, app bundles and other
/// packages, dependency and build folders, or files that only live in iCloud (that would download them).
public enum FolderScanner {
    static let skippedFolders: Set<String> = [
        "node_modules", "bower_components", "__pycache__", "venv", "site-packages", "dist-packages",
        "DerivedData", "Pods", "Carthage", "Caches",
    ]
    /// Skipped only inside a code project (a folder with one of `projectMarkers`), where they hold build output.
    static let projectFolders: Set<String> = ["build", "target", "dist", "out", "vendor", "env", "tmp", "coverage"]
    static let projectMarkers = [".git", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Package.swift",
                                 "pom.xml", "build.gradle", "CMakeLists.txt", "Makefile", "setup.py"]
    static let systemFolders: Set<String> = ["Library", "Applications", "System", ".Trash"].reduce(into: []) {
        $0.insert(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($1).path)
    }
    static let skippedExtensions: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
                                                 "fcpbundle", "noindex", "xcodeproj", "xcworkspace", "framework",
                                                 "bundle", "plugin", "kext", "lproj", "xcassets"]

    public struct Scan: Sendable {
        public var candidates: [Candidate] = []
        /// Folders macOS wouldn't let Familiar open (privacy settings, other users' folders): their files are
        /// missing from the index, and Settings says so.
        public var denied: [URL] = []
    }

    public static func scan(roots: [URL], excluded: [URL] = [], isCancelled: () -> Bool = { false }) -> [Candidate] {
        scanReporting(roots: roots, excluded: excluded, isCancelled: isCancelled).candidates
    }

    public static func scanReporting(roots: [URL], excluded: [URL] = [], isCancelled: () -> Bool = { false }) -> Scan {
        var denied: [URL] = []
        let result = scanCandidates(roots: roots, excluded: excluded, isCancelled: isCancelled) { url, error in
            if isPermissionError(error) { denied.append(url.standardizedFileURL) }
        }
        // Only the outermost refused folders: one inside another adds nothing.
        let paths = denied.map(\.path).sorted()
        var outermost: [URL] = []
        for path in paths where !outermost.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            outermost.append(URL(fileURLWithPath: path))
        }
        return Scan(candidates: result, denied: outermost)
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    private static func scanCandidates(roots: [URL], excluded: [URL], isCancelled: () -> Bool,
                                       onError: @escaping (URL, Error) -> Void) -> [Candidate] {
        let excludedPaths = excluded.map { $0.standardizedFileURL.path }
        var seen = Set<String>()
        var out: [Candidate] = []
        for root in roots {
            // A file chosen on its own: just that file.
            if let values = try? root.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                if let candidate = candidate(root, values), seen.insert(candidate.url.path).inserted { out.append(candidate) }
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                    onError(url, error)
                    return true
                }) else { continue }
            // The enumerator reports nothing for a root it can't open: check that one by hand.
            do { _ = try FileManager.default.contentsOfDirectory(atPath: root.path) } catch { onError(root, error); continue }
            for case let url as URL in enumerator {
                if isCancelled() { return out }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if skipsFolder(url, excludedPaths: excludedPaths) || looksLikeDataset(url) { enumerator.skipDescendants() }
                    continue
                }
                guard let candidate = candidate(url, values) else { continue }
                guard seen.insert(candidate.url.path).inserted else { continue }
                out.append(candidate)
            }
        }
        return out
    }

    static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
                                         .contentModificationDateKey, .isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]

    /// A folder whose contents are never read.
    static func skipsFolder(_ url: URL, excludedPaths: [String]) -> Bool {
        let name = url.lastPathComponent, path = url.standardizedFileURL.path
        return name.hasPrefix(".") || skippedFolders.contains(name) || skippedExtensions.contains(url.pathExtension.lowercased())
            || name.hasSuffix(".noindex") || excludedPaths.contains(path) || systemFolders.contains(path)
            || (projectFolders.contains(name) && isInProject(url))
    }

    /// The file as something to read, or nil: not a kind Familiar reads, empty or too big, only in iCloud, a lock
    /// file or hidden.
    static func candidate(_ url: URL, _ values: URLResourceValues) -> Candidate? {
        let name = url.lastPathComponent
        guard values.isRegularFile == true, let kind = FileKind.of(url), !name.hasPrefix("."), !name.hasPrefix("~$")
        else { return nil }
        if Privacy.isSecretName(name) { return nil }
        if Privacy.dataExtensions.contains(url.pathExtension.lowercased()) && !Privacy.readsDataFiles { return nil }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return nil }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, size <= kind.maxBytes else { return nil }
        return Candidate(url: url.standardizedFileURL, kind: kind, size: size,
                         mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    public struct ChangeScan: Sendable {
        public var candidates: [Candidate] = []
        /// What this scan speaks for: a path here, or anything under it, that isn't among `candidates` is gone.
        public var scopes: [String] = []
    }

    /// Looks only at the paths FSEvents reported (files or folders, new, changed or gone) instead of every folder:
    /// a changed file is checked on its own, a folder that appeared or changed is read through, and a path that no
    /// longer exists marks everything that was there as gone. The same rules as a full scan decide what's read.
    public static func scanChanges(_ paths: [String], roots: [URL], excluded: [URL] = []) -> ChangeScan {
        let excludedPaths = excluded.map { $0.standardizedFileURL.path }
        let rootPaths = roots.map { $0.standardizedFileURL.path }
        var scan = ChangeScan()
        var seen = Set<String>()
        // Outer paths first, so a file inside a folder that is read through isn't checked twice.
        for path in Set(paths.map(normalized)).sorted() {
            guard let root = rootPaths.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            if scan.scopes.contains(where: { path.hasPrefix($0 + "/") }) && FileManager.default.fileExists(atPath: path) {
                continue
            }
            if isExcluded(path, root: root, excludedPaths: excludedPaths) { continue }
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                scan.scopes.append(path)
            } else if isDirectory.boolValue {
                if skipsFolder(url, excludedPaths: excludedPaths) { continue }
                for candidate in scanCandidates(roots: [url], excluded: excluded, isCancelled: { false }, onError: { _, _ in })
                where seen.insert(candidate.url.path).inserted {
                    scan.candidates.append(candidate)
                }
                scan.scopes.append(path)
            } else {
                if let values = try? url.resourceValues(forKeys: Set(keys)), let candidate = candidate(url, values),
                   seen.insert(candidate.url.path).inserted {
                    scan.candidates.append(candidate)
                }
                scan.scopes.append(path)
            }
        }
        return scan
    }

    /// The path as the index spells it. Standardizing only works on paths that exist (it turns /private/tmp/x into
    /// /tmp/x, as the crawler's paths are), so for one that's gone, its nearest existing folder is standardized and
    /// the rest added back; otherwise a deleted file's path wouldn't match its indexed one.
    public static func normalized(_ path: String) -> String {
        let fm = FileManager.default
        var folder = URL(fileURLWithPath: path)
        var tail: [String] = []
        while !fm.fileExists(atPath: folder.path) && folder.path != "/" {
            tail.insert(folder.lastPathComponent, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        return tail.reduce(folder.standardizedFileURL) { $0.appendingPathComponent($1) }.path
    }

    /// True when a folder between `root` and `path` is one a full scan would skip.
    static func isExcluded(_ path: String, root: String, excludedPaths: [String]) -> Bool {
        guard path.count > root.count else { return false }
        var folder = URL(fileURLWithPath: root)
        let parts = path.dropFirst(root.count).split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            folder.appendPathComponent(part)
            if skipsFolder(folder, excludedPaths: excludedPaths) { return true }
        }
        return parts.last?.hasPrefix(".") ?? false
    }

    private static func isInProject(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        return projectMarkers.contains { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
    }

    /// A folder of thousands of same-kind files (an image dataset, exported frames) would swamp the index: skip
    /// folders with more than 3,000 files directly inside.
    private static func looksLikeDataset(_ url: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return names.count > 3000
    }
}
