import MogoCore
import PDFKit
import XCTest

final class ImposerTests: XCTestCase {
    private let mm = pointsPerMM

    private func file(_ pages: [TestPDF.Page], name: String = "f") throws -> SourceFile {
        let url = TestPDF.make(pages, at: TestPDF.tempDir().appendingPathComponent("\(name).pdf"))
        return try XCTUnwrap(SourceFile(url: url))
    }

    func testCropIsInkPlusPaddingAndScaleFitsA4() throws {
        let box = CGRect(x: 80, y: 70, width: 680, height: 1050)
        let f = try file([.init(size: TestPDF.a3, boxes: [box])])
        var o = ImpositionOptions()
        o.paperMarginMM = 5
        o.paddingMM = 1.5
        let plan = Imposer.plan(files: [f], options: o)
        let page = try XCTUnwrap(plan.first?.pages.first)
        XCTAssertRectEqual(page.crop, box.insetBy(dx: -1.5 * mm, dy: -1.5 * mm), accuracy: 1.5)
        let usable = CGSize(width: a4Size.width - 10 * mm, height: a4Size.height - 10 * mm)
        let expected = min(usable.width / page.crop.width, usable.height / page.crop.height)
        XCTAssertEqual(page.scale, expected, accuracy: 0.0001)
    }

    func testOneCropForAllPagesOfSameSize() throws {
        let f = try file([
            .init(size: TestPDF.a3, boxes: [CGRect(x: 100, y: 100, width: 300, height: 300)]),
            .init(size: TestPDF.a3, boxes: [CGRect(x: 400, y: 600, width: 300, height: 400)]),
        ])
        let plan = Imposer.plan(files: [f], options: ImpositionOptions())
        let pages = try XCTUnwrap(plan.first?.pages)
        // 글자 크기가 쪽마다 달라지지 않도록 합친 영역 하나로 자른다.
        XCTAssertEqual(pages[0].crop, pages[1].crop)
        XCTAssertEqual(pages[0].scale, pages[1].scale)
        XCTAssertTrue(pages[0].crop.contains(CGRect(x: 100, y: 100, width: 600, height: 900)))
    }

    func testNeverEnlargesBeyondOriginal() throws {
        // 정답표처럼 원래 A4이고 내용이 작으면 100%로 둔다.
        let f = try file([.init(size: TestPDF.a4, boxes: [CGRect(x: 100, y: 500, width: 300, height: 200)])])
        let plan = Imposer.plan(files: [f], options: ImpositionOptions())
        XCTAssertEqual(try XCTUnwrap(plan.first).scale, 1, accuracy: 0.0001)
    }

    func testMixedPageSizesGetTheirOwnCrop() throws {
        let f = try file([
            .init(size: TestPDF.a3, boxes: [CGRect(x: 80, y: 70, width: 680, height: 1050)]),
            .init(size: TestPDF.a4, boxes: [CGRect(x: 60, y: 60, width: 470, height: 720)]),
        ])
        let pages = try XCTUnwrap(Imposer.plan(files: [f], options: ImpositionOptions()).first?.pages)
        XCTAssertNotEqual(pages[0].crop, pages[1].crop)
        XCTAssertTrue(CGRect(origin: .zero, size: TestPDF.a4).contains(pages[1].crop))
        XCTAssertRectEqual(pages[1].crop, CGRect(x: 60, y: 60, width: 470, height: 720).insetBy(dx: -1.5 * mm, dy: -1.5 * mm), accuracy: 1.5)
    }

    func testCropAdjustment() throws {
        let box = CGRect(x: 80, y: 70, width: 680, height: 1050)
        let f = try file([.init(size: TestPDF.a3, boxes: [box])])
        var o = ImpositionOptions()
        let base = try XCTUnwrap(Imposer.plan(files: [f], options: o).first?.pages.first)

        o.adjustments[f.url] = CropAdjustment(top: 10, bottom: -5, left: 3, right: 0)
        let adj = try XCTUnwrap(Imposer.plan(files: [f], options: o).first?.pages.first)
        XCTAssertEqual(adj.crop.maxY, base.crop.maxY - 10 * mm, accuracy: 0.01)
        XCTAssertEqual(adj.crop.minY, base.crop.minY - 5 * mm, accuracy: 0.01)
        XCTAssertEqual(adj.crop.minX, base.crop.minX + 3 * mm, accuracy: 0.01)
        XCTAssertEqual(adj.crop.maxX, base.crop.maxX, accuracy: 0.01)

        o.adjustments[f.url] = CropAdjustment(wholePage: true)
        let whole = try XCTUnwrap(Imposer.plan(files: [f], options: o).first?.pages.first)
        XCTAssertEqual(whole.crop, CGRect(origin: .zero, size: TestPDF.a3))

        // 잘라낸 결과가 페이지 밖으로 나가거나 뒤집히지 않는다.
        o.adjustments[f.url] = CropAdjustment(top: -500, bottom: 900, left: 0, right: 0)
        let silly = try XCTUnwrap(Imposer.plan(files: [f], options: o).first?.pages.first)
        XCTAssertTrue(CGRect(origin: .zero, size: TestPDF.a3).contains(silly.crop))
        XCTAssertGreaterThan(silly.crop.height, 0)
    }

    func testBlankPagePadding() throws {
        let p = TestPDF.Page(size: TestPDF.a3, boxes: [CGRect(x: 100, y: 100, width: 500, height: 800)])
        let three = try file([p, p, p], name: "three")
        let two = try file([p, p], name: "two")
        let one = try file([p], name: "one")

        var o = ImpositionOptions()
        o.padSectionsToEven = true
        var plan = Imposer.plan(files: [three, two, one], options: o)
        XCTAssertEqual(plan.map(\.padsBlankPage), [true, false, false]) // 마지막 파일 뒤에는 기본으로 안 넣는다
        XCTAssertEqual(Imposer.render(plan)?.pageCount, 3 + 1 + 2 + 1)

        o.padEndToEven = true // 양면으로 여러 부
        plan = Imposer.plan(files: [three, two, one], options: o)
        XCTAssertEqual(plan.map(\.padsBlankPage), [true, false, true])
        XCTAssertEqual(Imposer.render(plan)?.pageCount, 8)

        o.padSectionsToEven = false // 단면
        plan = Imposer.plan(files: [three, two, one], options: o)
        XCTAssertEqual(plan.map(\.padsBlankPage), [false, false, false])
    }

    func testRenderMakesA4PagesCenteredInsideMargin() throws {
        let f = try file([.init(size: TestPDF.a3, boxes: [CGRect(x: 80, y: 70, width: 680, height: 1050)])])
        var o = ImpositionOptions()
        o.paperMarginMM = 5
        let result = try XCTUnwrap(Imposer.impose(files: [f], options: o))
        let out = try XCTUnwrap(PDFDocument(data: result.data))
        XCTAssertEqual(out.pageCount, 1)
        let page = try XCTUnwrap(out.page(at: 0))
        let media = page.bounds(for: .mediaBox)
        XCTAssertEqual(media.width, a4Size.width, accuracy: 0.01)
        XCTAssertEqual(media.height, a4Size.height, accuracy: 0.01)

        let ink = try XCTUnwrap(TestPDF.inkRect(of: page, dpi: 144))
        let left = ink.minX, right = media.width - ink.maxX
        let bottom = ink.minY, top = media.height - ink.maxY
        // 잉크는 여백(5mm) + 덧붙인 여유(1.5mm × 배율) 안쪽에, 좌우·위아래 대칭으로 놓인다.
        for m in [left, right, bottom, top] { XCTAssertGreaterThanOrEqual(m, 5 * mm) }
        // 앱은 감지한 영역을 가운데 둔다. 감지는 50dpi라 한 변이 최대 1픽셀(1.44pt)까지 넓게 잡힐 수 있어서
        // 실제 잉크의 좌우·위아래 차이는 그만큼(× 배율) + 측정 오차까지 생길 수 있다.
        XCTAssertEqual(left, right, accuracy: 2.5)
        XCTAssertEqual(top, bottom, accuracy: 2.5)
        // 한쪽 방향은 꽉 차야 한다(배율을 최대로 썼는지).
        XCTAssertEqual(min(left, top), 5 * mm + 1.5 * mm * result.sections[0].scale, accuracy: 1.5)
    }

    /// 회전된 원본도 PDFKit이 보여주는 방향 그대로 A4에 놓여야 한다.
    func testRotatedSourceKeepsDisplayedOrientation() throws {
        // 회전 전 기준 왼쪽 위에 작은 표시, 오른쪽 아래에 큰 상자.
        let boxes = [CGRect(x: 20, y: 520, width: 40, height: 40), CGRect(x: 250, y: 30, width: 120, height: 150)]
        for rotate in [0, 90, 180, 270] {
            let f = try file([.init(size: CGSize(width: 400, height: 600), rotate: rotate, boxes: boxes)],
                             name: "rot\(rotate)")
            let source = try XCTUnwrap(f.document.page(at: 0))
            let out = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(Imposer.impose(files: [f], options: ImpositionOptions())).data))
            XCTAssertEqual(quadrants(source), quadrants(try XCTUnwrap(out.page(at: 0))), "rotate \(rotate)")
        }
    }

    /// 잉크 영역을 네 칸으로 나눠 칸마다 잉크가 있는지(왼위, 오위, 왼아래, 오아래).
    private func quadrants(_ page: PDFPage) -> [Bool] {
        let bounds = page.bounds(for: .cropBox)
        let size = page.rotation % 180 != 0 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard let ink = TestPDF.inkRect(of: page) else { return [] }
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        page.draw(with: .cropBox, to: ctx)
        let buf = ctx.data!.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        func dark(_ r: CGRect) -> Bool {
            for y in Int(r.minY)..<Int(r.maxY) {
                let row = h - 1 - y
                for x in Int(r.minX)..<Int(r.maxX) where buf[row * ctx.bytesPerRow + x] < 128 { return true }
            }
            return false
        }
        let mx = ink.midX, my = ink.midY
        return [
            dark(CGRect(x: ink.minX, y: my, width: mx - ink.minX, height: ink.maxY - my)),
            dark(CGRect(x: mx, y: my, width: ink.maxX - mx, height: ink.maxY - my)),
            dark(CGRect(x: ink.minX, y: ink.minY, width: mx - ink.minX, height: my - ink.minY)),
            dark(CGRect(x: mx, y: ink.minY, width: ink.maxX - mx, height: my - ink.minY)),
        ]
    }

    func testVariantSelectionInPlan() throws {
        let f = try file([
            .init(size: TestPDF.a3, text: "홀수형", boxes: [CGRect(x: 100, y: 100, width: 600, height: 900)]),
            .init(size: TestPDF.a3, text: "2", boxes: [CGRect(x: 100, y: 100, width: 600, height: 900)]),
            .init(size: TestPDF.a3, text: "짝수형", boxes: [CGRect(x: 100, y: 100, width: 600, height: 900)]),
        ])
        var o = ImpositionOptions()
        o.variant = .even
        XCTAssertEqual(Imposer.plan(files: [f], options: o).first?.pageIndices, [2])
        o.variant = .all
        XCTAssertEqual(Imposer.plan(files: [f], options: o).first?.pageIndices, [0, 1, 2])
    }

    func testExpandPDFs() throws {
        let dir = TestPDF.tempDir()
        let fm = FileManager.default
        for name in ["1.pdf", "10.pdf", "2.pdf", "X.PDF", ".hidden.pdf", "._1.pdf", "note.txt"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("sub/3.pdf").path, contents: Data("x".utf8))

        let names = URL.expandPDFs([dir]).map { $0.path.replacingOccurrences(of: dir.standardizedFileURL.path + "/", with: "") }
        XCTAssertEqual(names, ["1.pdf", "2.pdf", "10.pdf", "sub/3.pdf", "X.PDF"])

        // 같은 파일을 두 번 넣어도 한 번만, 없는 경로와 PDF 아닌 파일은 뺀다.
        let again = URL.expandPDFs([dir.appendingPathComponent("2.pdf"), dir, dir.appendingPathComponent("nope.pdf"),
                                    dir.appendingPathComponent("note.txt")])
        XCTAssertEqual(again.count, 5)
        XCTAssertEqual(again.first?.lastPathComponent, "2.pdf")
    }
}
