// 应用图标生成器:液态玻璃底 + 活泼小螃蟹
// 用法: swift IconGen.swift [输出路径]
import AppKit

let S: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: S, height: S)

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let cg = gctx.cgContext

func rr(_ rect: NSRect, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
}

// ── 玻璃底板 ──────────────────────────────────────────────
let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = rr(tileRect, 186)

// 投影
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowOffset = NSSize(width: 0, height: -16)
sh.shadowBlurRadius = 38
sh.shadowColor = NSColor.black.withAlphaComponent(0.45)
sh.set()
NSColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

// 深色玻璃渐变
NSGradient(colors: [NSColor(red: 0.26, green: 0.28, blue: 0.36, alpha: 1),
                    NSColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1)])!
    .draw(in: tile, angle: -90)

NSGraphicsContext.saveGraphicsState()
tile.addClip()

// 品牌色氤氲(和小组件一致:右上橙、左下粉)
NSGradient(colors: [NSColor(red: 1.0, green: 0.48, blue: 0.25, alpha: 0.40), NSColor.clear])!
    .draw(fromCenter: NSPoint(x: 770, y: 740), radius: 0,
          toCenter: NSPoint(x: 770, y: 740), radius: 560, options: [])
NSGradient(colors: [NSColor(red: 0.95, green: 0.33, blue: 0.55, alpha: 0.32), NSColor.clear])!
    .draw(fromCenter: NSPoint(x: 270, y: 250), radius: 0,
          toCenter: NSPoint(x: 270, y: 250), radius: 540, options: [])

// 顶部镜面高光
NSGradient(colors: [NSColor.white.withAlphaComponent(0.30),
                    NSColor.white.withAlphaComponent(0.0)])!
    .draw(in: NSRect(x: 100, y: 545, width: 824, height: 379), angle: -90)

NSGraphicsContext.restoreGraphicsState()

// 玻璃描边
let border = rr(tileRect.insetBy(dx: 4, dy: 4), 182)
border.lineWidth = 7
NSColor.white.withAlphaComponent(0.34).setStroke()
border.stroke()

// ── 小螃蟹 ──────────────────────────────────────────────
let crabBody  = NSColor(red: 0.94, green: 0.47, blue: 0.31, alpha: 1)
let crabLight = NSColor(red: 0.98, green: 0.56, blue: 0.38, alpha: 1)
let crabDark  = NSColor(red: 0.72, green: 0.29, blue: 0.17, alpha: 1)

cg.saveGState()
cg.translateBy(x: 512, y: 452)
cg.rotate(by: -6 * .pi / 180)

func strokeCapsule(from a: NSPoint, to b: NSPoint, width w: CGFloat, color: NSColor) {
    let p = NSBezierPath()
    p.lineWidth = w
    p.lineCapStyle = .round
    p.move(to: a)
    p.line(to: b)
    color.setStroke()
    p.stroke()
}

// 六条小腿
strokeCapsule(from: NSPoint(x: -118, y: -78), to: NSPoint(x: -196, y: -142), width: 26, color: crabDark)
strokeCapsule(from: NSPoint(x: -96, y: -100), to: NSPoint(x: -156, y: -180), width: 26, color: crabDark)
strokeCapsule(from: NSPoint(x: -64, y: -114), to: NSPoint(x: -100, y: -204), width: 26, color: crabDark)
strokeCapsule(from: NSPoint(x: 118, y: -78), to: NSPoint(x: 196, y: -142), width: 26, color: crabDark)
strokeCapsule(from: NSPoint(x: 96, y: -100), to: NSPoint(x: 156, y: -180), width: 26, color: crabDark)
strokeCapsule(from: NSPoint(x: 64, y: -114), to: NSPoint(x: 100, y: -204), width: 26, color: crabDark)

// 胳膊
strokeCapsule(from: NSPoint(x: -152, y: 28), to: NSPoint(x: -236, y: 104), width: 36, color: crabDark)
strokeCapsule(from: NSPoint(x: 152, y: 28), to: NSPoint(x: 236, y: 104), width: 36, color: crabDark)

// 大钳子(张开,举高高,活泼感)
func pincer(center c: NSPoint, radius r: CGFloat, openDeg: CGFloat, facingDeg: CGFloat) {
    let p = NSBezierPath()
    p.move(to: c)
    p.appendArc(withCenter: c, radius: r,
                startAngle: facingDeg + openDeg / 2,
                endAngle: facingDeg - openDeg / 2 + 360, clockwise: false)
    p.close()
    NSGraphicsContext.saveGraphicsState()
    p.addClip()
    NSGradient(colors: [crabLight, crabDark])!.draw(in: p.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    p.lineWidth = 9
    crabDark.setStroke()
    p.stroke()
}
pincer(center: NSPoint(x: -268, y: 148), radius: 88, openDeg: 46, facingDeg: 128)
pincer(center: NSPoint(x: 268, y: 148), radius: 88, openDeg: 46, facingDeg: 52)

// 身体
let bodyRect = NSRect(x: -190, y: -132, width: 380, height: 258)
let body = rr(bodyRect, 108)
NSGraphicsContext.saveGraphicsState()
body.addClip()
NSGradient(colors: [crabLight, crabDark])!.draw(in: bodyRect, angle: -90)
// 身体顶部高光
NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.clear])!
    .draw(in: NSRect(x: -190, y: 20, width: 380, height: 106), angle: -90)
NSGraphicsContext.restoreGraphicsState()
body.lineWidth = 8
crabDark.withAlphaComponent(0.85).setStroke()
body.stroke()

// 大眼睛
func eye(at c: NSPoint) {
    let white = NSBezierPath(ovalIn: NSRect(x: c.x - 62, y: c.y - 62, width: 124, height: 124))
    NSColor.white.setFill()
    white.fill()
    let pupil = NSBezierPath(ovalIn: NSRect(x: c.x - 27 + 10, y: c.y - 27 + 13, width: 54, height: 54))
    NSColor(red: 0.13, green: 0.10, blue: 0.10, alpha: 1).setFill()
    pupil.fill()
    let light = NSBezierPath(ovalIn: NSRect(x: c.x - 9 + 24, y: c.y - 9 + 34, width: 18, height: 18))
    NSColor.white.setFill()
    light.fill()
}
eye(at: NSPoint(x: -92, y: 52))
eye(at: NSPoint(x: 92, y: 52))

// 笑容
let smile = NSBezierPath()
smile.appendArc(withCenter: NSPoint(x: 0, y: -8), radius: 62, startAngle: 210, endAngle: 330, clockwise: false)
smile.lineWidth = 14
smile.lineCapStyle = .round
NSColor(red: 0.35, green: 0.13, blue: 0.08, alpha: 0.85).setStroke()
smile.stroke()

// 腮红
for x: CGFloat in [-152, 152] {
    let blush = NSBezierPath(ovalIn: NSRect(x: x - 27, y: -32, width: 54, height: 32))
    NSColor(red: 1.0, green: 0.62, blue: 0.50, alpha: 0.55).setFill()
    blush.fill()
}

cg.restoreGState()
NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("✅ 已生成 \(outPath)")
