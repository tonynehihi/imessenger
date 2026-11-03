// Vẽ ảnh nền cửa sổ DMG (660×410 điểm – vừa phần nhìn thấy của cửa sổ 660×470): dòng hướng dẫn, mũi tên app → Applications, nhắc đọc hướng dẫn mở lần đầu
// Chạy: swift dmg/ve-nen.swift <thư mục ra>  → nen.png (1x) + nen@2x.png
import AppKit
let ra = CommandLine.arguments[1]
for k in [1.0, 2.0] {
    let w = 660.0, h = 410.0
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * k), pixelsHigh: Int(h * k), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.97, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.99, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    func chu(_ s: String, _ y: Double, _ co: Double, _ dam: NSFont.Weight, _ mau: NSColor) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: co, weight: dam), .foregroundColor: mau, .paragraphStyle: p])
            .draw(in: NSRect(x: 20, y: h - y - co * 1.4, width: w - 40, height: co * 1.6))
    }
    chu("Kéo Messenger Vdk vào Applications", 26, 20, .semibold, NSColor(calibratedWhite: 0.15, alpha: 1))
    // mũi tên giữa 2 icon (icon ở x=165 và x=495, tâm y=150 tính từ trên)
    let mau = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 0.9)
    let y = h - 150, m = NSBezierPath()
    m.move(to: NSPoint(x: 255, y: y)); m.line(to: NSPoint(x: 395, y: y)); m.lineWidth = 6; m.lineCapStyle = .round; mau.setStroke(); m.stroke()
    let dau = NSBezierPath(); dau.move(to: NSPoint(x: 410, y: y)); dau.line(to: NSPoint(x: 385, y: y + 16)); dau.line(to: NSPoint(x: 385, y: y - 16)); dau.close(); mau.setFill(); dau.fill()
    chu("Lần đầu mở bị macOS chặn? Mở file «Hướng dẫn mở lần đầu» bên dưới.", 246, 13, .regular, NSColor(calibratedWhite: 0.3, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ra + (k == 1 ? "/nen.png" : "/nen@2x.png")))
}
