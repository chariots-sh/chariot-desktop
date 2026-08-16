// Renders the Chariot Desktop app icon (1024pt) to PNG.
// Geometry: angular "C" of slanted bars — green accent top-left, orange
// accent bottom-right, white body — on a black squircle.
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let size = 1024.0
let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Flip to y-down coordinates.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// Background: squircle for macOS (.icns), full-bleed square for iOS asset
// catalogs (iOS applies its own mask; alpha corners render black there).
let squareMode = CommandLine.arguments.contains("--square")
let bg = squareMode
    ? CGPath(rect: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
    : CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
             cornerWidth: 230, cornerHeight: 230, transform: nil)
ctx.addPath(bg)
ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1))
ctx.fillPath()

let slope = 0.71  // leftward x shift per unit y down, shared by all slanted cuts

func quad(topLeftX: Double, topRightX: Double, topY: Double, bottomY: Double) -> CGPath {
    let shift = slope * (bottomY - topY)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: topLeftX, y: topY))
    path.addLine(to: CGPoint(x: topRightX, y: topY))
    path.addLine(to: CGPoint(x: topRightX - shift, y: bottomY))
    path.addLine(to: CGPoint(x: topLeftX - shift, y: bottomY))
    path.closeSubpath()
    return path
}

func fillGradient(_ path: CGPath, from: CGColor, to: CGColor, start: CGPoint, end: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [from, to] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: start, end: end,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

let white = CGColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)
let topY = 240.0, topBarBottom = 360.0
let barTopY = 677.0, bottomY = 805.0

// 1. Green accent (top-left) — slim parallelogram.
let green = quad(topLeftX: 368, topRightX: 480, topY: topY, bottomY: topBarBottom)
fillGradient(green,
             from: CGColor(red: 0.06, green: 0.93, blue: 0.55, alpha: 1),
             to: CGColor(red: 0.0, green: 0.80, blue: 0.42, alpha: 1),
             start: CGPoint(x: 430, y: topY), end: CGPoint(x: 330, y: topBarBottom))

// 2. White top bar.
ctx.addPath(quad(topLeftX: 528, topRightX: 862, topY: topY, bottomY: topBarBottom))
ctx.setFillColor(white)
ctx.fillPath()

// 3. White body: left spine + bottom bar. Slanted top cut, rounded outer
//    bottom-left corner, rounded inner corner, slanted right end.
let outerX = 222.0, innerX = 350.0
let body = CGMutablePath()
body.move(to: CGPoint(x: innerX, y: 415))                                 // inner top
body.addLine(to: CGPoint(x: outerX, y: 415 + (innerX - outerX) / slope))  // slanted top cut
body.addLine(to: CGPoint(x: outerX, y: bottomY - 160))
body.addQuadCurve(to: CGPoint(x: outerX + 160, y: bottomY),
                  control: CGPoint(x: outerX, y: bottomY))                // outer corner
body.addLine(to: CGPoint(x: 585, y: bottomY))
body.addLine(to: CGPoint(x: 585 + slope * (bottomY - barTopY), y: barTopY))
body.addLine(to: CGPoint(x: innerX + 95, y: barTopY))
body.addQuadCurve(to: CGPoint(x: innerX, y: barTopY - 95),
                  control: CGPoint(x: innerX, y: barTopY))                // inner corner
body.closeSubpath()
ctx.addPath(body)
ctx.setFillColor(white)
ctx.fillPath()

// 4. Orange accent (bottom-right) — long parallelogram.
let orange = quad(topLeftX: 731, topRightX: 901, topY: barTopY, bottomY: bottomY)
fillGradient(orange,
             from: CGColor(red: 1.0, green: 0.80, blue: 0.05, alpha: 1),
             to: CGColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1),
             start: CGPoint(x: 790, y: barTopY), end: CGPoint(x: 720, y: bottomY))

let image = ctx.makeImage()!
let fileArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let out = fileArgs.first ?? "icon-1024.png"
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
