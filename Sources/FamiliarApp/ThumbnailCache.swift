import AVFoundation
import AppKit
import PDFKit
import QuickLookThumbnailing
import FamiliarCore
import SwiftUI

/// ThumbnailCache that show the match: the PDF page, the video frame at its moment, the picture itself; Quick Look's
/// thumbnail or the file's icon otherwise.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for result: SearchResult, side: CGFloat) async -> NSImage {
        let key = "\(result.path)#\(result.segmentKind.rawValue)#\(result.locator)#\(Int(side))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let pixels = side * (NSScreen.main?.backingScaleFactor ?? 2)
        let url = result.url
        var image: NSImage?
        if let page = result.page {
            image = await Task.detached { Self.pdfPage(url, page: page, side: pixels) }.value
        } else if result.segmentKind == .frame, let seconds = result.seconds {
            image = await Self.videoFrame(url, at: seconds, side: pixels)
        }
        if image == nil {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        let final = image ?? NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(final, forKey: key)
        return final
    }

    nonisolated private static func pdfPage(_ url: URL, page index: Int, side: CGFloat) -> NSImage? {
        guard let page = PDFDocument(url: url)?.page(at: index) else { return nil }
        return page.thumbnail(of: CGSize(width: side, height: side), for: .cropBox)
    }

    private static func videoFrame(_ url: URL, at seconds: Double, side: CGFloat) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side * 1.6, height: side * 1.6)
        guard let (cg, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct ThumbnailView: View {
    let result: SearchResult
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.primary.opacity(0.06)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if result.fileKind == .audio || result.fileKind == .video {
                Image(systemName: result.fileKind == .audio ? "waveform" : "play.fill")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .padding(3).background(Circle().fill(Color.black.opacity(0.55))).padding(3)
            }
        }
        .task(id: result) { image = await ThumbnailCache.shared.image(for: result, side: size) }
    }
}
