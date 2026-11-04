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
        let h: CGFloat = 1190
        var g = CropGuides.move(.top, to: 5000, top: 1000, bottom: 100, pageHeight: h)
        XCTAssertEqual(g.top, h)                                  // 페이지 위로 못 나감
        g = CropGuides.move(.top, to: 50, top: 1000, bottom: 100, pageHeight: h)
        XCTAssertEqual(g.top, 100 + CropGuides.minGap, accuracy: 0.001) // 아래 점선과 최소 간격
        g = CropGuides.move(.bottom, to: -40, top: 1000, bottom: 100, pageHeight: h)
        XCTAssertEqual(g.bottom, 0)                               // 페이지 아래로 못 나감
        g = CropGuides.move(.bottom, to: 990, top: 1000, bottom: 100, pageHeight: h)
        XCTAssertEqual(g.bottom, 1000 - CropGuides.minGap, accuracy: 0.001)
        g = CropGuides.move(.bottom, to: 300, top: 1000, bottom: 100, pageHeight: h)
        XCTAssertEqual(g.top, 1000)                               // 다른 점선은 그대로
        XCTAssertEqual(g.bottom, 300)
    }

    func testGuidePositionToAdjustmentRoundTrip() throws {
        let f = try file()
        var o = ImpositionOptions()
        let base = Imposer.baseCrop(file: f, pageIndex: 0, options: o)
        // 위 점선을 10mm 내리고 아래 점선을 4mm 내리면(여백을 더 남김) 위 +10, 아래 -4.
        let old = CropAdjustment(left: 2, right: 3)
        let a = CropGuides.adjustment(top: base.maxY - 10 * mm, bottom: base.minY - 4 * mm, base: base, keeping: old)
        XCTAssertEqual(a.top, 10)
        XCTAssertEqual(a.bottom, -4)
        XCTAssertEqual(a.left, 2)   // 좌우는 그대로
        XCTAssertEqual(a.right, 3)
        // 그 값으로 배치하면 점선 위치가 그대로 자르는 선이 된다.
        o.adjustments[f.url] = a
        let crop = Imposer.crop(file: f, pageIndex: 0, options: o)
        XCTAssertEqual(crop.maxY, base.maxY - 10 * mm, accuracy: 0.01)
        XCTAssertEqual(crop.minY, base.minY - 4 * mm, accuracy: 0.01)
        // 0.5mm 단위로 반올림한다.
        let r = CropGuides.adjustment(top: base.maxY - 3.3 * mm, bottom: base.minY + 1.8 * mm, base: base, keeping: CropAdjustment())
        XCTAssertEqual(r.top, 3.5)
        XCTAssertEqual(r.bottom, 2)
    }
}
