#!/usr/bin/env swift
// Renders Enka/Assets.xcassets/AppIcon.appiconset from code — no design tool
// in the loop, same as the Mac's Scripts/make-icon.swift.
// Usage: swift Scripts/make-icon.swift <AppIcon.appiconset>
//
// Three cards fanned out, in the clay both other clients use, on the same warm
// near-black. The Mac's icon is two cards lying flat with the notch cut into
// the top edge, because that is where the Mac app lives; a phone has no notch
// to point at, so the cards stand upright — the way one is held on the phone —
// and a third joins the fan, because what the phone shows is a queue.
import AppKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Enka/Assets.xcassets/AppIcon.appiconset"
let out = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The clay accent, `--accent` in the web client's tokens.
func clay(_ alpha: CGFloat) -> CGColor {
    CGColor(red: 0.851, green: 0.467, blue: 0.341, alpha: alpha)
}

func draw(size s: CGFloat) -> NSBitmapImageRep {
    let px = Int(s)
    // Drawn without an alpha channel: an iOS icon is a full-bleed opaque
    // square, and the system is what rounds it.
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let k = s / 1024  // everything below is authored on a 1024 canvas
    let body = CGRect(x: 0, y: 0, width: s, height: s)

    // The warm near-black of the web client's `--bg`, not a neutral grey,
    // lifted a little at the top so the square has a direction.
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.20, green: 0.19, blue: 0.18, alpha: 1),
            CGColor(red: 0.07, green: 0.065, blue: 0.06, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )

    func card(_ rect: CGRect, radius: CGFloat, fill: CGColor, rotation: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: rotation)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // The fan. The two behind lean opposite ways and are dimmed rather than
    // outlined, so at 40pt the shape stays one silhouette instead of three.
    let cw = 440 * k, ch = 580 * k
    let front = CGRect(x: body.midX - cw / 2, y: body.midY - ch / 2, width: cw, height: ch)
    card(front.offsetBy(dx: 0, dy: 40 * k), radius: 58 * k, fill: clay(0.24), rotation: 0.19)
    card(front.offsetBy(dx: 0, dy: 20 * k), radius: 58 * k, fill: clay(0.44), rotation: -0.19)
    card(front, radius: 58 * k, fill: clay(1), rotation: 0)

    // Two lines of "writing" on the front card: a term, and a shorter meaning.
    ctx.setFillColor(CGColor(red: 0.10, green: 0.08, blue: 0.07, alpha: 0.72))
    let lineH = 38 * k
    for (index, width) in [(0, 260 * k), (1, 170 * k)] {
        let y = body.midY + 46 * k - CGFloat(index) * (lineH + 42 * k)
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: body.midX - width / 2, y: y, width: width, height: lineH),
            cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil
        ))
    }
    ctx.fillPath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!)
}

// One 1024 image; Xcode derives every size the system asks for from it.
let png = draw(size: 1024).representation(using: .png, properties: [:])!
try png.write(to: out.appendingPathComponent("AppIcon-1024.png"))

let contents = """
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "make-icon.swift",
    "version" : 1
  }
}

"""
try contents.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(outPath)")
