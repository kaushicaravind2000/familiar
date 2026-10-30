import AVFoundation
import AppKit
import CoreText

// Makes the eval test collection's generated files (scripts/make-test-collection.sh runs it). Everything is drawn or spoken
// here, so the collection holds nothing personal and comes out the same on every Mac.
//   screenshot <out.png> <title> <line>...      an app window with text, as a screenshot
//   card <out.jpg> <line>...                    an ID-card-like photo
//   pdf <out.pdf> <page text>...                a text PDF, one argument per page
//   scan <out.pdf> <line>...                    a scanned receipt: an image-only PDF, no text layer
//   concat <out.m4a> <seconds> <in>...          sound files back to back, each padded to <seconds>
//   video <out.mov> <audio|-> <image:seconds>...  pictures shown for given seconds, with a soundtrack

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, args.count >= 2 else { print("usage: see the top of testbed.swift"); exit(2) }
let out = URL(fileURLWithPath: args[1])

func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
    bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
}

func bitmap(_ width: Int, _ height: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func text(_ string: String, at point: CGPoint, size: CGFloat, bold: Bool = false, color: NSColor = .black) {
    (string as NSString).draw(at: point, withAttributes: [.font: font(size, bold: bold), .foregroundColor: color])
}

func save(_ rep: NSBitmapImageRep, as type: NSBitmapImageRep.FileType) {
    try! rep.representation(using: type, properties: type == .jpeg ? [.compressionFactor: 0.92] : [:])!.write(to: out)
}

switch command {
case "screenshot":
    // A macOS-style window: title bar with traffic lights, then the lines, the first one large.
    let lines = Array(args.dropFirst(3))
    let rep = bitmap(1440, 900) { ctx in
        NSColor(white: 0.93, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1440, height: 900))
        NSColor.white.setFill(); NSBezierPath(roundedRect: CGRect(x: 120, y: 80, width: 1200, height: 720), xRadius: 14, yRadius: 14).fill()
        NSColor(white: 0.86, alpha: 1).setFill(); ctx.fill(CGRect(x: 120, y: 744, width: 1200, height: 56))
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill(); NSBezierPath(ovalIn: CGRect(x: 144 + i * 26, y: 764, width: 16, height: 16)).fill()
        }
        text(args[2], at: CGPoint(x: 560, y: 758), size: 20, bold: true, color: .darkGray)
        var y: CGFloat = 660
        for (i, line) in lines.enumerated() {
            text(line, at: CGPoint(x: 180, y: y), size: i == 0 ? 40 : 28, bold: i == 0)
            y -= i == 0 ? 80 : 56
        }
    }
    save(rep, as: .png)

case "card":
    let lines = Array(args.dropFirst(2))
    let rep = bitmap(1200, 760) { ctx in
        NSColor(red: 0.86, green: 0.9, blue: 0.97, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 760))
        NSColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 640, width: 1200, height: 120))
        NSColor(white: 0.75, alpha: 1).setFill(); ctx.fill(CGRect(x: 60, y: 160, width: 260, height: 320))   // the photo
        var y: CGFloat = 680
        for (i, line) in lines.enumerated() {
            text(line, at: CGPoint(x: i < 2 ? 60 : 380, y: y), size: i < 2 ? 34 : 38, bold: i == 0 || i == 3,
                 color: i < 2 ? .white : .black)
            y -= i == 1 ? 140 : 70
        }
    }
    save(rep, as: .jpeg)

case "pdf", "scan":
    // A4 pages. "pdf" draws real text; "scan" draws the text into a slightly grey, tilted picture first, so the
    // PDF holds only an image (as a scanner makes it).
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let pdf = CGContext(out as CFURL, mediaBox: &box, nil)!
    let pages = command == "pdf" ? Array(args.dropFirst(2)) : [args.dropFirst(2).joined(separator: "\n")]
    for page in pages {
        pdf.beginPDFPage(nil)
        if command == "pdf" {
            let attributed = NSAttributedString(string: page, attributes: [.font: font(13)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
                                                 CGPath(rect: box.insetBy(dx: 60, dy: 70), transform: nil), nil)
            CTFrameDraw(frame, pdf)
        } else {
            let rep = bitmap(1240, 1754) { ctx in
                NSColor(white: 0.96, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1240, height: 1754))
                ctx.rotate(by: 0.012)
                var y: CGFloat = 1550
                for (i, line) in page.split(separator: "\n").enumerated() {
                    text(String(line), at: CGPoint(x: 180, y: y), size: i == 0 ? 52 : 38, bold: i == 0, color: NSColor(white: 0.12, alpha: 1))
                    y -= 72
                }
            }
            pdf.draw(rep.cgImage!, in: box)
        }
        pdf.endPDFPage()
    }
    pdf.closePDF()

case "concat":
    // One slot length for all, one per file, or "auto": back to back with a 0.5 s pause, and each part's start and
    // end written to <out>.segments.json (for eval queries like "radio-show.m4a@seg3").
    let auto = args[2] == "auto"
    let slots = auto ? [] : args[2].split(separator: ",").map { Double($0)! }
    var segments: [[Double]] = []
    let composition = AVMutableComposition()
    let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    var at = CMTime.zero
    for (n, path) in args.dropFirst(3).enumerated() {
        let seconds = auto ? AVURLAsset(url: URL(fileURLWithPath: path)).duration.seconds + 0.5
                           : (slots.count == 1 ? slots[0] : slots[n])
        if auto { segments.append([at.seconds, at.seconds + seconds - 0.5]) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let source = asset.tracks(withMediaType: .audio)[0]
        let length = min(asset.duration, CMTime(seconds: seconds, preferredTimescale: 600))
        try! track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: at)
        at = at + CMTime(seconds: seconds, preferredTimescale: 600)   // the rest of the slot stays silent
    }
    if at > composition.duration {
        track.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: at - composition.duration))
    }
    try? FileManager.default.removeItem(at: out)
    let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)!
    export.outputURL = out
    export.outputFileType = .m4a
    let done = DispatchSemaphore(value: 0)
    export.exportAsynchronously { done.signal() }
    done.wait()
    guard export.status == .completed else { print("export failed: \(String(describing: export.error))"); exit(1) }
    if auto {
        let rounded = segments.map { $0.map { ($0 * 10).rounded() / 10 } }
        try! JSONSerialization.data(withJSONObject: rounded).write(to: URL(fileURLWithPath: out.path + ".segments.json"))
    }

case "video":
    let audio = args[2]
    let scenes = args.dropFirst(3).map { item -> (CGImage, Int) in
        let parts = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let image = NSImage(contentsOfFile: String(parts[0]))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return (image, Int(parts[1])!)
    }
    let silent = out.deletingLastPathComponent().appendingPathComponent(".silent-\(UUID().uuidString).mov")
    let width = 960, height = 540
    let writer = try! AVAssetWriter(outputURL: silent, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    var second = 0
    for (image, length) in scenes {
        for _ in 0..<length {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            ctx.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 1))
            second += 1
        }
    }
    input.markAsFinished()
    let total = CMTime(value: CMTimeValue(second), timescale: 1)
    writer.endSession(atSourceTime: total)
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }; done.wait()

    let composition = AVMutableComposition()
    let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    // The assets are kept in variables: a track whose asset is freed can't be inserted (-12780).
    let framesAsset = AVURLAsset(url: silent)
    let frames = framesAsset.tracks(withMediaType: .video)[0]
    try! video.insertTimeRange(frames.timeRange, of: frames, at: .zero)
    let soundAsset = audio == "-" ? nil : AVURLAsset(url: URL(fileURLWithPath: audio))
    if let soundAsset {
        let sound = soundAsset.tracks(withMediaType: .audio)[0]
        let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let length = min(sound.timeRange.duration, frames.timeRange.duration)
        try! track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: sound, at: .zero)
    }
    try? FileManager.default.removeItem(at: out)
    let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
    export.outputURL = out
    export.outputFileType = .mov
    export.exportAsynchronously { done.signal() }
    done.wait()
    try? FileManager.default.removeItem(at: silent)
    guard export.status == .completed else { print("export failed: \(String(describing: export.error))"); exit(1) }

default:
    print("unknown command \(command)")
    exit(2)
}
