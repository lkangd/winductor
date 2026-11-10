// brand-subject.swift — 一次性派生：白底应用图标原图 → 透明底主体（ui-refactor 票 08）。
// 用法（仓库根）：swiftc -O Scripts/brand-subject.swift -o /tmp/brand-subject && /tmp/brand-subject <Approved_Original_1254.png> Resources/Brand
// 输入：用户批准的原图（1254×1254 RGB 白底、无 alpha；主 checkout assets/Winductor-All-Icon-Sizes-REPACK/）。
// 产出：
//   AppIconSubject.png           透明底主体，按 alpha 外接框裁切（关于页 / 界面用）
//   AppIcon.icon/Assets/Subject.png  1024 画布前景，构图与已批准 1024 图标一致（Icon Composer 图层）
// 方法：
//   1) 从四边 flood fill：浅色（255 − min(rgb) ≤ 70）且相邻像素色差 ≤ 3 的连通区 = 背景（含柔和投影），alpha 置 0。
//   2) 白描边与投影平滑相接、颜色上分不开的两处手工封口：指挥棒（胶囊形，解析覆盖率抗锯齿）、
//      头部描边左下段（该区域内按「到头发深色像素距离 ≤ 22px」重建描边外缘）。坐标均为原图像素。
//   3) 主体距背景 ≤ 2.5px 的边缘带：取内部色 F（距背景 ≥ 3.5px 的最近像素）与局部背景色 W 线性解混求 alpha，去白边。
// 换原图须重新标定第 2 步的坐标。
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    print("用法：brand-subject <原图.png> <输出目录>")
    exit(2)
}

let maxLightness = 70.0, maxStep = 3.0, band = 2.5, interior = 3.5
let batons: [(x0: Double, y0: Double, x1: Double, y1: Double, r: Double)] = [(816.2, 410.5, 780, 545, 21.6)]
let outlineZone = (x0: 370, y0: 740, x1: 530, y1: 850), hairMaxY = 812, outlineRadius = 22.0
// 已批准 1024 图标 = 原图 × 0.98571 后平移 (−106.1, −114.3)（两图主体外接框求得）
let iconScale = 0.98571, iconOffset = (x: -106.1, y: -114.3)

let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let w = image.width, h = image.height, n = w * h
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgbaContext(_ cw: Int, _ ch: Int) -> CGContext {
    CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
let input = rgbaContext(w, h)
input.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
let pixels = input.data!.bindMemory(to: UInt8.self, capacity: n * 4) // 行序自上而下
var color = [SIMD3<Double>](repeating: .zero, count: n)
for i in 0 ..< n {
    color[i] = SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2]))
}
func lightnessGap(_ i: Int) -> Double { 255 - color[i].min() }
func step(_ i: Int, _ j: Int) -> Double {
    let v = color[i] - color[j]
    return max(abs(v.x), abs(v.y), abs(v.z))
}

// 手工封口：覆盖率 1 的像素挡住 flood，部分覆盖的像素按覆盖率给 alpha
var keep = [Double](repeating: 0, count: n)
for y in 0 ..< h {
    for x in 0 ..< w {
        let px = Double(x) + 0.5, py = Double(y) + 0.5
        for b in batons {
            let vx = b.x1 - b.x0, vy = b.y1 - b.y0
            let t = max(0, min(1, ((px - b.x0) * vx + (py - b.y0) * vy) / (vx * vx + vy * vy)))
            let dist = hypot(px - (b.x0 + t * vx), py - (b.y0 + t * vy))
            keep[y * w + x] = max(keep[y * w + x], max(0, min(1, b.r - dist + 0.5)))
        }
    }
}
var hair = [(Int, Int)]()
for y in (outlineZone.y0 - 30) ..< hairMaxY {
    for x in (outlineZone.x0 - 30) ..< (outlineZone.x1 + 30) {
        let c = color[y * w + x]
        if c.max() < 170, c.max() - c.min() < 60 { hair.append((x, y)) } // 深色低饱和 = 头发（排除绿色窗）
    }
}
for y in outlineZone.y0 ..< outlineZone.y1 {
    for x in outlineZone.x0 ..< outlineZone.x1 {
        var best = Double.infinity
        for (hx, hy) in hair where abs(hx - x) < 30 && abs(hy - y) < 30 {
            best = min(best, Double((hx - x) * (hx - x) + (hy - y) * (hy - y)))
        }
        keep[y * w + x] = max(keep[y * w + x], max(0, min(1, outlineRadius - best.squareRoot() + 0.5)))
    }
}

// 1) 背景 flood fill
var background = [Bool](repeating: false, count: n)
var stack = [Int]()
for x in 0 ..< w { stack += [x, (h - 1) * w + x] }
for y in 0 ..< h { stack += [y * w, y * w + w - 1] }
for i in stack { background[i] = true }
while let i = stack.popLast() {
    let x = i % w, y = i / w
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
        let j = ny * w + nx
        guard !background[j], keep[j] < 1, lightnessGap(j) <= maxLightness, step(i, j) <= maxStep else { continue }
        background[j] = true
        stack.append(j)
    }
}

// 3) 边缘解混
let radius = 6
var distanceToBackground = [Double](repeating: .infinity, count: n)
for y in 0 ..< h {
    for x in 0 ..< w where !background[y * w + x] {
        for oy in -radius ... radius {
            for ox in -radius ... radius {
                let nx = x + ox, ny = y + oy
                guard nx >= 0, ny >= 0, nx < w, ny < h, background[ny * w + nx] else { continue }
                distanceToBackground[y * w + x] = min(distanceToBackground[y * w + x], hypot(Double(ox), Double(oy)))
            }
        }
    }
}
var alpha = [Double](repeating: 0, count: n)
var output = color
for y in 0 ..< h {
    for x in 0 ..< w {
        let i = y * w + x
        if background[i] {
            alpha[i] = keep[i]
            continue
        }
        alpha[i] = 1
        guard distanceToBackground[i] <= band, keep[i] < 1 else { continue }
        var nearest = Double.infinity, inner = color[i], bgSum = SIMD3<Double>.zero, bgCount = 0.0
        for oy in -5 ... 5 {
            for ox in -5 ... 5 {
                let nx = x + ox, ny = y + oy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx, d = hypot(Double(ox), Double(oy))
                if !background[j], distanceToBackground[j] >= interior, d < nearest { nearest = d; inner = color[j] }
                if background[j], d <= 3 { bgSum += color[j]; bgCount += 1 }
            }
        }
        let bg = bgCount > 0 ? bgSum / bgCount : SIMD3(repeating: 254)
        let span = inner - bg
        let spanSquared = (span * span).sum()
        guard spanSquared > 900 else { continue } // 内部色与背景太近（白描边外缘）：无法解混，保持不透明
        let a = max(0, min(1, ((color[i] - bg) * span).sum() / spanSquared))
        alpha[i] = max(a, keep[i])
        output[i] = a < 0.3 ? inner
            : ((color[i] - (1 - a) * bg) / a).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255))
    }
}

let subjectContext = rgbaContext(w, h)
let out = subjectContext.data!.bindMemory(to: UInt8.self, capacity: n * 4)
var minX = w, minY = h, maxX = -1, maxY = -1
for i in 0 ..< n {
    for k in 0 ..< 3 { out[i * 4 + k] = UInt8((output[i][k] * alpha[i]).rounded()) }
    out[i * 4 + 3] = UInt8((alpha[i] * 255).rounded())
    if out[i * 4 + 3] > 0 {
        minX = min(minX, i % w); maxX = max(maxX, i % w); minY = min(minY, i / w); maxY = max(maxY, i / w)
    }
}
let subject = subjectContext.makeImage()!
func save(_ image: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("写入失败：\(path)") }
}
let outDir = args[2]
save(subject.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!,
     outDir + "/AppIconSubject.png")
let icon = rgbaContext(1024, 1024)
icon.interpolationQuality = .high
let drawnHeight = Double(h) * iconScale
icon.draw(subject, in: CGRect(x: iconOffset.x, y: 1024 - (iconOffset.y + drawnHeight),
                              width: Double(w) * iconScale, height: drawnHeight))
save(icon.makeImage()!, outDir + "/AppIcon.icon/Assets/Subject.png")
print("主体外接框（原图像素）：x \(minX) y \(minY) w \(maxX - minX + 1) h \(maxY - minY + 1)")
