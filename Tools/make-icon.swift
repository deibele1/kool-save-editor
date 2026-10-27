// Renders the app icon into KSEMac/Assets.xcassets/AppIcon.appiconset.
// Run from the repository root: swift Tools/make-icon.swift

import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> Data {
    let scale = CGFloat(size) / 1024
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Squircle body with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x070C1A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x16264A), color(0x070B17)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A few stars.
    let stars: [(CGFloat, CGFloat, CGFloat)] = [(210, 780, 5), (300, 860, 3), (770, 820, 4), (840, 700, 3), (190, 300, 3),
                                                  (860, 260, 5), (720, 180, 3), (260, 180, 4), (640, 870, 3), (150, 560, 3)]
    for (x, y, r) in stars {
        context.setFillColor(color(0xDCE6FF, 0.75))
        context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // Glow behind the holocron.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFB347, 0.55), color(0xFF8C1A, 0.0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 500), endRadius: 380, options: [])
    context.restoreGState()

    // Isometric cube.
    let center = CGPoint(x: 512, y: 470)
    let edge: CGFloat = 250
    let dx = edge * cos(.pi / 6), dy = edge * sin(.pi / 6)
    let top = CGPoint(x: center.x, y: center.y + edge)
    let left = CGPoint(x: center.x - dx, y: center.y + dy)
    let right = CGPoint(x: center.x + dx, y: center.y + dy)
    let bottom = CGPoint(x: center.x, y: center.y - edge)
    let bottomLeft = CGPoint(x: center.x - dx, y: center.y - dy)
    let bottomRight = CGPoint(x: center.x + dx, y: center.y - dy)

    func face(_ points: [CGPoint], _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    func inset(_ points: [CGPoint], by factor: CGFloat) -> [CGPoint] {
        let cx = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let cy = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        return points.map { CGPoint(x: cx + ($0.x - cx) * factor, y: cy + ($0.y - cy) * factor) }
    }

    let topFace = [top, right, center, left]
    let leftFace = [left, center, bottom, bottomLeft]
    let rightFace = [center, right, bottomRight, bottom]

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.5))
    let silhouette = CGMutablePath()
    silhouette.addLines(between: [top, right, bottomRight, bottom, bottomLeft, left])
    silhouette.closeSubpath()
    context.addPath(silhouette)
    context.setFillColor(color(0x8A5414))
    context.fillPath()
    context.restoreGState()

    face(topFace, [color(0xFFE2A0), color(0xF0B653)], from: top, to: center)
    face(leftFace, [color(0xD99A3C), color(0x9C5F18)], from: left, to: bottom)
    face(rightFace, [color(0xB8752A), color(0x744210)], from: right, to: bottom)

    // Panels and glowing seams.
    for (points, alpha) in [(topFace, 0.55), (leftFace, 0.45), (rightFace, 0.4)] {
        let panel = CGMutablePath()
        panel.addLines(between: inset(points, by: 0.56))
        panel.closeSubpath()
        context.addPath(panel)
        context.setStrokeColor(color(0xFFF1CC, alpha))
        context.setLineWidth(10)
        context.setLineJoin(.round)
        context.strokePath()

        let core = CGMutablePath()
        core.addLines(between: inset(points, by: 0.2))
        core.closeSubpath()
        context.addPath(core)
        context.setFillColor(color(0xFFF6DD, alpha + 0.2))
        context.fillPath()
    }

    let outline = CGMutablePath()
    outline.addLines(between: [top, right, bottomRight, bottom, bottomLeft, left])
    outline.closeSubpath()
    for corner in [left, right, bottom] {
        outline.move(to: center)
        outline.addLine(to: corner)
    }
    context.addPath(outline)
    context.setStrokeColor(color(0xFFE9B8, 0.9))
    context.setLineWidth(6)
    context.setLineJoin(.round)
    context.strokePath()

    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: "KSEMac/Assets.xcassets/AppIcon.appiconset")
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: base * scale).write(to: folder.appendingPathComponent(name))
    }
}
print("Wrote app icons to \(folder.path)")
