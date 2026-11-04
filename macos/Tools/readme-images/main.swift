// README 그림을 만든다. 앱 자동 점검 캡처에 둥근 모서리·그림자를 입히고, 원본/결과 비교 그림을 그린다.
//
//     cd macos
//     bash build_app.sh
//     build/MogoPrint.app/Contents/MacOS/MogoPrint --snapshot-dir /tmp/mogo-shots --snapshot-appearance light \
//       --snapshot-size 1180x780 --snapshot-copies 2 \
//       --snapshot-drop "$PWD/../docs/demo/예시_국어_문제지.pdf" --snapshot-drop "$PWD/../docs/demo/예시_수학_문제지.pdf" \
//       --snapshot-quit
//     swiftc -O Sources/MogoCore/*.swift Tools/readme-images/main.swift -o /tmp/readme-images
//     /tmp/readme-images /tmp/mogo-shots ../docs/demo ../docs/images
import AppKit
import CoreText
import PDFKit

let a = CommandLine.arguments
guard a.count == 4 else { print("usage: readme-images <캡처 폴더> <예시 PDF 폴더> <출력 폴더>"); exit(1) }
let shots = URL(fileURLWithPath: a[1]), demo = URL(fileURLWithPath: a[2]), out = URL(fileURLWithPath: a[3])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func save(_ ctx: CGContext, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let url = out.appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("\(url.path) \(ctx.width)x\(ctx.height)")
}
func load(_ url: URL) -> CGImage? {
    guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) else { return nil }
    return rep.cgImage
}

/// 창 캡처에 둥근 모서리와 부드러운 그림자를 입힌다(투명 배경). 크기는 2배 해상도 기준.
func framed(_ name: String, as outName: String, radius: CGFloat = 22, maxWidth: Int? = nil) {
    guard var img = load(shots.appendingPathComponent(name)) else { print("없음: \(name)"); return }
    if let maxWidth, img.width > maxWidth {
        let s = CGFloat(maxWidth) / CGFloat(img.width)
        let c = context(maxWidth, Int(CGFloat(img.height) * s))
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
        img = c.makeImage()!
    }
    let pad: CGFloat = 60
    let w = CGFloat(img.width), h = CGFloat(img.height)
    let ctx = context(Int(w + pad * 2), Int(h + pad * 2))
    let rect = CGRect(x: pad, y: pad + 10, width: w, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 44, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path); ctx.clip()
    ctx.draw(img, in: rect)
    ctx.resetClip()
    ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); ctx.setLineWidth(2); ctx.strokePath()
    save(ctx, outName)
}

framed("main.png", as: "screenshot-main.png", maxWidth: 1800)
framed("empty.png", as: "screenshot-drop.png", maxWidth: 1400)
framed("confirm.png", as: "screenshot-confirm.png", radius: 18)
framed("manual.png", as: "screenshot-manual.png", maxWidth: 1800)

// MARK: 원본(그냥 A4에 맞춤) vs 모고 프린트 비교

let a4 = CGSize(width: 595.28, height: 841.89)
let src = SourceFile(url: demo.appendingPathComponent("예시_국어_문제지.pdf"))!
let result = Imposer.impose(files: [src], options: ImpositionOptions())!
let imposed = PDFDocument(data: result.data)!.page(at: 0)!.pageRef!
let original = src.document.page(at: 0)!.pageRef!
let originalBox = original.getBoxRect(.cropBox)
let plainScale = min(a4.width / originalBox.width, a4.height / originalBox.height)

let k: CGFloat = 2               // 2배 해상도
let sheet = CGSize(width: a4.width * 0.62, height: a4.height * 0.62)
let gap: CGFloat = 70, margin: CGFloat = 50, caption: CGFloat = 86
let canvas = CGSize(width: margin * 2 + sheet.width * 2 + gap, height: margin + sheet.height + caption)
let ctx = context(Int(canvas.width * k), Int(canvas.height * k))
ctx.scaleBy(x: k, y: k)

func drawSheet(at origin: CGPoint, _ body: (CGContext) -> Void) {
    let rect = CGRect(origin: origin, size: sheet)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: CGColor(gray: 0, alpha: 0.22))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: sheet.width / a4.width, y: sheet.height / a4.height)
    body(ctx)
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.15)); ctx.setLineWidth(0.6); ctx.stroke(rect)
}

func label(_ text: String, _ sub: String, centerX: CGFloat, y: CGFloat) {
    for (t, size, weight, dy) in [(text, CGFloat(17), "AppleSDGothicNeo-Bold", CGFloat(0)), (sub, CGFloat(13), "AppleSDGothicNeo-Regular", CGFloat(-24))] {
        let attrs = [kCTFontAttributeName: CTFontCreateWithName(weight as CFString, size, nil),
                     kCTForegroundColorAttributeName: CGColor(gray: 0.12, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, t as CFString, attrs))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: centerX - w / 2, y: y + dy)
        CTLineDraw(line, ctx)
    }
}

ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
ctx.fill(CGRect(origin: .zero, size: canvas))
let left = CGPoint(x: margin, y: caption), right = CGPoint(x: margin + sheet.width + gap, y: caption)
drawSheet(at: left) { c in
    // A3 원본을 그대로 A4에 맞춘 모습(바깥 여백까지 같이 줄어든다).
    c.translateBy(x: (a4.width - originalBox.width * plainScale) / 2, y: (a4.height - originalBox.height * plainScale) / 2)
    c.scaleBy(x: plainScale, y: plainScale)
    c.translateBy(x: -originalBox.minX, y: -originalBox.minY)
    c.drawPDFPage(original)
}
drawSheet(at: right) { c in c.drawPDFPage(imposed) }
label("그냥 A4에 맞춰 인쇄", "원본 대비 \(Int((plainScale * 100).rounded()))%, 바깥 여백까지 같이 줄어듦",
      centerX: left.x + sheet.width / 2, y: caption - 34)
label("모고 프린트", "원본 대비 \(Int((result.sections[0].scale * 100).rounded()))%, 여백을 잘라 A4에 꽉 차게",
      centerX: right.x + sheet.width / 2, y: caption - 34)
save(ctx, "before-after.png")
