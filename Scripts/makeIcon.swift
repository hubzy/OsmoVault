import Cocoa
import CoreGraphics

// 用 CoreGraphics 程序化绘制 OsmoVault 新图标：
// 图像/视频资源管理器（类似照片 App）。
// 隐喻：一叠错落的白底照片卡，最前一张是「风景照 + 播放按钮」，
// 既代表图片、又代表视频；背景是蓝紫渐变圆角方块。

let size = 1024.0
let outURL = URL(fileURLWithPath:
    "/Users/hubzy/Documents/New project/OsmoVault/Resources/AppIcon-1024.png")

func rr(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
    return p
}

func linGrad(_ c1: CGColor, _ c2: CGColor) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: [c1, c2] as CFArray,
               locations: [0, 1])!
}

func col(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> CGColor {
    CGColor(red: Double(r) / 255, green: Double(g) / 255,
            blue: Double(b) / 255, alpha: a)
}

func colf(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// 翻转成 y 向下，方便用屏幕坐标思考
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// ── 背景：圆角方块 + 蓝紫渐变 ─────────────────────────────
let radius = size * 0.2198
let iconRect = CGRect(x: 0, y: 0, width: size, height: size)
ctx.saveGState()
ctx.addPath(rr(iconRect, radius))
ctx.clip()

ctx.drawLinearGradient(
    linGrad(col(91, 140, 255), col(142, 91, 255)),
    start: CGPoint(x: size * 0.15, y: size),
    end:   CGPoint(x: size * 0.9, y: 0),
    options: [])

// 顶部柔光，增加质感
ctx.saveGState()
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [col(255, 255, 255, 0.28), col(255, 255, 255, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
    startCenter: CGPoint(x: size * 0.32, y: size * 0.78),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.32, y: size * 0.78),
    endRadius: size * 0.7, options: [])
ctx.restoreGState()

// 底部轻微压暗，制造体积感
ctx.saveGState()
let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [col(20, 20, 40, 0), col(20, 20, 40, 0.18)] as CFArray,
                       locations: [0.55, 1])!
ctx.drawLinearGradient(shade,
    start: CGPoint(x: 0, y: size * 0.55),
    end:   CGPoint(x: 0, y: size), options: [])
ctx.restoreGState()
ctx.restoreGState()   // 结束背景 clip

// ── 照片卡 ───────────────────────────────────────────────
func drawCard(center: CGPoint, w: CGFloat, h: CGFloat,
              angle: CGFloat, scale: CGFloat, hero: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    ctx.scaleBy(x: scale, y: scale)

    let r = min(w, h) * 0.10
    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.018),
                  blur: size * 0.035,
                  color: col(15, 20, 45, 0.30))
    ctx.setFillColor(CGColor.white)
    ctx.addPath(rr(rect, r))
    ctx.fillPath()
    ctx.restoreGState()

    // 极淡描边
    ctx.setLineWidth(size * 0.0035)
    ctx.setStrokeColor(col(0, 0, 0, 0.06))
    ctx.addPath(rr(rect.insetBy(dx: size * 0.0025, dy: size * 0.0025), r))
    ctx.strokePath()

    if hero {
        drawHero(in: rect, r: r)
    } else {
        // 普通卡：一张迷你「风景照」，明确它是另一张照片
        let pad = w * 0.11
        let inner = rect.insetBy(dx: pad, dy: pad * 1.25)
        ctx.saveGState()
        ctx.addPath(rr(inner, r * 0.6))
        ctx.clip()
        ctx.drawLinearGradient(linGrad(col(150, 200, 245), col(236, 245, 250)),
                               start: CGPoint(x: 0, y: inner.maxY),
                               end:   CGPoint(x: 0, y: inner.minY), options: [])
        ctx.setFillColor(col(255, 214, 102, 1))
        ctx.fillEllipse(in: CGRect(x: inner.maxX - inner.width * 0.28,
                                   y: inner.maxY - inner.height * 0.30,
                                   width: inner.width * 0.16, height: inner.width * 0.16))
        ctx.setFillColor(col(110, 185, 150, 1))
        ctx.fillEllipse(in: CGRect(x: inner.minX + inner.width * 0.05, y: inner.minY,
                                   width: inner.width * 0.5, height: inner.height * 0.30))
        ctx.setFillColor(col(80, 160, 125, 1))
        ctx.fillEllipse(in: CGRect(x: inner.midX - inner.width * 0.27, y: inner.minY,
                                   width: inner.width * 0.55, height: inner.height * 0.34))
        ctx.restoreGState()
        ctx.setLineWidth(size * 0.0035)
        ctx.setStrokeColor(col(0, 0, 0, 0.06))
        ctx.addPath(rr(inner, r * 0.6))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func drawHero(in rect: CGRect, r: CGFloat) {
    let pad = rect.width * 0.10
    let im = rect.insetBy(dx: pad, dy: pad * 1.25)
    ctx.saveGState()
    ctx.addPath(rr(im, r * 0.6))
    ctx.clip()

    // 天空
    ctx.drawLinearGradient(
        linGrad(col(127, 196, 255), col(214, 240, 255)),
        start: CGPoint(x: 0, y: im.maxY),
        end:   CGPoint(x: 0, y: im.minY), options: [])

    // 太阳（带柔光），放到左上天空，避开中央播放键
    let sun = CGPoint(x: im.minX + im.width * 0.20, y: im.maxY - im.height * 0.30)
    let sg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [col(255, 224, 130, 0.85), col(255, 224, 130, 0)] as CFArray,
                        locations: [0, 1])!
    ctx.drawRadialGradient(sg, startCenter: sun, startRadius: 0,
                           endCenter: sun, endRadius: im.width * 0.16, options: [])
    ctx.setFillColor(col(255, 210, 92, 1))
    ctx.fillEllipse(in: CGRect(x: sun.x - im.width * 0.07, y: sun.y - im.width * 0.07,
                               width: im.width * 0.14, height: im.width * 0.14))

    // 远山（压到画面底部，峰顶低于播放键，避免与播放键打架）
    ctx.setFillColor(col(95, 190, 160, 1))
    ctx.fillEllipse(in: CGRect(x: im.minX - im.width * 0.15, y: im.minY,
                               width: im.width * 0.75, height: im.height * 0.26))
    ctx.setFillColor(col(56, 150, 120, 1))
    ctx.fillEllipse(in: CGRect(x: im.midX - im.width * 0.1, y: im.minY,
                               width: im.width * 0.95, height: im.height * 0.32))
    // 水面（盖住山脚形成岸线；水面顶在播放键下方，中央区域保持干净天空）
    ctx.setFillColor(col(120, 200, 220, 1))
    ctx.fill(CGRect(x: im.minX, y: im.minY, width: im.width, height: im.height * 0.10))
    ctx.restoreGState()

    // 播放按钮（视频隐喻）
    let pc = CGPoint(x: 0, y: 0)
    let pr = rect.width * 0.155
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.02, color: col(0, 0, 0, 0.30))
    ctx.setFillColor(CGColor.white)
    ctx.fillEllipse(in: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2))
    ctx.restoreGState()
    let tri = CGMutablePath()
    let s = pr * 0.58
    tri.move(to: CGPoint(x: pc.x - s * 0.55, y: pc.y - s))
    tri.addLine(to: CGPoint(x: pc.x - s * 0.55, y: pc.y + s))
    tri.addLine(to: CGPoint(x: pc.x + s * 0.85, y: pc.y))
    tri.closeSubpath()
    ctx.setFillColor(col(30, 40, 70, 1))
    ctx.addPath(tri)
    ctx.fillPath()
}

// 后卡（偏移、旋转、略小）
drawCard(center: CGPoint(x: size * 0.63, y: size * 0.40),
         w: size * 0.50, h: size * 0.50 * 0.78,
         angle: -0.20, scale: 0.92, hero: false)
// 前卡（主角：风景 + 播放）
drawCard(center: CGPoint(x: size * 0.46, y: size * 0.56),
         w: size * 0.52, h: size * 0.52 * 0.78,
         angle: 0.05, scale: 1.0, hero: true)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try png.write(to: outURL)
print("图标主图已写出 -> \(outURL.path)")
