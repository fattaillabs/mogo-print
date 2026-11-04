import MogoCore
import XCTest

final class CropGuidesTests: XCTestCase {
    private let mm = pointsPerMM

    private func file() throws -> SourceFile {
        let url = TestPDF.make([
            .init(size: TestPDF.a3, boxes: [CGRect(x: 80, y: 70, width: 680, height: 1050)]),
            .init(size: TestPDF.a3, boxes: [CGRect(x: 90, y: 90, width: 600, height: 1000)]),
        ], at: TestPDF.tempDir().appendingPathComponent("g.pdf"))
        return try XCTUnwrap(SourceFile(url: url))
    }

    /// 수동 조정 화면이 쓰는 계산은 실제 배치와 같은 값을 내야 한다.
    func testScreenMathMatchesPlan() throws {
        let f = try file()
        var o = ImpositionOptions()
        for adjust in [CropAdjustment(), CropAdjustment(top: 12.5, bottom: -3), CropAdjustment(wholePage: true)] {
            o.adjustments[f.url] = adjust
            let placed = try XCTUnwrap(Imposer.plan(files: [f], options: o).first?.pages.first)
            XCTAssertEqual(Imposer.crop(file: f, pageIndex: 0, options: o), placed.crop, "\(adjust)")
            XCTAssertEqual(Imposer.scale(for: placed.crop, options: o), placed.scale, accuracy: 1e-9)
        }
        // 기준(자동) 범위는 손 조정과 상관없다.
        o.adjustments[f.url] = CropAdjustment(top: 12.5)
        let base = Imposer.baseCrop(file: f, pageIndex: 0, options: o)
        o.adjustments[f.url] = nil
        XCTAssertEqual(base, Imposer.baseCrop(file: f, pageIndex: 0, options: o))
    }

    func testGuidesStayInsidePageAndApart() {
        let page = CGSize(width: 842, height: 1190)
        let c = CGRect(x: 80, y: 100, width: 680, height: 900) // 왼80 오760 아래100 위1000
        var r = CropGuides.move(.top, to: 5000, crop: c, pageSize: page)
        XCTAssertEqual(r.maxY, page.height)                       // 페이지 위로 못 나감
        XCTAssertEqual(r.minY, c.minY)                            // 나머지 변은 그대로
        XCTAssertEqual(r.minX, c.minX)
        XCTAssertEqual(r.maxX, c.maxX)
        r = CropGuides.move(.top, to: 50, crop: c, pageSize: page)
        XCTAssertEqual(r.maxY, c.minY + CropGuides.minGap, accuracy: 0.001) // 아래 점선과 최소 간격
        r = CropGuides.move(.bottom, to: -40, crop: c, pageSize: page)
        XCTAssertEqual(r.minY, 0)
        r = CropGuides.move(.bottom, to: 990, crop: c, pageSize: page)
        XCTAssertEqual(r.minY, c.maxY - CropGuides.minGap, accuracy: 0.001)
        r = CropGuides.move(.left, to: -10, crop: c, pageSize: page)
        XCTAssertEqual(r.minX, 0)                                 // 페이지 왼쪽 밖으로 못 나감
        r = CropGuides.move(.left, to: 755, crop: c, pageSize: page)
        XCTAssertEqual(r.minX, c.maxX - CropGuides.minGap, accuracy: 0.001)
        r = CropGuides.move(.right, to: 2000, crop: c, pageSize: page)
        XCTAssertEqual(r.maxX, page.width)
        r = CropGuides.move(.right, to: 100, crop: c, pageSize: page)
        XCTAssertEqual(r.maxX, c.minX + CropGuides.minGap, accuracy: 0.001)
        r = CropGuides.move(.right, to: 700, crop: c, pageSize: page)
        XCTAssertEqual(r, CGRect(x: 80, y: 100, width: 620, height: 900))
    }

    func testGuidePositionToAdjustmentRoundTrip() throws {
        let f = try file()
        var o = ImpositionOptions()
        let base = Imposer.baseCrop(file: f, pageIndex: 0, options: o)
        // 위 점선 10mm 아래로, 아래 점선 4mm 아래로(여백 더 남김), 왼쪽 6mm 안으로, 오른쪽 2mm 밖으로.
        let crop = CGRect(x: base.minX + 6 * mm, y: base.minY - 4 * mm,
                          width: base.width - 6 * mm + 2 * mm, height: base.height - 10 * mm + 4 * mm)
        let a = CropGuides.adjustment(crop: crop, base: base, keeping: CropAdjustment(wholePage: false))
        XCTAssertEqual(a.top, 10)
        XCTAssertEqual(a.bottom, -4)
        XCTAssertEqual(a.left, 6)
        XCTAssertEqual(a.right, -2)
        // 그 값으로 배치하면 점선 위치가 그대로 자르는 선이 된다(페이지 안인 범위에서).
        o.adjustments[f.url] = a
        let placed = Imposer.crop(file: f, pageIndex: 0, options: o)
        let page = CGRect(origin: .zero, size: f.geometry[0].size)
        let expected = crop.intersection(page)
        XCTAssertEqual(placed.minX, expected.minX, accuracy: 0.01)
        XCTAssertEqual(placed.maxX, expected.maxX, accuracy: 0.01)
        XCTAssertEqual(placed.minY, expected.minY, accuracy: 0.01)
        XCTAssertEqual(placed.maxY, expected.maxY, accuracy: 0.01)
        // 0.5mm 단위로 반올림하고, '자동 자르기 끄기'는 그대로 둔다.
        let r = CropGuides.adjustment(crop: base.insetBy(dx: 1.2 * mm, dy: 3.3 * mm), base: base,
                                      keeping: CropAdjustment(wholePage: true))
        XCTAssertEqual(r.top, 3.5)
        XCTAssertEqual(r.left, 1)
        XCTAssertTrue(r.wholePage)
    }
}
