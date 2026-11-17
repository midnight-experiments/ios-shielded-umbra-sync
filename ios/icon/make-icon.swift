// Draws the app icon: a shield over a grid of records, one of them lit, the record a private retrieval reads without
// the server seeing which. Writes the 1024 × 1024 opaque PNG of the asset catalog:
//
//   swift icon/make-icon.swift            (from ios/)

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Top-left origin, y down.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// Background: midnight blue, lighter at the top.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x1C2A6B), rgb(0x0A0F2E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])

// A soft glow behind the shield.
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x4F6BFF, 0.35), rgb(0x4F6BFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 480), startRadius: 0, endCenter: CGPoint(x: 512, y: 480), endRadius: 470, options: [])

// The shield.
func shield(inset d: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let left = 232 + d, right = 792 - d, top = 196 + d, bottom = 868 - d * 1.4
    p.move(to: CGPoint(x: 512, y: top))
    p.addCurve(to: CGPoint(x: right, y: top + 78), control1: CGPoint(x: 600, y: top + 52), control2: CGPoint(x: 700, y: top + 72))
    p.addLine(to: CGPoint(x: right, y: 500))
    p.addCurve(to: CGPoint(x: 512, y: bottom), control1: CGPoint(x: right, y: 680), control2: CGPoint(x: 660, y: bottom - 80))
    p.addCurve(to: CGPoint(x: left, y: 500), control1: CGPoint(x: 364, y: bottom - 80), control2: CGPoint(x: left, y: 680))
    p.addLine(to: CGPoint(x: left, y: top + 78))
    p.addCurve(to: CGPoint(x: 512, y: top), control1: CGPoint(x: 324, y: top + 72), control2: CGPoint(x: 424, y: top + 52))
    p.closeSubpath()
    return p
}

ctx.saveGState()
ctx.addPath(shield(inset: 0))
ctx.clip()
let face = CGGradient(colorsSpace: space, colors: [rgb(0x3B4FD8), rgb(0x1A2470)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(face, start: CGPoint(x: 512, y: 196), end: CGPoint(x: 512, y: 868), options: [])
ctx.restoreGState()

ctx.addPath(shield(inset: 0))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.92))
ctx.setLineWidth(30)
ctx.setLineJoin(.round)
ctx.strokePath()

// The table: 3 × 3 records, one lit.
let cell: CGFloat = 92, gap: CGFloat = 26
let gridX = 512 - (3 * cell + 2 * gap) / 2, gridY: CGFloat = 340
for r in 0..<3 {
    for c in 0..<3 {
        let rect = CGRect(x: gridX + CGFloat(c) * (cell + gap), y: gridY + CGFloat(r) * (cell + gap), width: cell, height: cell)
        let path = CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil)
        ctx.addPath(path)
        if r == 1 && c == 2 {
            ctx.setFillColor(rgb(0x3EE6C1))
            ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x3EE6C1, 0.9))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        } else {
            ctx.setFillColor(rgb(0xFFFFFF, 0.78))
            ctx.fillPath()
        }
    }
}

let image = ctx.makeImage()!
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
print("wrote \(out.path)")
