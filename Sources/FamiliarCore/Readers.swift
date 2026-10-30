import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// A piece of text to embed and keyword-index, with where it is in its file.
public struct TextPiece: Sendable {
    public var text: String
    public var locator: Double
    public var kind: SegmentKind
}

public enum ReadError: LocalizedError {
    case unreadable(String)
    public var errorDescription: String? {
        if case .unreadable(let why) = self { return why }
        return nil
    }
}

// MARK: - Text

public enum TextReader {
    /// Chunks of about `size` characters, broken at paragraph or sentence ends, overlapping a little so a passage
    /// that spans a break is still found.
    public static func chunks(_ text: String, size: Int = 1400, overlap: Int = 150, limit: Int = 400) -> [(String, Int)] {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let chars = Array(text)
        var out: [(String, Int)] = []
        var start = 0
        while start < chars.count && out.count < limit {
            var end = min(start + size, chars.count)
            if end < chars.count {
                // Prefer a paragraph break, then a sentence end, then a space, in the last third of the window.
                let floor = start + size * 2 / 3
                if let p = (floor..<end).reversed().first(where: { chars[$0] == "\n" && $0 > 0 && chars[$0 - 1] == "\n" }) {
                    end = p
                } else if let s = (floor..<end).reversed().first(where: { ".!?。\n".contains(chars[$0]) }) {
                    end = s + 1
                } else if let w = (floor..<end).reversed().first(where: { chars[$0] == " " }) {
                    end = w
                }
            }
            let piece = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.count > 3 { out.append((piece, start)) }
            if end >= chars.count { break }
            start = max(end - overlap, start + 1)
        }
        return out
    }

    public static func read(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) { return text }
        throw ReadError.unreadable("unknown text encoding")
    }

    /// Text that's mostly digits and punctuation (a data export, a log of numbers) means little to an embedding:
    /// such text is matched by its exact words only.
    public static func isMostlyNumbers(_ text: String) -> Bool {
        let sample = text.prefix(4000)
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return sample.count > 200 && Double(letters) / Double(sample.count) < 0.35
    }
}

/// Word, RTF, OpenDocument, HTML and web archives, through macOS's `textutil` (in its own process, so a broken file
/// can't take the app down).
public enum DocumentReader {
    public static func read(_ url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pages" { return try PackageText.pages(url) }
        let output = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", "-noload", "-nostore", url.path])
        return output
    }
}

/// xlsx, pptx, ods, odp: zip files of XML. Their text is pulled out of the XML: each slide's text and notes, each
/// sheet's strings.
public enum OfficeReader {
    public static func read(_ url: URL) throws -> [TextPiece] {
        let ext = url.pathExtension.lowercased()
        if ext == "key" || ext == "numbers" { return [TextPiece(text: try PackageText.iwork(url), locator: 0, kind: .text)] }
        let entries = try run("/usr/bin/unzip", ["-Z1", url.path]).split(separator: "\n").map(String.init)
        func xmlText(_ entry: String) -> String {
            guard let xml = try? run("/usr/bin/unzip", ["-p", url.path, entry]) else { return "" }
            return stripXML(xml)
        }
        switch ext {
        case "pptx":
            let slides = entries.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { number(in: $0) < number(in: $1) }
            return slides.map { entry in
                let n = number(in: entry)
                let notes = entries.contains("ppt/notesSlides/notesSlide\(n).xml") ? xmlText("ppt/notesSlides/notesSlide\(n).xml") : ""
                return TextPiece(text: "Slide \(n). " + xmlText(entry) + (notes.isEmpty ? "" : " Notes: \(notes)"),
                                 locator: Double(n - 1), kind: .text)
            }
        case "xlsx":
            var text = ""
            if entries.contains("xl/workbook.xml") { text += "Sheets: " + xmlText("xl/workbook.xml") + "\n" }
            if entries.contains("xl/sharedStrings.xml") { text += xmlText("xl/sharedStrings.xml") }
            return [TextPiece(text: text, locator: 0, kind: .text)]
        default:   // ods, odp
            return [TextPiece(text: entries.contains("content.xml") ? xmlText("content.xml") : "", locator: 0, kind: .text)]
        }
    }

    static func number(in entry: String) -> Int {
        Int(entry.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0
    }

    static func stripXML(_ xml: String) -> String {
        var text = xml.replacingOccurrences(of: "</a:p>", with: "\n").replacingOccurrences(of: "</text:p>", with: "\n")
            .replacingOccurrences(of: "</si>", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        return text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }
}

/// Pages, Keynote and Numbers files: their text isn't readable without Apple's private formats, but each holds a
/// preview PDF or image. The preview PDF's text is used when there is one.
enum PackageText {
    static func pages(_ url: URL) throws -> String { try iwork(url) }

    static func iwork(_ url: URL) throws -> String {
        let pdf = url.appendingPathComponent("QuickLook/Preview.pdf")
        if let document = PDFDocument(url: pdf), let text = document.string, !text.isEmpty { return text }
        if let entries = try? run("/usr/bin/unzip", ["-Z1", url.path]), entries.contains("QuickLook/Preview.pdf") {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let data = try runData("/usr/bin/unzip", ["-p", url.path, "QuickLook/Preview.pdf"])
            try data.write(to: tmp)
            if let document = PDFDocument(url: tmp), let text = document.string { return text }
        }
        throw ReadError.unreadable("no text preview inside")
    }
}

// MARK: - PDF

public enum PDFReader {
    public struct Page {
        public let index: Int
        public let text: String
        /// For a page with no text layer (a scan): the page as a picture.
        public let image: Data?
        public let ocr: String?
    }

    public static let maxPages = 1000

    public static func read(_ url: URL) throws -> (pages: [Page], title: String?) {
        guard let document = PDFDocument(url: url) else { throw ReadError.unreadable("not a readable PDF") }
        if document.isLocked { throw ReadError.unreadable("the PDF is password protected") }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        var pages: [Page] = []
        for index in 0..<min(document.pageCount, maxPages) {
            autoreleasepool {
                guard let page = document.page(at: index) else { return }
                let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= 40 {
                    pages.append(Page(index: index, text: text, image: nil, ocr: nil))
                } else if let cg = render(page) {
                    let ocr = TextRecognizer.recognize(cg)
                    let image = ImagePrep.encode(cg, budget: ImageBudgets.current.page)
                    pages.append(Page(index: index, text: text, image: image, ocr: ocr))
                }
            }
        }
        return (pages, title)
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 1600 / max(bounds.width, bounds.height)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Images

public enum ImagePrep {
    /// Loads an image, downscaled so its long side is at most `maxSide` (HEIC, RAW, WebP and the rest through ImageIO),
    /// with its orientation applied.
    public static func load(_ url: URL, maxSide: Int = 1600) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// The type of what `encode` makes.
    public static let mime = "image/jpeg"
    /// How large a picture is loaded before resizing.
    public static let loadSide = 1600

    /// A screenshot: macOS marks the ones it takes (and some tools do too), and their names say so. They're sent with
    /// more detail than photos, since they're mostly text.
    public static func isScreenshot(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.hasPrefix("cleanshot")
            || name.contains("screen capture") || name.hasPrefix("simulator screen")
    }

    /// The size the model's image processor scales to for `budget` soft tokens (each 3 × 3 patches of 16 px), keeping
    /// the aspect ratio, each side a multiple of 48 px. Sized here so llama.cpp takes the picture as it is.
    static func targetSize(width: Int, height: Int, budget: Int) -> (Int, Int) {
        let patch = 16.0, pooling = 3.0, side = 48.0
        let maxPatches = Double(budget) * pooling * pooling
        let factor = (maxPatches * patch * patch / Double(width * height)).squareRoot()
        var w = (factor * Double(width) / side).rounded(.down) * side
        var h = (factor * Double(height) / side).rounded(.down) * side
        w = max(w, side); h = max(h, side)
        return (Int(w), Int(h))
    }

    /// The picture resized for `budget` tokens and encoded as JPEG (70: a thumbnail's worth, 280: the default,
    /// 560 and 1120 for more detail).
    public static func encode(_ image: CGImage, budget: Int) -> Data? {
        let (w, h) = targetSize(width: image.width, height: image.height, budget: budget)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))   // transparent PNGs on white
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let resized = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, resized, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

}

/// Apple's Vision text recognition, for screenshots and scanned pages.
public enum TextRecognizer {
    public static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // it "corrects" ID numbers and codes into words
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return nil }
        let text = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

// MARK: - Processes

@discardableResult
func run(_ tool: String, _ arguments: [String]) throws -> String {
    String(decoding: try runData(tool, arguments), as: UTF8.self)
}

func runData(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    guard process.terminationStatus == 0 else {
        throw ReadError.unreadable("\((tool as NSString).lastPathComponent) couldn't read it")
    }
    return data
}
