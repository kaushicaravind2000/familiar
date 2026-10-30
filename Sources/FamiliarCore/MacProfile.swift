import Foundation
import IOKit
import IOKit.ps

/// This Mac, as setup needs it: what it is, how much memory and GPU it has, which macOS, how much disk is free.
/// Read without any permission. `FAMILIAR_MAC="name;chip;memoryGB;gpuCores;macOS;freeGB"` pretends to be another
/// Mac (tests and screenshots of the other tiers).
public struct MacProfile: Sendable {
    public let name: String          // "MacBook Pro (16-inch, Nov 2024)"
    public let chip: String          // "Apple M4 Max"
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let gpuCores: Int
    public let memoryGB: Int
    public let macOS: OperatingSystemVersion
    public let freeDiskGB: Double
    public let isLaptop: Bool

    public static let current: MacProfile = simulated ?? detect()

    public var macOSText: String {
        "macOS \(macOS.majorVersion).\(macOS.minorVersion)" + (macOS.patchVersion > 0 ? ".\(macOS.patchVersion)" : "")
    }

    public var coresText: String {
        let cpu = performanceCores + efficiencyCores
        return (cpu > 0 ? "\(cpu)-core CPU" : "") + (gpuCores > 0 ? (cpu > 0 ? ", " : "") + "\(gpuCores)-core GPU" : "")
    }

    func atLeast(_ major: Int, _ minor: Int = 0) -> Bool {
        (macOS.majorVersion, macOS.minorVersion) >= (major, minor)
    }

    // MARK: - Reading it

    private static func detect() -> MacProfile {
        MacProfile(name: ioString(path: "IODeviceTree:/product", key: "product-name") ?? sysctlString("hw.model") ?? "Mac",
                   chip: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
                   performanceCores: sysctlInt("hw.perflevel0.physicalcpu"), efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"),
                   gpuCores: gpuCoreCount(), memoryGB: MemoryProfile.physicalGB,
                   macOS: ProcessInfo.processInfo.operatingSystemVersion, freeDiskGB: freeDisk(), isLaptop: hasBattery())
    }

    private static var simulated: MacProfile? {
        guard let spec = ProcessInfo.processInfo.environment["FAMILIAR_MAC"] else { return nil }
        let p = spec.split(separator: ";").map(String.init)
        guard p.count >= 6 else { return nil }
        let os = p[4].split(separator: ".").compactMap { Int($0) }
        return MacProfile(name: p[0], chip: p[1], performanceCores: 0, efficiencyCores: 0, gpuCores: Int(p[3]) ?? 8,
                          memoryGB: Int(p[2]) ?? 8,
                          macOS: OperatingSystemVersion(majorVersion: os.first ?? 14, minorVersion: os.dropFirst().first ?? 0, patchVersion: 0),
                          freeDiskGB: Double(p[5]) ?? 50, isLaptop: p[0].lowercased().contains("book"))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
    }

    private static func ioString(path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        if let data = value as? Data { return String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
        return value as? String
    }

    private static func gpuCoreCount() -> Int {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            if let count = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int { return count }
        }
        return 0
    }

    private static func freeDisk() -> Double {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bytes = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        return Double(bytes) / 1_000_000_000
    }

    private static func hasBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return (description?[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }
    }
}

/// What Familiar sets up on a Mac. The models are the same everywhere (EmbeddingGemma 2, Apple's text recognition,
/// Qwen3.5-4B, Parakeet); the tier only changes how they share memory. Decided with the evals of 2026-10-23: the 2B
/// was twice as fast but invented answers the 4B didn't, and the 4B at 3-bit saved 0.4 GB without being faster.
public struct SetupPlan: Sendable {
    public enum Tier: String, Sendable { case light, standard, fast }
    public enum Availability: Sendable, Equatable { case available, limited(String), unavailable(String) }

    public let mac: MacProfile
    public var tier: Tier {
        if mac.memoryGB <= 12 { return .light }
        return mac.gpuCores >= 30 ? .fast : .standard
    }
    public var profile: MemoryProfile { mac.memoryGB <= 12 ? .low : .standard }

    public var tierTitle: String {
        switch tier {
        case .light: return "Light"
        case .standard: return "Standard"
        case .fast: return "Fast"
        }
    }

    public var tierSummary: String {
        switch tier {
        case .light: return "With \(mac.memoryGB) GB, Familiar saves memory: it pauses indexing while you chat, and lets the models go sooner when idle."
        case .standard: return "Everything runs side by side: search, indexing, chat and meetings."
        case .fast: return "Everything runs side by side, and answers come quickly on this GPU."
        }
    }

    public var chatNote: String {
        switch tier {
        case .light: return "Pauses indexing while you chat, so both fit in \(mac.memoryGB) GB. Writes about 10–20 words a second here."
        case .standard: return "Writes about 15–35 words a second on this Mac."
        case .fast: return "Writes about 40–70 words a second on this Mac."
        }
    }

    public var speech: Availability {
        if !mac.atLeast(14) { return .unavailable("Needs macOS 14 or later. This Mac has \(mac.macOSText).") }
        if !mac.atLeast(14, 2) { return .limited("Records your microphone only: recording the other people on a call needs macOS 14.2.") }
        return .available
    }

    public init(mac: MacProfile = .current) { self.mac = mac }
}
