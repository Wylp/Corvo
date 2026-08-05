import AppKit

// Renders a macOS app icon set from one square source image.
//
// macOS icons are not full-bleed squares: the art sits in an 824pt square inside
// a 1024pt canvas, clipped to the rounded-rect "squircle". Handing the system a
// bleeding square makes the icon read as bigger and boxier than every neighbour
// in the Dock.

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon <source.png> <output-dir>\n".utf8))
    exit(2)
}
let source = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let src = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("cannot read \(source.path)\n".utf8))
    exit(1)
}

let canvas: CGFloat = 1024
let art: CGFloat = 824                 // Apple's content square inside the canvas
let radius: CGFloat = art * 0.2237     // the macOS squircle, close enough at every size

/// The square region of the source that actually holds the subject.
///
/// Source art usually carries its own margin. Nesting that inside the 824pt
/// content square doubles it, and the subject ends up filling barely half the
/// icon — invisible at the 16pt the Finder list uses. So we find the subject and
/// re-frame on it, rather than trusting the file's framing.
func subjectBox(_ image: NSImage) -> NSRect {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        return NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    // The plate colour, sampled from a corner. Everything close to it is background.
    let plate = rep.colorAt(x: 0, y: 0) ?? .black
    let (pr, pg, pb) = (plate.redComponent, plate.greenComponent, plate.blueComponent)

    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            // Transparent pixels are background too, whatever their colour claims.
            guard c.alphaComponent > 0.1 else { continue }
            let d = abs(c.redComponent - pr) + abs(c.greenComponent - pg)
                  + abs(c.blueComponent - pb)
            guard d > 0.12 else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard minX < maxX, minY < maxY else {
        return NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
    }

    // Squared off around the subject's centre, so re-framing never distorts it.
    let side = CGFloat(max(maxX - minX, maxY - minY))
    let cx = CGFloat(minX + maxX) / 2
    // colorAt counts rows from the top; NSImage draws from the bottom.
    let cy = CGFloat(h) - CGFloat(minY + maxY) / 2
    return NSRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
}

/// The master: subject re-framed in the canvas and clipped to the icon shape.
func master() -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = (canvas - art) / 2
    let box = NSRect(x: inset, y: inset, width: art, height: art)
    NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).addClip()

    // The plate fills the whole shape; the subject is drawn over it at a size
    // that reads at 16pt. 0.78 leaves the corners clear of the rounding.
    (src.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
        .colorAt(x: 0, y: 0) ?? .black).setFill()
    NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()

    let subject = subjectBox(src)
    let side = art * 0.78
    let target = NSRect(x: (canvas - side) / 2, y: (canvas - side) / 2,
                        width: side, height: side)
    src.draw(in: target, from: subject, operation: .sourceOver, fraction: 1)

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, side: Int) -> Data? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep else { return nil }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// point size → scale, the ten entries a macOS app icon set expects
let wanted: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let base = master()

var entries: [String] = []
for (pt, scale) in wanted {
    let side = pt * scale
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    guard let data = png(base, side: side) else {
        FileHandle.standardError.write(Data("failed rendering \(name)\n".utf8))
        exit(1)
    }
    try! data.write(to: outDir.appendingPathComponent(name))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(pt)x\(pt)"
        }
    """)
    print("\(name)  \(side)×\(side)")
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try! contents.write(to: outDir.appendingPathComponent("Contents.json"),
                    atomically: true, encoding: .utf8)
print("Contents.json")
