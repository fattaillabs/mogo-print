import MogoCore
import PDFKit
import XCTest

final class AnalyzerTests: XCTestCase {
    func testVariantLabelVariants() {
        XCTAssertEqual(ExamAnalyzer.variantLabel(in: "제1교시 국어 영역 홀수형"), .odd)
        XCTAssertEqual(ExamAnalyzer.variantLabel(in: "짝 수 형"), .even)
        // 정답표 표기 "( 홀수 )형"
        XCTAssertEqual(ExamAnalyzer.variantLabel(in: "국어 영역 정답표\n( 홀수 )형"), .odd)
        XCTAssertEqual(ExamAnalyzer.variantLabel(in: "(짝수)형"), .even)
        // 둘 다 있거나 없으면 라벨이 아니다.
        XCTAssertNil(ExamAnalyzer.variantLabel(in: "홀수형/짝수형을 확인하시오"))
        XCTAssertNil(ExamAnalyzer.variantLabel(in: "수학 영역"))
        XCTAssertNil(ExamAnalyzer.variantLabel(in: ""))
    }

    func testPropagateKeepsLeadingPagesUnlabeled() {
        let labels: [ExamVariant?] = [nil, .odd, nil, nil, .even, nil]
        XCTAssertEqual(ExamAnalyzer.propagate(labels), [nil, .odd, .odd, .odd, .even, .even])
    }

    func testCombinedFileSplitsByVariantAndKeepsCover() throws {
        let url = TestPDF.tempDir().appendingPathComponent("combined.pdf")
        TestPDF.make([
            .init(size: TestPDF.a3, text: "표지"),
            .init(size: TestPDF.a3, text: "국어 영역 홀수형"),
            .init(size: TestPDF.a3, text: "2쪽"),
            .init(size: TestPDF.a3, text: "국어 영역 짝수형"),
            .init(size: TestPDF.a3, text: "2쪽"),
        ], at: url)
        let file = try XCTUnwrap(SourceFile(url: url))
        XCTAssertEqual(file.pageCount, 5)
        XCTAssertTrue(file.hasBothVariants)
        XCTAssertEqual(file.pageVariants, [nil, .odd, .odd, .even, .even])
        // 표지(라벨 앞)는 어느 형에도 들어간다.
        XCTAssertEqual(file.pageIndices(for: .odd), [0, 1, 2])
        XCTAssertEqual(file.pageIndices(for: .even), [0, 3, 4])
        XCTAssertEqual(file.pageIndices(for: .all), [0, 1, 2, 3, 4])
    }

    func testSingleVariantFileKeepsAllPages() throws {
        let url = TestPDF.tempDir().appendingPathComponent("odd-only.pdf")
        TestPDF.make([.init(size: TestPDF.a3, text: "홀수형"), .init(size: TestPDF.a3, text: "2쪽")], at: url)
        let file = try XCTUnwrap(SourceFile(url: url))
        XCTAssertFalse(file.hasBothVariants)
        // 짝수형을 골라도 한 형만 있는 파일은 통째로 쓴다.
        XCTAssertEqual(file.pageIndices(for: .even), [0, 1])
    }

    func testInkBoundsMatchesDrawnBox() throws {
        let box = CGRect(x: 100, y: 200, width: 150, height: 300)
        let url = TestPDF.tempDir().appendingPathComponent("box.pdf")
        TestPDF.make([.init(size: TestPDF.a4, boxes: [box])], at: url)
        let file = try XCTUnwrap(SourceFile(url: url))
        // 50dpi 렌더링이라 한 픽셀(1.44pt) 정도 오차.
        XCTAssertRectEqual(file.inkBounds[0], box, accuracy: 1.5)
    }

    func testBlankPageHasNoInk() throws {
        let url = TestPDF.tempDir().appendingPathComponent("blank.pdf")
        TestPDF.make([.init(size: TestPDF.a4)], at: url)
        let file = try XCTUnwrap(SourceFile(url: url))
        XCTAssertNil(file.inkBounds[0])
    }

    /// /Rotate가 있는 페이지는 화면에 보이는 방향(PDFKit과 같은 방향)으로 잉크 영역을 잡아야 한다.
    func testRotatedPageInkBoundsMatchPDFKitDisplay() throws {
        let dir = TestPDF.tempDir()
        for rotate in [90, 180, 270] {
            let url = dir.appendingPathComponent("rot\(rotate).pdf")
            TestPDF.make([.init(size: CGSize(width: 400, height: 600), rotate: rotate,
                                boxes: [CGRect(x: 20, y: 30, width: 60, height: 40)])], at: url)
            let file = try XCTUnwrap(SourceFile(url: url))
            let expectedSize = rotate == 180 ? CGSize(width: 400, height: 600) : CGSize(width: 600, height: 400)
            XCTAssertEqual(file.geometry[0].size, expectedSize, "rotate \(rotate)")
            let page = try XCTUnwrap(file.document.page(at: 0))
            let displayed = try XCTUnwrap(TestPDF.inkRect(of: page))
            XCTAssertRectEqual(file.inkBounds[0], displayed, accuracy: 2, "rotate \(rotate)")
        }
    }

    func testLockedOrBrokenFileReturnsNil() {
        let dir = TestPDF.tempDir()
        let broken = dir.appendingPathComponent("broken.pdf")
        try? Data("not a pdf".utf8).write(to: broken)
        XCTAssertNil(SourceFile(url: broken))

        let src = TestPDF.make([.init(size: TestPDF.a4, text: "비밀")], at: dir.appendingPathComponent("plain.pdf"))
        let doc = PDFDocument(url: src)!
        let locked = dir.appendingPathComponent("locked.pdf")
        XCTAssertTrue(doc.write(to: locked, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"]))
        XCTAssertNil(SourceFile(url: locked))
    }

    func testLoadKeepsOrderAndMarksFailures() {
        let dir = TestPDF.tempDir()
        let a = TestPDF.make([.init(size: TestPDF.a4, text: "가")], at: dir.appendingPathComponent("a.pdf"))
        let bad = dir.appendingPathComponent("bad.pdf")
        try? Data("x".utf8).write(to: bad)
        let b = TestPDF.make([.init(size: TestPDF.a4, text: "나"), .init(size: TestPDF.a4)], at: dir.appendingPathComponent("b.pdf"))
        let loaded = SourceFile.load([a, bad, b])
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[0]?.pageCount, 1)
        XCTAssertNil(loaded[1])
        XCTAssertEqual(loaded[2]?.pageCount, 2)
    }

    /// 여러 스레드로 나눠 분석해도 순차 분석과 같은 결과여야 한다(쪽수가 많아 스레드가 여러 개 쓰이는 경우).
    func testParallelAnalysisMatchesSequential() throws {
        var pages: [TestPDF.Page] = []
        for i in 0..<40 {
            pages.append(.init(size: TestPDF.a3, text: i == 0 ? "홀수형" : (i == 20 ? "짝수형" : "\(i)쪽"),
                               boxes: [CGRect(x: 50 + CGFloat(i), y: 60, width: 300, height: 400 + CGFloat(i))]))
        }
        let url = TestPDF.make(pages, at: TestPDF.tempDir().appendingPathComponent("big.pdf"))
        let file = try XCTUnwrap(SourceFile(url: url))
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(file.pageVariants, ExamAnalyzer.detectVariants(doc))
        for i in 0..<doc.pageCount {
            let seq = ExamAnalyzer.inkBounds(of: doc.page(at: i)!)
            XCTAssertEqual(file.inkBounds[i], seq, "page \(i)")
        }
        XCTAssertEqual(file.pageIndices(for: .odd).count, 20)
        XCTAssertEqual(file.pageIndices(for: .even).count, 20)
    }
}

final class ElectiveTests: XCTestCase {
    func testElectiveLabel() {
        XCTAssertEqual(ExamAnalyzer.electiveLabel(in: "2026학년도 대학수학능력시험 문제지\n1\n(화법과 작문)\n제1교시"), .speechWriting)
        XCTAssertEqual(ExamAnalyzer.electiveLabel(in: "4 (언어와 매체) 홀수형"), .languageMedia)
        XCTAssertEqual(ExamAnalyzer.electiveLabel(in: "수학 영역（확률과 통계）"), .probability) // 전각 괄호
        XCTAssertEqual(ExamAnalyzer.electiveLabel(in: "( 미 적 분 )"), .calculus)               // 띄어쓰기 무시
        XCTAssertEqual(ExamAnalyzer.electiveLabel(in: "(기하)"), .geometry)
        // 공통 마지막 쪽의 안내문은 선택과목 쪽이 아니다.
        XCTAssertNil(ExamAnalyzer.electiveLabel(in: "◦이어서, ｢선택과목(화법과 작문)｣ 문제가 제시되오니, 자신이 선택한 과목인지 확인하시오."))
        // 선택과목 쪽 안에 다음 과목 안내가 있어도 그 쪽의 과목으로 본다.
        XCTAssertEqual(ExamAnalyzer.electiveLabel(in: "4 (화법과 작문) 홀수형 … 「선택과목(언어와 매체)」 문제가 제시되오니"), .speechWriting)
        // 괄호 없이 지문에 나온 낱말, 두 과목이 함께 나오는 쪽은 판정하지 않는다.
        XCTAssertNil(ExamAnalyzer.electiveLabel(in: "기하학적 무늬와 미적분의 역사"))
        XCTAssertNil(ExamAnalyzer.electiveLabel(in: "(확률과 통계) (기하)"))
        XCTAssertNil(ExamAnalyzer.electiveLabel(in: "국어 영역"))
    }

    func testElectiveNames() {
        XCTAssertEqual(Elective(name: "언매"), .languageMedia)
        XCTAssertEqual(Elective(name: "언어와 매체"), .languageMedia)
        XCTAssertEqual(Elective(name: "확률과통계"), .probability)
        XCTAssertNil(Elective(name: "물리학"))
        XCTAssertEqual(ElectiveSubject.korean.electives, [.speechWriting, .languageMedia])
        XCTAssertEqual(ElectiveSubject.math.electives, [.probability, .calculus, .geometry])
    }

    /// 홀·짝 합본에 선택과목까지 든 파일: 형과 선택과목을 함께 고른다. 공통 쪽은 언제나 들어간다.
    func testVariantAndElectiveTogether() throws {
        let box = [CGRect(x: 100, y: 100, width: 600, height: 900)]
        var pages: [TestPDF.Page] = []
        for v in ["홀수형", "짝수형"] {
            pages.append(.init(size: TestPDF.a3, text: "국어 영역 \(v)", boxes: box))
            pages.append(.init(size: TestPDF.a3, text: "이어서 「선택과목(화법과 작문)」", boxes: box))
            pages.append(.init(size: TestPDF.a3, text: "(화법과 작문)", boxes: box))
            pages.append(.init(size: TestPDF.a3, text: "(언어와 매체)", boxes: box))
        }
        let url = TestPDF.make(pages, at: TestPDF.tempDir().appendingPathComponent("k.pdf"))
        let f = try XCTUnwrap(SourceFile(url: url))
        XCTAssertEqual(f.pageElectives, [nil, nil, .speechWriting, .languageMedia, nil, nil, .speechWriting, .languageMedia])
        XCTAssertEqual(f.electives, [.speechWriting, .languageMedia])
        XCTAssertEqual(f.electiveSubject, .korean)

        var o = ImpositionOptions()
        XCTAssertEqual(f.pageIndices(for: o), [0, 1, 2, 3])          // 홀수형, 선택과목 전체
        o.electives[.korean] = .languageMedia
        XCTAssertEqual(f.pageIndices(for: o), [0, 1, 3])
        o.variant = .even
        XCTAssertEqual(f.pageIndices(for: o), [4, 5, 7])
        o.electives[.math] = .calculus                                // 다른 과목 선택은 영향 없음
        XCTAssertEqual(f.pageIndices(for: o), [4, 5, 7])
        o.variant = .all
        XCTAssertEqual(f.pageIndices(for: o), [0, 1, 3, 4, 5, 7])
        XCTAssertEqual(Imposer.plan(files: [f], options: o).first?.pageIndices, [0, 1, 3, 4, 5, 7])
    }
}
