import Foundation
import IOKit.ps

/// What indexing should do on battery (Settings).
enum BatteryBehavior: String, CaseIterable, Identifiable {
    case normal, slow, pause
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "Index normally"
        case .slow: return "Index slowly"
        case .pause: return "Pause indexing"
        }
    }
}

/// How fast indexing may go right now, and why it isn't full speed.
struct Pace: Equatable {
    enum Speed { case full, slow, paused }
    var speed: Speed
    var reason: String?

    static let full = Pace(speed: .full, reason: nil)
}

/// Watches the power source, Low Power Mode and the Mac's temperature, and calls `onChange` when any of them changes.
/// Searching is never limited; only indexing, which keeps the GPU busy, slows down or pauses.
@MainActor
final class PowerMonitor {
    private(set) var onBattery = false
    private(set) var lowPowerMode = false
    private(set) var thermal: ProcessInfo.ThermalState = .nominal
    private let onChange: () -> Void
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        read()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
        // Plugging in or unplugging: IOKit's power-source notification, on the main run loop.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.changed() }
        }, context)?.takeRetainedValue() {
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func read() {
        // `-debugPower battery|lowpower|hot|critical` (a launch argument) pretends, for testing.
        let pretend = UserDefaults.standard.string(forKey: "debugPower")
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            onBattery = type == kIOPSBatteryPowerValue
        }
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = ProcessInfo.processInfo.thermalState
        // A pretended scenario sets all three signals, so tests don't depend on this Mac's real state.
        if let pretend {
            onBattery = false; lowPowerMode = false; thermal = .nominal
            switch pretend {
            case "battery": onBattery = true
            case "lowpower": lowPowerMode = true
            case "hot": thermal = .serious
            case "critical": thermal = .critical
            default: break   // "ac": plugged in, cool
            }
        }
    }

    private func changed() {
        let before = (onBattery, lowPowerMode, thermal)
        read()
        if before != (onBattery, lowPowerMode, thermal) { onChange() }
    }

    /// The pace for indexing: macOS's own signals first (Low Power Mode, heat), then the battery setting.
    func pace(onBattery behavior: BatteryBehavior) -> Pace {
        if lowPowerMode { return Pace(speed: .paused, reason: "Low Power Mode is on") }
        if thermal == .critical { return Pace(speed: .paused, reason: "the Mac is very hot") }
        if onBattery && behavior == .pause { return Pace(speed: .paused, reason: "on battery") }
        if thermal == .serious { return Pace(speed: .slow, reason: "the Mac is hot") }
        if onBattery && behavior == .slow { return Pace(speed: .slow, reason: "on battery") }
        return .full
    }
}
