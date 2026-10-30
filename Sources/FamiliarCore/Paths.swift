import Foundation

/// Where Familiar keeps its things: `~/Library/Application Support/Familiar` holds the model and the index.
public enum AppPaths {
    public static let appName = "Familiar"

    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `FAMILIAR_MODELS` lets a test copy use its own model folder.
    public static var models: URL {
        let url = ProcessInfo.processInfo.environment["FAMILIAR_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? applicationSupport.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `FAMILIAR_INDEX` points the CLI at a test index instead of the app's.
    public static var index: URL {
        if let path = ProcessInfo.processInfo.environment["FAMILIAR_INDEX"] { return URL(fileURLWithPath: path) }
        return applicationSupport.appendingPathComponent("index.sqlite")
    }
    /// Saved chats (Ask in the main window), kept apart from the index. `FAMILIAR_CHATS` points a test copy elsewhere.
    public static var chats: URL {
        if let path = ProcessInfo.processInfo.environment["FAMILIAR_CHATS"] { return URL(fileURLWithPath: path) }
        return applicationSupport.appendingPathComponent("chats.sqlite")
    }
    /// `FAMILIAR_LOGS` keeps a test copy's logs out of the app's.
    public static var logs: URL {
        let url = ProcessInfo.processInfo.environment["FAMILIAR_LOGS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? applicationSupport.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The bundled `fam` tool, whose `guard` command stops a helper when its parent exits: in the app at
    /// Contents/Helpers/fam; for the CLI itself, its own binary; in development, the one SwiftPM built.
    public static var sfsTool: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["FAMILIAR_SFS"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/fam"))
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        if executable.lastPathComponent == "fam" { candidates.append(executable) }
        candidates.append(executable.deletingLastPathComponent().appendingPathComponent("fam"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// The speech-to-text helper (Parakeet on the Neural Engine, macOS 14+): in the app at Contents/Helpers, or in
    /// development the one `swift build --package-path Transcriber` makes.
    public static var transcriber: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["FAMILIAR_TRANSCRIBER"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/familiar-speech"))
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(executable.deletingLastPathComponent().appendingPathComponent("familiar-speech"))
        var dir = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Transcriber/.build/release/familiar-speech"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// The bundled llama-server: in the app at Contents/Helpers, or, for `swift run` during development, the one
    /// `scripts/build-llama-server.sh` builds in Vendor/.
    public static var llamaServer: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["FAMILIAR_LLAMA_SERVER"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llama-server"))
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Vendor/llama-build/bin/llama-server"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}

/// Appends to a log in Logs/, keeping it small: past 1 MB the file becomes `<name>.1` (replacing the older one) and a
/// new one starts, so a log never takes more than 2 MB.
public enum LogFile {
    private static let lock = NSLock()
    public static let limit = 1 << 20

    public static func append(_ line: String, to name: String) {
        lock.lock(); defer { lock.unlock() }
        let url = AppPaths.logs.appendingPathComponent(name)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > limit {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// Where the app keeps its settings (chosen folders and files, preferences): its own defaults, or with
/// FAMILIAR_DEFAULTS_SUITE a separate store, so a test copy of the app can never change the real app's settings.
public enum SettingsStore {
    public static let defaults: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["FAMILIAR_DEFAULTS_SUITE"], let store = UserDefaults(suiteName: suite) {
            return store
        }
        return .standard
    }()
}
