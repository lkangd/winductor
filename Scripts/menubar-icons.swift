#!/usr/bin/env swift
import AppKit
import Foundation

// Run from repo root: swift Scripts/menubar-icons.swift
// Rasterize approved SVG paths directly at final 1x/2x sizes. No intermediate PNG resampling.
// Freeze the previous 128px alpha-derived shared crop/centering, including its rounded 21×22pt mapping.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/Brand")
let source = root.appendingPathComponent(".assets/Winductor_MenuBar_Monochrome/SVG")

func alphaBox(_ name: String) -> CGRect {
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: output.appendingPathComponent(name)))!
    var box = CGRect.null
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)!.alphaComponent > 5.0 / 255 {
            box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return box
}
let body = alphaBox("MenuBarIdle_128px.png")
let all = body.union(alphaBox("MenuBarRestoring_128px.png"))
let half = max(body.midY - all.minY, all.maxY - body.midY) + 2
let crop = CGRect(x: all.minX - 2, y: body.midY - half, width: all.width + 4, height: half * 2)
let size = CGSize(width: 21, height: 22)
let bodyRect = CGRect(x: (body.minX - crop.minX) * 21 / crop.width,
                      y: (crop.maxY - body.maxY) * 22 / crop.height,
                      width: body.width * 21 / crop.width, height: body.height * 22 / crop.height)
let radius: CGFloat = 3.63
let center = CGPoint(x: min(bodyRect.maxX - radius * 0.4, 21 - radius - 0.2),
                     y: bodyRect.minY + radius * 0.4)
print("crop=\(crop), bodyRect=\(bodyRect), badgeCenter=\(center)")

struct Shape {
    let path: CGPath
    let stroke: Bool
    let evenOdd: Bool
}
// Deliberately limited to the approved source SVG path commands, not a general SVG renderer.
final class SVGPaths: NSObject, XMLParserDelegate {
    var shapes: [Shape] = []
    var stroked = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "g" { stroked = attributes["stroke"] != nil }
        guard name == "path", let data = attributes["d"] else { return }
        let regex = try! NSRegularExpression(pattern: "[A-Za-z]|[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?")
        let tokens = regex.matches(in: data, range: NSRange(data.startIndex..., in: data))
            .map { String(data[Range($0.range, in: data)!]) }
        let path = CGMutablePath()
        var i = 0
        func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
        func point() -> CGPoint { CGPoint(x: number(), y: number()) }
        while i < tokens.count {
            let command = tokens[i]; i += 1
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C":
                let c1 = point(), c2 = point(), end = point()
                path.addCurve(to: end, control1: c1, control2: c2)
            case "Z", "z": path.closeSubpath()
            default:
                // Approved SVG uses implicit L coordinate pairs following M/L.
                i -= 1
                precondition(Double(tokens[i]) != nil, "Unsupported SVG command")
                path.addLine(to: point())
            }
        }
        shapes.append(Shape(path: path, stroke: stroked, evenOdd: attributes["fill-rule"] == "evenodd"))
    }
}

func drawBadge(_ ctx: CGContext, scale: CGFloat) {
    let ring = radius + 1.1
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: CGRect(x: center.x - ring, y: center.y - ring, width: 2 * ring, height: 2 * ring))
    ctx.setBlendMode(.normal)
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    ctx.setBlendMode(.clear)
    // Align straight exclamation edges to backing pixels, retaining antialiasing for curves.
    func aligned(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX * scale).rounded() / scale, y: (rect.minY * scale).rounded() / scale,
               width: max(1, (rect.width * scale).rounded()) / scale,
               height: max(1, (rect.height * scale).rounded()) / scale)
    }
    ctx.fill(aligned(CGRect(x: center.x - 0.605, y: center.y - 0.33, width: 1.21, height: 2.86)))
    ctx.fillEllipse(in: aligned(CGRect(x: center.x - 0.66, y: center.y - 2.31, width: 1.32, height: 1.32)))
}

for (name, svgName, badge) in [("Idle", "Idle", false), ("Restoring", "Restoring", false), ("NotReady", "Idle", true)] {
    let delegate = SVGPaths()
    let parser = XMLParser(contentsOf: source.appendingPathComponent("MenuBar\(svgName).svg"))!
    parser.delegate = delegate
    precondition(parser.parse(), "Invalid SVG")
    for scale in [1, 2] {
        let ctx = CGContext(data: nil, width: 21 * scale, height: 22 * scale, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.saveGState()
        // SVG viewBox -5 -8 74 74 → original 128px coordinates → shared crop → final points.
        ctx.translateBy(x: -crop.minX * 21 / crop.width, y: crop.maxY * 22 / crop.height)
        ctx.scaleBy(x: 21 / crop.width, y: -22 / crop.height)
        ctx.scaleBy(x: 128 / 74, y: 128 / 74)
        ctx.translateBy(x: 5, y: 8)
        for shape in delegate.shapes {
            let outline = shape.stroke ? shape.path.copy(strokingWithWidth: 4.35, lineCap: .round,
                                                         lineJoin: .miter, miterLimit: 10) : shape.path
            let bounds = outline.boundingBoxOfPath.applying(ctx.ctm)
            precondition(CGRect(x: 0, y: 0, width: 21 * scale, height: 22 * scale).contains(bounds),
                         "Shared crop must not clip approved SVG geometry")
            ctx.addPath(shape.path)
            if shape.stroke {
                ctx.setLineWidth(4.35)
                ctx.setLineCap(.round)
                ctx.strokePath()
            } else {
                ctx.drawPath(using: shape.evenOdd ? .eoFill : .fill)
            }
        }
        ctx.restoreGState()
        if badge { drawBadge(ctx, scale: CGFloat(scale)) }
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        rep.size = size
        try rep.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("MenuBar\(name)\(scale == 2 ? "@2x" : "").png"))
    }
}
