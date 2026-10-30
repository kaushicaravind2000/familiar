import AppKit

// Draws the app icon (1024 px): Familiar's black cat, the companion that lives with you, drawn flat and simple in
// the style of macOS's own icons: a wide head with two rounded ears and amber eyes, on a night-blue squircle.
// Usage: swift scripts/make-icon.swift <out.png>
let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: a) }

// Background squircle with the macOS icon grid's margins, a quiet top-to-bottom gradient.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()
squircle.addClip()
NSGradient(colors: [rgb(0.36, 0.30, 0.82), rgb(0.20, 0.17, 0.52)])!.draw(in: rect, angle: -90)

// The head: one shape, a wide rounded face with two ears whose tips are rounded.
let head = NSBezierPath()
head.move(to: CGPoint(x: 512, y: 236))                                                            // chin
head.curve(to: CGPoint(x: 236, y: 500), controlPoint1: CGPoint(x: 330, y: 236), controlPoint2: CGPoint(x: 236, y: 350))
head.curve(to: CGPoint(x: 268, y: 640), controlPoint1: CGPoint(x: 236, y: 560), controlPoint2: CGPoint(x: 248, y: 604))
head.line(to: CGPoint(x: 284, y: 796))                                                            // left ear, outer edge
head.curve(to: CGPoint(x: 330, y: 812), controlPoint1: CGPoint(x: 288, y: 826), controlPoint2: CGPoint(x: 312, y: 830))
head.line(to: CGPoint(x: 438, y: 706))                                                            // left ear, inner edge
head.curve(to: CGPoint(x: 586, y: 706), controlPoint1: CGPoint(x: 486, y: 720), controlPoint2: CGPoint(x: 538, y: 720))
head.line(to: CGPoint(x: 694, y: 812))                                                            // right ear, inner edge
head.curve(to: CGPoint(x: 740, y: 796), controlPoint1: CGPoint(x: 712, y: 830), controlPoint2: CGPoint(x: 736, y: 826))
head.line(to: CGPoint(x: 756, y: 640))                                                            // right ear, outer edge
head.curve(to: CGPoint(x: 788, y: 500), controlPoint1: CGPoint(x: 776, y: 604), controlPoint2: CGPoint(x: 788, y: 560))
head.curve(to: CGPoint(x: 512, y: 236), controlPoint1: CGPoint(x: 788, y: 350), controlPoint2: CGPoint(x: 694, y: 236))
head.close()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
rgb(0.09, 0.08, 0.16).setFill()
head.fill()
ctx.restoreGState()

// The eyes: flat amber almonds with slit pupils.
for cx in [CGFloat(410), 614] {
    let eye = NSBezierPath()
    eye.move(to: CGPoint(x: cx - 66, y: 490))
    eye.curve(to: CGPoint(x: cx + 66, y: 490), controlPoint1: CGPoint(x: cx - 34, y: 562), controlPoint2: CGPoint(x: cx + 34, y: 562))
    eye.curve(to: CGPoint(x: cx - 66, y: 490), controlPoint1: CGPoint(x: cx + 34, y: 418), controlPoint2: CGPoint(x: cx - 34, y: 418))
    eye.close()
    NSGradient(colors: [rgb(1, 0.84, 0.40), rgb(1, 0.72, 0.22)])!.draw(in: eye, angle: -90)
    rgb(0.09, 0.08, 0.16).setFill()
    NSBezierPath(roundedRect: CGRect(x: cx - 12, y: 444, width: 24, height: 92), xRadius: 12, yRadius: 12).fill()
}

// The nose.
let nose = NSBezierPath()
nose.move(to: CGPoint(x: 488, y: 398))
nose.curve(to: CGPoint(x: 536, y: 398), controlPoint1: CGPoint(x: 504, y: 404), controlPoint2: CGPoint(x: 520, y: 404))
nose.curve(to: CGPoint(x: 488, y: 398), controlPoint1: CGPoint(x: 524, y: 372), controlPoint2: CGPoint(x: 500, y: 372))
nose.close()
rgb(0.93, 0.60, 0.72).setFill()
nose.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
