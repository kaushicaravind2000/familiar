import Foundation

/// How much memory Familiar allows itself. Macs with 12 GB or less get `.low` automatically: a leaner indexing
/// server (peak ~1.85 GB instead of ~2.6 GB, measured), photos at half the detail (about twice as fast to read), vectors
/// held as 8-bit numbers (a quarter of the memory), and no search model kept loaded unless asked for.
public enum MemoryProfile: String, CaseIterable, Sendable {
    case standard, low

    /// What this Mac gets on Automatic.
    public static var automatic: MemoryProfile { physicalGB <= 12 ? .low : .standard }

    public static var physicalGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// The setting: nil is Automatic. `FAMILIAR_MEMORY=low|standard` overrides it (the CLI, tests).
    public static var chosen: MemoryProfile? {
        get {
            if let env = ProcessInfo.processInfo.environment["FAMILIAR_MEMORY"] { return MemoryProfile(rawValue: env) }
            return SettingsStore.defaults.string(forKey: "memoryProfile").flatMap(MemoryProfile.init)
        }
        set { SettingsStore.defaults.set(newValue?.rawValue, forKey: "memoryProfile") }
    }

    public static var current: MemoryProfile { chosen ?? automatic }

    /// Soft tokens per picture kind (`ImageBudgets`), the same in both profiles. Chosen with `fam eval` (evals/core.json,
    /// 99 queries, 2026-10-22): photo 140 / screenshot 280 / page 280 / frame 70 ranked every query the same as
    /// 280 / 280 / 560 / 140, with an equal or larger margin, and read pictures about twice as fast (DigUp's defaults).
    public var budgets: ImageBudgets { ImageBudgets(photo: 140, screenshot: 280, page: 280, frame: 70) }
    /// Vectors in memory as 8-bit numbers, rescored exactly from the index.
    public var compactVectors: Bool { self == .low }
    /// Whether the search model stays loaded when the setting was never touched.
    public var searchServerByDefault: Bool { self == .standard }
}

/// How much detail (vision soft tokens: 70, 140, 280, 560 or 1120) each kind of picture is sent at. More detail costs
/// GPU time roughly in proportion. `FAMILIAR_BUDGET_PHOTO`, `_SCREENSHOT`, `_PAGE` and `_FRAME` override them, for
/// A/B runs with `fam eval`.
public struct ImageBudgets: Sendable, Equatable, Codable {
    public var photo: Int
    public var screenshot: Int
    /// Scanned PDF pages (pages without a text layer).
    public var page: Int
    public var frame: Int

    public init(photo: Int, screenshot: Int, page: Int, frame: Int) {
        self.photo = photo; self.screenshot = screenshot; self.page = page; self.frame = frame
    }

    public static var current: ImageBudgets {
        var budgets = MemoryProfile.current.budgets
        let env = ProcessInfo.processInfo.environment
        if let v = env["FAMILIAR_BUDGET_PHOTO"].flatMap(Int.init) { budgets.photo = v }
        if let v = env["FAMILIAR_BUDGET_SCREENSHOT"].flatMap(Int.init) { budgets.screenshot = v }
        if let v = env["FAMILIAR_BUDGET_PAGE"].flatMap(Int.init) { budgets.page = v }
        if let v = env["FAMILIAR_BUDGET_FRAME"].flatMap(Int.init) { budgets.frame = v }
        return budgets
    }
}
