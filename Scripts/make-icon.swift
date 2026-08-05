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

// MARK: - Menu bar

// The status item is a different animal from the app icon: it has to be a
// template image, a silhouette in alpha only. macOS paints it — dark on a light
// menu bar, light on a dark one, inverted while the menu is open. Ship the
// colour artwork there instead and it is stuck in one colour, invisible against
// half the menu bars it will ever sit on.

let menuDir = outDir.deletingLastPathComponent()
    .appendingPathComponent("MenuBarIcon.imageset")
try? FileManager.default.createDirectory(at: menuDir, withIntermediateDirectories: true)

/// The subject as an alpha mask: how far each pixel stands off the plate becomes
/// how opaque it is, so the edges stay antialiased instead of stair-stepped.
///
/// Reads with `colorAt`, the path `subjectBox` already proves works, and writes
/// straight into the output buffer. `setColor(atX:y:)` is the tempting way to
/// write and it silently does nothing on some bitmap formats.
func silhouette(side: Int) -> Data? {
    guard let tiff = src.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32),
          let pixels = out.bitmapData
    else { return nil }

    let plate = rep.colorAt(x: 0, y: 0) ?? .black
    let plateLuma = plate.redComponent * 0.299 + plate.greenComponent * 0.587
                  + plate.blueComponent * 0.114

    // Tighter than the app icon: the menu bar gives ~18pt of height and no plate
    // to sit on, so the silhouette uses nearly all of it.
    let floorD = 0.045   // below this, background noise
    let ceilD = 0.12     // above this, unambiguously the subject
    let pad = CGFloat(side) * 0.06
    let span = CGFloat(side) - pad * 2
    let box = subjectBox(src)
    let h = CGFloat(rep.pixelsHigh)

    for y in 0..<side {
        for x in 0..<side {
            var coverage = 0.0
            let u = (CGFloat(x) - pad) / span
            let v = (CGFloat(y) - pad) / span
            if u >= 0, u <= 1, v >= 0, v <= 1 {
                let sx = Int(box.minX + u * box.width)
                // colorAt counts rows from the top, subjectBox is in draw space.
                let sy = Int(h - (box.minY + (1 - v) * box.height))
                if sx >= 0, sx < rep.pixelsWide, sy >= 0, sy < rep.pixelsHigh,
                   let c = rep.colorAt(x: sx, y: sy), c.alphaComponent > 0.1 {
                    let luma = c.redComponent * 0.299 + c.greenComponent * 0.587
                             + c.blueComponent * 0.114
                    // A band, not a single threshold: the artwork's background
                    // carries a faint vignette, so one hard cut either speckles
                    // the noise into the mask or eats the darker feathers.
                    let d = abs(luma - plateLuma)
                    let t = min(1, max(0, (d - floorD) / (ceilD - floorD)))
                    coverage = t * t * (3 - 2 * t)   // smoothstep
                }
            }
            // Premultiplied: black in every channel, the shape lives in alpha.
            let i = (y * side + x) * 4
            pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
            pixels[i + 3] = UInt8(coverage * 255)
        }
    }
    return out.representation(using: .png, properties: [:])
}

var menuEntries: [String] = []
for scale in [1, 2, 3] {
    let side = 18 * scale
    let name = "menubar\(scale == 1 ? "" : "@\(scale)x").png"
    guard let data = silhouette(side: side) else { exit(1) }
    try! data.write(to: menuDir.appendingPathComponent(name))
    menuEntries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x"
        }
    """)
    print("MenuBarIcon/\(name)  \(side)×\(side)")
}

let menuContents = """
{
  "images" : [
\(menuEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}

"""
try! menuContents.write(to: menuDir.appendingPathComponent("Contents.json"),
                        atomically: true, encoding: .utf8)
print("MenuBarIcon/Contents.json")
