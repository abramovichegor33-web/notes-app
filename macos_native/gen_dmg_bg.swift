import AppKit
import CoreGraphics
import Foundation

func renderBackground(width: Int, height: Int, scale: CGFloat, outputPath: String) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Failed to create CGContext")
    }

    ctx.scaleBy(x: scale, y: scale)
    let w: CGFloat = 660
    let h: CGFloat = 420

    // Deep dark gradient background matching FlowNote aesthetic
    let bgColors = [
        CGColor(red: 0.055, green: 0.059, blue: 0.075, alpha: 1.0),
        CGColor(red: 0.078, green: 0.082, blue: 0.110, alpha: 1.0),
        CGColor(red: 0.047, green: 0.051, blue: 0.067, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    }

    // Subtle indigo glow in the center
    let glowColors = [
        CGColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 0.18),
        CGColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 0.0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: w / 2, y: h * 0.56),
            startRadius: 10,
            endCenter: CGPoint(x: w / 2, y: h * 0.56),
            endRadius: 270,
            options: []
        )
    }

    // Dropzone cards behind FlowNote.app (left) and Applications (right)
    func drawCard(cx: CGFloat, cy: CGFloat) {
        let cardW: CGFloat = 176
        let cardH: CGFloat = 176
        let rect = CGRect(x: cx - cardW / 2, y: cy - cardH / 2, width: cardW, height: cardH)
        let path = CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.035))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.09))
        ctx.setLineWidth(1.0)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Note: CoreGraphics origin is bottom-left; Finder Y=225 from top -> 420-225 = 195
    drawCard(cx: 175, cy: 195)
    drawCard(cx: 485, cy: 195)

    // Sleek arrow between cards
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0.50, green: 0.53, blue: 0.98, alpha: 0.85))
    ctx.setLineWidth(2.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let arrowY: CGFloat = 195
    ctx.move(to: CGPoint(x: 288, y: arrowY))
    ctx.addLine(to: CGPoint(x: 370, y: arrowY))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 358, y: arrowY + 10))
    ctx.addLine(to: CGPoint(x: 372, y: arrowY))
    ctx.addLine(to: CGPoint(x: 358, y: arrowY - 10))
    ctx.strokePath()
    ctx.restoreGState()

    // Draw text using NSGraphicsContext
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 26, weight: .bold),
        .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1.0),
    ]
    let title = NSAttributedString(string: "FlowNote", attributes: titleAttrs)
    let titleSize = title.size()
    title.draw(at: NSPoint(x: (w - titleSize.width) / 2, y: h - 64))

    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.68, alpha: 1.0),
    ]
    let sub = NSAttributedString(
        string: "Перетащите FlowNote в папку «Программы» для установки",
        attributes: subAttrs
    )
    let subSize = sub.size()
    sub.draw(at: NSPoint(x: (w - subSize.width) / 2, y: 38))

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else { fatalError("makeImage failed") }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: w, height: h)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    try! pngData.write(to: URL(fileURLWithPath: outputPath))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
renderBackground(width: 660, height: 420, scale: 1.0, outputPath: "\(outDir)/bg@1x.png")
renderBackground(width: 1320, height: 840, scale: 2.0, outputPath: "\(outDir)/bg@2x.png")
