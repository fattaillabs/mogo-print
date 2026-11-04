import AppKit
import CoreText
import MogoCore
import PDFKit
import XCTest

/// 테스트용 PDF를 만들고 결과를 읽는 도우미.
enum TestPDF {
    struct Page {
        var size: CGSize
        var text: String? = nil
        var rotate: Int = 0
        /// 검은 사각형(페이지 좌표, 왼쪽 아래 원점, 회전 전)
        var boxes: [CGRect] = []
    }

    static let a3 = CGSize(width: 841.89, height: 1190.55)
    static let a4 = CGSize(width: 595.28, height: 841.89)

    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MogoPrintTests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 페이지들을 그려 PDF 파일로 저장한다. 글자는 PDFKit이 읽을 수 있는 실제 텍스트로 넣는다.
    @discardableResult
    static func make(_ pages: [Page], at url: URL) -> URL {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pages.first?.size ?? a4)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for p in pages {
            var media = CGRect(origin: .zero, size: p.size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for b in p.boxes { ctx.fill(b) }
            if let text = p.text {
                let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, 14, nil)
                let attr = [kCTFontAttributeName: font] as CFDictionary
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attr))
                ctx.textPosition = CGPoint(x: p.size.width / 2 - 40, y: p.size.height - 60)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        // 회전은 PDFKit으로 넣는다(/Rotate).
        let doc = PDFDocument(data: data as Data)!
        for (i, p) in pages.enumerated() where p.rotate != 0 {
            doc.page(at: i)?.rotation = p.rotate
        }
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    /// PDF 페이지를 회색 비트맵으로 그려 잉크(어두운 픽셀) 영역을 돌려준다. PDFKit 표시와 같은 방향(회전 반영).
    /// 좌표는 페이지 포인트, 왼쪽 아래 원점.
    static func inkRect(of page: PDFPage, dpi: CGFloat = 72) -> CGRect? {
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let s = dpi / 72
        let w = Int(size.width * s), h = Int(size.height * s)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        // PDFPage.draw는 페이지 회전을 반영해서 그린다.
        page.draw(with: .cropBox, to: ctx)
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for row in 0..<h {
            for x in 0..<w where buf[row * ctx.bytesPerRow + x] < 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / s, y: size.height - CGFloat(maxY + 1) / s,
                      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
    }

    /// 저장소 맨 위 폴더 (이 파일: <저장소>/macos/Tests/MogoCoreTests/TestSupport.swift).
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MogoCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // 저장소
    }

    /// 저장소의 Samples 폴더(평가원 기출, git 제외). 없으면 nil.
    static var samplesDir: URL? {
        let dir = repoRoot.appendingPathComponent("Samples", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }
}

func XCTAssertRectEqual(_ a: CGRect?, _ b: CGRect, accuracy: CGFloat, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("rect is nil \(message)", file: file, line: line) }
    XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "minX \(message)", file: file, line: line)
    XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "minY \(message)", file: file, line: line)
    XCTAssertEqual(a.maxX, b.maxX, accuracy: accuracy, "maxX \(message)", file: file, line: line)
    XCTAssertEqual(a.maxY, b.maxY, accuracy: accuracy, "maxY \(message)", file: file, line: line)
}
