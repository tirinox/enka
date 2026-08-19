#!/usr/bin/env swift
// Renders Resources/AppIcon.icns from code — no design tool in the loop.
// Usage: swift Scripts/make-icon.swift <output.icns>
//
// Two cards, offset, in the same clay the panel uses; the notch is cut into the
// top edge so the icon says where the app lives.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Enka.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size s: CGFloat) -> NSBitmapImageRep {
    let px = Int(s)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 1024  // everything below is authored on a 1024 canvas

    // Rounded-square body, macOS proportions. The warm near-black of the web
    // client's `--bg`, not a neutral grey.
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
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

    // The notch, cut into the top edge.
    let notchW = 330 * k, notchH = 86 * k, r = 34 * k
    let nx = body.midX - notchW / 2, ny = body.maxY - notchH
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: nx, y: body.maxY))
    notch.addLine(to: CGPoint(x: nx, y: ny + r))
    notch.addQuadCurve(to: CGPoint(x: nx + r, y: ny), control: CGPoint(x: nx, y: ny))
    notch.addLine(to: CGPoint(x: nx + notchW - r, y: ny))
    notch.addQuadCurve(to: CGPoint(x: nx + notchW, y: ny + r), control: CGPoint(x: nx + notchW, y: ny))
    notch.addLine(to: CGPoint(x: nx + notchW, y: body.maxY))
    notch.closeSubpath()
    ctx.addPath(notch)
    ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1))
    ctx.fillPath()

    // Two cards. The back one is turned a little and dimmed — a stack, which is
    // what a collection looks like, rather than one card, which is what a
    // single flashcard app looks like.
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

    let cw = 460 * k, ch = 320 * k
    let cx = body.midX, cy = body.midY - 30 * k
    card(
        CGRect(x: cx - cw / 2, y: cy - ch / 2 + 34 * k, width: cw, height: ch),
        radius: 46 * k,
        fill: CGColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 0.38),
        rotation: -0.13
    )
    card(
        CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch),
        radius: 46 * k,
        fill: CGColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1),
        rotation: 0
    )

    // Two lines of "writing" on the front card: a term, and a shorter meaning.
    ctx.setFillColor(CGColor(red: 0.10, green: 0.08, blue: 0.07, alpha: 0.72))
    let lineH = 34 * k
    for (index, width) in [(0, 250 * k), (1, 160 * k)] {
        let y = cy + 34 * k - CGFloat(index) * (lineH + 40 * k)
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: cx - width / 2, y: y, width: width, height: lineH),
            cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil
        ))
        ctx.fillPath()
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (size, name) in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
] {
    let data = draw(size: CGFloat(size)).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outPath]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote \(outPath)" : "iconutil failed")
