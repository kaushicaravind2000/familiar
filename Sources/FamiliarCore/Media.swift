import AVFoundation
import CoreGraphics
import Foundation

/// Recordings and videos: the model hears 30 seconds at a time, so sound is cut into overlapping 30 s windows; video
/// adds a frame every few seconds, skipping frames that look like the one before (the same shot).
public enum MediaReader {
    /// Seconds of sound per input (the model hears at most 30) and between window starts. 10 s every 5 s, chosen with
    /// `fam eval` (2026-10-22, 15 audio queries): against 30 s every 25 s, first-place hits 0.93 vs 0.80, MRR 0.97 vs
    /// 0.86, a margin three times wider, for the same GPU time (twice the sound, half the length each).
    /// `FAMILIAR_AUDIO_WINDOW` and `FAMILIAR_AUDIO_HOP` override them, for A/B runs.
    public static let window: Double = ProcessInfo.processInfo.environment["FAMILIAR_AUDIO_WINDOW"].flatMap(Double.init) ?? 10
    public static let hop: Double = ProcessInfo.processInfo.environment["FAMILIAR_AUDIO_HOP"].flatMap(Double.init) ?? 5
    static let sampleRate = 16_000
    /// Longer than this, only the first three hours are read.
    static let maxSeconds: Double = 3 * 3600

    public struct AudioWindow {
        public let start: Double
        public let wav: Data
    }

    public struct Frame {
        public let time: Double
        public let jpeg: Data
    }

    public static func duration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration) else { return 0 }
        return time.seconds.isFinite ? time.seconds : 0
    }

    /// The soundtrack as 16 kHz mono 16-bit samples, then cut into windows. Windows that are near silence are dropped.
    public static func audioWindows(_ url: URL) async throws -> [AudioWindow] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? ReadError.unreadable("can't read its sound") }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? ReadError.unreadable("can't read its sound") }

        let windowSamples = Int(window * Double(sampleRate)), hopSamples = Int(hop * Double(sampleRate))
        var windows: [AudioWindow] = []
        var start = 0
        while start < samples.count {
            let end = min(start + windowSamples, samples.count)
            // A tail shorter than 3 s is covered by the window before it.
            if end - start < 3 * sampleRate && start > 0 { break }
            let slice = samples[start..<end]
            if rms(slice) > 60 {
                windows.append(AudioWindow(start: Double(start) / Double(sampleRate), wav: wav(slice)))
            }
            if end == samples.count { break }
            start += hopSamples
        }
        return windows
    }

    /// Frames every `interval` seconds (wider for long videos, at most `maxFrames`), each sized for `budget` tokens.
    /// A frame that looks like the last kept one is skipped.
    public static func frames(_ url: URL, duration: Double, budget: Int = 140, maxFrames: Int = 240) async -> [Frame] {
        guard duration > 0 else { return [] }
        let interval = max(3, duration / Double(maxFrames))
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        var frames: [Frame] = []
        var last: [UInt8]?
        var time = min(1, duration / 2)
        while time < min(duration, maxSeconds) {
            if let (image, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                let signature = tinySignature(image)
                if last == nil || difference(signature, last!) > 18 {
                    if let jpeg = ImagePrep.encode(image, budget: budget) {
                        frames.append(Frame(time: time, jpeg: jpeg))
                        last = signature
                    }
                }
            }
            time += interval
        }
        return frames
    }

    // MARK: - Helpers

    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        var i = samples.startIndex
        while i < samples.endIndex { let v = Double(samples[i]); sum += v * v; i += 8 }
        return (sum / Double(samples.count / 8 + 1)).squareRoot()
    }

    static func wav(_ samples: ArraySlice<Int16>) -> Data {
        var data = Data()
        let bytes = samples.count * 2
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// The frame shrunk to 16 × 16 gray: enough to tell one shot from the next.
    static func tinySignature(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 16 * 16)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return pixels
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0
        for i in 0..<min(a.count, b.count) { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}
