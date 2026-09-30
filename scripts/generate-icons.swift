// Generates every icon and logo file of iOS Developer Toolkit (Swift) from one source image.
//
//   xcrun swift scripts/generate-icons.swift [docs/brand/logo-source.png]
//
// The source is the rounded-square logo with transparent corners. Writes:
//   App/iOSDeveloperToolkit/Assets.xcassets/AppIcon.appiconset/icon_{16…1024}.png
//       the app icon (Dock, Finder, About), on Apple's macOS icon grid: the tile is 824/1024 of
//       the canvas, centered, so it matches the size of other apps in the Dock
//   App/iOSDeveloperToolkit/Assets.xcassets/Logo.imageset/logo.png   the tile edge to edge (1024)
//   docs/brand/icon-1024.png, docs/brand/iOSDeveloperToolkitSwift.icns   the app icon as files
//   docs/brand/logo-1024.png, docs/brand/logo-512.png                 the logo edge to edge
//   docs/brand/logo.svg          the logo as SVG (the 512-pixel logo embedded in a clipped SVG)
//   docs/brand/social-preview.png  1280×640 image for the repository's social preview
// The tile's interior is made fully opaque (the source is slightly translucent, which shows as
// grey patches on light backgrounds); the anti-aliased edge keeps its transparency.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-icons: \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/brand/logo-source.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(sourceURL.path)") }
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ width: Int, _ height: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
    context.interpolationQuality = .high
    return context
}

// 1. Read the pixels, find the tile, and make its interior opaque.
let width = original.width, height = original.height
let reader = context(width, height)
reader.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
let pixels = reader.data!.bindMemory(to: UInt8.self, capacity: reader.bytesPerRow * height)
let stride = reader.bytesPerRow
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where pixels[y * stride + x * 4 + 3] > 64 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { fail("the source has no visible tile") }
var translucent = 0
for y in minY...maxY {
    for x in minX...maxX {
        let i = y * stride + x * 4
        let alpha = Int(pixels[i + 3])
        guard alpha > 0, alpha < 255 else { continue }
        // Interior pixels (nearly opaque) become opaque; edge pixels are scaled up slightly.
        let target = alpha >= 200 ? 255 : min(255, alpha * 255 / 252)
        if alpha < 200 && x > minX + 40 && x < maxX - 40 && y > minY + 40 && y < maxY - 40 { translucent += 1 }
        for channel in 0..<3 {
            let straight = Int(pixels[i + channel]) * 255 / alpha
            pixels[i + channel] = UInt8(min(255, straight * target / 255))
        }
        pixels[i + 3] = UInt8(target)
    }
}
if translucent > 0 { print("note: \(translucent) clearly translucent pixels inside the tile were kept as they are") }
let fixed = reader.makeImage()!
// Core Graphics' origin is bottom-left; the crop rectangle uses image (top-left) coordinates.
guard let tile = fixed.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { fail("crop failed") }
print("tile: \(tile.width)×\(tile.height) at (\(minX), \(minY)) in a \(width)×\(height) source")

// 2. Renderers.
func render(_ size: Int, tileScale: CGFloat) -> CGImage {
    let canvas = context(size, size)
    let side = CGFloat(size) * tileScale
    let aspect = CGFloat(tile.width) / CGFloat(tile.height)
    let rect = CGRect(x: (CGFloat(size) - side * min(1, aspect)) / 2, y: (CGFloat(size) - side / max(1, aspect)) / 2,
                      width: side * min(1, aspect), height: side / max(1, aspect))
    canvas.draw(tile, in: rect)
    return canvas.makeImage()!
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { fail("no PNG encoder") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("PNG encoding failed") }
    return data as Data
}

func write(_ image: CGImage, to path: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try pngData(image).write(to: url, options: .atomic) } catch { fail("cannot write \(path): \(error)") }
    print("wrote \(path) (\(image.width)×\(image.height))")
}

// Apple's macOS icon grid: an 824-point body on a 1024-point canvas.
let gridScale: CGFloat = 824.0 / 1024.0

// 3. App icon, logo, and brand files.
let appIcon = "App/iOSDeveloperToolkit/Assets.xcassets/AppIcon.appiconset"
for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(render(size, tileScale: gridScale), to: "\(appIcon)/icon_\(size).png")
}
write(render(1024, tileScale: 1), to: "App/iOSDeveloperToolkit/Assets.xcassets/Logo.imageset/logo.png")
write(render(1024, tileScale: gridScale), to: "docs/brand/icon-1024.png")
write(render(1024, tileScale: 1), to: "docs/brand/logo-1024.png")
let logo512 = render(512, tileScale: 1)
write(logo512, to: "docs/brand/logo-512.png")

// .icns through iconutil (Apple's tool), from a temporary .iconset.
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("idt-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                     ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try? pngData(render(size, tileScale: gridScale)).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("docs/brand/iOSDeveloperToolkitSwift.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
print("wrote docs/brand/iOSDeveloperToolkitSwift.icns")

// SVG: the logo embedded as PNG, clipped to its rounded square so it scales cleanly anywhere.
let radius = Int((Double(512) * 0.235).rounded())
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="512" height="512" viewBox="0 0 512 512" role="img" aria-label="iOS Developer Toolkit (Swift)">
  <title>iOS Developer Toolkit (Swift)</title>
  <defs><clipPath id="tile"><rect width="512" height="512" rx="\(radius)" ry="\(radius)"/></clipPath></defs>
  <image width="512" height="512" clip-path="url(#tile)" xlink:href="data:image/png;base64,\(pngData(logo512).base64EncodedString())"/>
</svg>

"""
try Data(svg.utf8).write(to: root.appendingPathComponent("docs/brand/logo.svg"), options: .atomic)
print("wrote docs/brand/logo.svg")

// Social preview (GitHub recommends 1280×640): the logo and the name on the logo's own dark blue.
let social = context(1280, 640)
social.setFillColor(CGColor(srgbRed: 0.075, green: 0.094, blue: 0.125, alpha: 1))
social.fill(CGRect(x: 0, y: 0, width: 1280, height: 640))
social.draw(render(420, tileScale: 1), in: CGRect(x: 110, y: 110, width: 420, height: 420))
func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, at point: CGPoint) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!]))
    social.textPosition = point
    CTLineDraw(line, social)
}
let white = CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1)
let grey = CGColor(srgbRed: 0.62, green: 0.68, blue: 0.76, alpha: 1)
drawText("iOS Developer", size: 64, weight: .bold, color: white, at: CGPoint(x: 590, y: 372))
drawText("Toolkit (Swift)", size: 64, weight: .bold, color: white, at: CGPoint(x: 590, y: 292))
drawText("A native macOS app and CLI for iPhone, iPad,", size: 26, weight: .regular, color: grey, at: CGPoint(x: 592, y: 226))
drawText("and simulators.", size: 26, weight: .regular, color: grey, at: CGPoint(x: 592, y: 190))
write(social.makeImage()!, to: "docs/brand/social-preview.png")
