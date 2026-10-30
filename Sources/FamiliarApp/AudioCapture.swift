import AVFoundation
import CoreAudio
import Foundation
import IOKit
import FamiliarCore

/// Where a meeting's sound comes from. Each source hands over 16 kHz mono samples (what the speech model takes) as
/// they arrive, on its own thread.
protocol AudioSource: AnyObject {
    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

/// 16 kHz mono, 32-bit float: the speech model's format.
let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

/// Converts whatever a device delivers (48 kHz stereo, say) to `speechFormat`.
final class Resampler {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat

    init?(from input: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: speechFormat) else { return nil }
        self.converter = converter
        self.input = input
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = speechFormat.sampleRate / input.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

/// Your microphone: "Me". Opening a Bluetooth headset's microphone switches the headset to its call mode, which
/// reconfigures the audio devices, and macOS then stops the engine (it would record nothing for the whole meeting); a
/// change of input device does the same. So on a change it starts again with the new format, and a watchdog restarts
/// it if no sound has arrived for 3 s. The time lost is filled with silence, so "Me" stays in step with the call.
///
/// When the input is a Bluetooth headset, the Mac's own microphone is used instead (Settings → Push to talk, on by
/// default): opening the headset's microphone takes it into call mode, which loses the first second, sounds like a
/// phone line to the speech model, and makes whatever's playing in the headphones sound worse until it ends. Not when
/// the lid is closed, which turns the built-in microphone off.
final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var observer: NSObjectProtocol?
    private var watchdog: Timer?
    private var restartedAt = Date.distantPast
    private let clock = Clock()

    /// When sound last arrived, and whether a restart's gap is still to be filled. Read on the audio thread too.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Date?
        private var gapPending = false
        private var started = Date()

        func begin() { lock.lock(); started = Date(); last = nil; gapPending = false; lock.unlock() }
        func restarting() { lock.lock(); gapPending = true; lock.unlock() }
        /// Seconds of silence owed before a buffer of `duration` seconds that just arrived.
        func arrived(duration: Double) -> Double {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            let gap = gapPending ? now.timeIntervalSince(last ?? started) - duration : 0
            last = now; gapPending = false
            return min(max(gap, 0), 30)
        }
        var silentFor: Double { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last ?? started) }
    }

    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        self.onSamples = onSamples
        clock.begin()
        try connect()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            self?.restart("the audio devices changed")
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // At most every 5 s, so a microphone that's gone for good isn't restarted every second.
            guard let self, self.clock.silentFor > 3, Date().timeIntervalSince(self.restartedAt) > 5 else { return }
            self.restart("no sound for 3 s")
        }
    }

    private func connect() throws {
        guard let onSamples else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if Self.avoidsBluetooth, var device = AudioDevices.builtInInsteadOfBluetooth(), let unit = input.audioUnit,
           AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr {
            AppLog.write("microphone: the Mac's own, not the Bluetooth headset's")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let resampler = Resampler(from: format) else {
            throw RecordingError.noMicrophone
        }
        let clock = clock
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let gap = clock.arrived(duration: Double(buffer.frameLength) / format.sampleRate)
            if gap > 0.05 { onSamples([Float](repeating: 0, count: Int(gap * speechFormat.sampleRate))) }
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    private func restart(_ why: String) {
        guard onSamples != nil else { return }
        restartedAt = Date()
        clock.restarting()
        engine.stop()
        do {
            try connect()
            AppLog.write("meeting: microphone restarted (\(why))")
        } catch {
            AppLog.write("meeting: microphone didn't restart (\(why)): \(error.localizedDescription)")
        }
    }

    /// Settings → Push to talk → "Use the Mac's microphone with Bluetooth headphones".
    static var avoidsBluetooth: Bool {
        get { SettingsStore.defaults.object(forKey: "micAvoidsBluetooth") as? Bool ?? true }
        set { SettingsStore.defaults.set(newValue, forKey: "micAvoidsBluetooth") }
    }

    func stop() {
        onSamples = nil
        watchdog?.invalidate(); watchdog = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Everything the Mac plays (the other people on a call, in any app): a Core Audio process tap on all output, read
/// through a private aggregate device. macOS 14.2 and later; macOS asks once for "System Audio Recording".
@available(macOS 14.2, *)
final class SystemAudioSource: AudioSource {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Familiar.systemAudio", qos: .userInitiated)

    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Familiar meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Familiar Meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the capture device")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read the tap's format")
        guard let tapFormat = AVAudioFormat(streamDescription: &format), let resampler = Resampler(from: tapFormat) else {
            throw RecordingError.systemAudio("unsupported audio format")
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        }, "listen to the tap")
        try check(AudioDeviceStart(aggregateID, procID), "start the capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { stop(); throw RecordingError.systemAudio("couldn't \(what) (\(status))") }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            throw RecordingError.systemAudio("no output device")
        }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw RecordingError.systemAudio("no output device id") }
        return uid as String
    }
}

/// The Mac's audio devices, as far as choosing a microphone needs.
enum AudioDevices {
    /// The built-in microphone, when the default input is a Bluetooth headset and the lid is open; otherwise nil (use
    /// the default).
    static func builtInInsteadOfBluetooth() -> AudioDeviceID? {
        guard let input = defaultInput(), [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
            .contains(transport(input)), !lidClosed else { return nil }
        return all().first { transport($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    private static func defaultInput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func all() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func transport(_ device: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// A MacBook with its lid shut (on an external display): the built-in microphone is off.
    private static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }
}

/// For tests: plays a recording into the recorder instead of a device, `speed` times faster than real time.
final class FileSource: AudioSource {
    private let url: URL
    private let speed: Double
    private var task: Task<Void, Never>?
    var finished: (@Sendable () -> Void)?

    init(url: URL, speed: Double) { self.url = url; self.speed = speed }

    func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let url = self.url, speed = self.speed, finished = self.finished
        task = Task.detached {
            guard let file = try? AVAudioFile(forReading: url), let resampler = Resampler(from: file.processingFormat) else { finished?(); return }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)   // 0.1 s
            let started = Date()
            var fed = 0
            while !Task.isCancelled, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) {
                guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                let samples = resampler.convert(buffer)
                fed += samples.count
                onSamples(samples)
                try? await Task.sleep(nanoseconds: UInt64(100_000_000 / speed))
            }
            AppLog.write(String(format: "test source %@: fed %.1f s of sound in %.1f s%@", url.lastPathComponent,
                                Double(fed) / 16_000, Date().timeIntervalSince(started), Task.isCancelled ? " (stopped)" : ""))
            finished?()
        }
    }

    func stop() { task?.cancel() }
}

enum RecordingError: LocalizedError {
    case noMicrophone, microphoneDenied, systemAudio(String)
    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone was found."
        case .microphoneDenied: return "Familiar isn't allowed to use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
        case .systemAudio(let why): return "The Mac's sound can't be recorded: \(why)."
        }
    }
}
