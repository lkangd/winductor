#!/usr/bin/env swift
import AppKit

// 部分 Icon Composer / actool 版本的回落 .icns 只含 16/32/128/256 像素，没有完整的 Retina 档位。
// 通知等传统图标消费者使用独立的完整 .icns；现代 Finder/Dock 仍读 AppIcon 的分层 Assets.car。
// 输入与 Composer 同一张 1024px 透明图层；白色圆角底板采用 macOS 图标的安全边距。
// 用法：swift Scripts/legacy-app-icon.swift <Subject.png> <输出.iconset>
guard CommandLine.arguments.count == 3,
      let subject = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("用法：legacy-app-icon.swift <Subject.png> <输出.iconset>")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for side in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = side * scale
        let size = CGFloat(pixels)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("无法创建图标位图") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let tile = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 100 / 1024,
                                                                      dy: size * 100 / 1024)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: tile, xRadius: size * 180 / 1024, yRadius: size * 180 / 1024).fill()
        subject.draw(in: tile)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("无法编码图标") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(side)x\(side)\(suffix).png"))
    }
}
