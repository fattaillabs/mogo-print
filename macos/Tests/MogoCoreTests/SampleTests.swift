import MogoCore
import PDFKit
import XCTest

/// 실제 평가원·교육청 기출 PDF로 하는 시험. `Samples/` 폴더가 없으면 건너뛴다(저작권 때문에 git에 안 넣음).
final class SampleTests: XCTestCase {
    private let mm = pointsPerMM

    private func sample(_ path: String) throws -> URL {
        guard let dir = TestPDF.samplesDir else { throw XCTSkip("Samples 폴더 없음") }
        let url = dir.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(path) 없음") }
        return url
    }

    func testSuneung2026KoreanCombinedOddEven() throws {
        let file = try XCTUnwrap(SourceFile(url: try sample("2026수능_국어_문제지.pdf")))
        XCTAssertEqual(file.pageCount, 40)
        XCTAssertTrue(file.hasBothVariants)
        let odd = file.pageIndices(for: .odd), even = file.pageIndices(for: .even)
        XCTAssertEqual(odd, Array(0..<20))
        XCTAssertEqual(even, Array(20..<40))
        // 원본에서 뽑은 글자는 "홀 수 형"처럼 띄어져 나오므로 앱과 같은 판정 함수로 본다.
        XCTAssertEqual(ExamAnalyzer.variantLabel(in: file.document.page(at: odd[0])?.string ?? ""), .odd)
        XCTAssertEqual(ExamAnalyzer.variantLabel(in: file.document.page(at: even[0])?.string ?? ""), .even)

        var o = ImpositionOptions()
        o.variant = .even
        let result = try XCTUnwrap(Imposer.impose(files: [file], options: o))
        XCTAssertEqual(result.pageCount, 20)
        XCTAssertEqual(result.sections[0].scale, 0.80, accuracy: 0.015)
        // 원본을 이미지로 굽지 않고 벡터 그대로 그린다. 그 증거로 결과 쪽에 텍스트 객체가 남아 있다.
        // (본문은 한컴 PDF의 글자 대응표 'Unidocs-HWP2002-UCS2'를 Quartz가 못 옮겨서 글자 추출이 안 되고,
        //  표준 글꼴로 된 저작권 줄만 읽힌다. 인쇄 모양에는 영향 없음.)
        let out = try XCTUnwrap(PDFDocument(data: result.data))
        XCTAssertTrue(out.page(at: 0)?.string?.contains("저작권") ?? false)
    }

    func testSeparateOddEvenFilesKeepAllPages() throws {
        let odd = try XCTUnwrap(SourceFile(url: try sample("2019수능_국어/국어_홀.pdf")))
        let even = try XCTUnwrap(SourceFile(url: try sample("2019수능_국어/국어_짝.pdf")))
        XCTAssertFalse(odd.hasBothVariants)
        XCTAssertFalse(even.hasBothVariants)
        var o = ImpositionOptions()
        o.variant = .odd
        // 형을 골라도 한 형만 든 파일은 통째로 쓴다.
        XCTAssertEqual(Imposer.plan(files: [odd, even], options: o).map { $0.pageIndices.count }, [16, 16])
    }

    func testInquirySubjectsHaveNarrowRightMargin() throws {
        let dir = try sample("2026수능_사회탐구_문제지")
        let urls = URL.expandPDFs([dir])
        XCTAssertEqual(urls.count, 9)
        let files = SourceFile.load(urls).compactMap { $0 }
        XCTAssertEqual(files.count, 9)
        for s in Imposer.plan(files: files, options: ImpositionOptions()) {
            XCTAssertEqual(s.pages.count, 4, s.file.name)
            // 오른쪽 과목 탭 때문에 오른쪽 여백이 왼쪽보다 훨씬 좁다.
            let right = s.pageSize.width - s.crop.maxX
            XCTAssertLessThan(right, s.crop.minX - 8 * mm, s.file.name)
            XCTAssertEqual(s.scale, 0.79, accuracy: 0.015, s.file.name)
        }
    }

    func testAnswerSheetSplitsByVariantAndIsNotEnlarged() throws {
        let file = try XCTUnwrap(SourceFile(url: try sample("2026수능_국어_정답표.pdf")))
        XCTAssertEqual(file.pageCount, 2)
        XCTAssertTrue(file.hasBothVariants, "정답표의 \"( 홀수 )형\" 표기를 인식해야 함")
        let plan = Imposer.plan(files: [file], options: ImpositionOptions())
        XCTAssertEqual(plan[0].pageIndices, [0])
        XCTAssertEqual(plan[0].scale, 1, accuracy: 0.0001)
    }

    /// 모든 샘플을 한꺼번에 A4로 만들고, 모든 쪽이 A4이며 내용이 종이 여백 안에 있는지 본다.
    func testAllSamplesFitInsideA4Margins() throws {
        guard let dir = TestPDF.samplesDir else { throw XCTSkip("Samples 폴더 없음") }
        let urls = URL.expandPDFs([dir])
        XCTAssertGreaterThanOrEqual(urls.count, 20)
        let files = SourceFile.load(urls).compactMap { $0 }
        XCTAssertEqual(files.count, urls.count, "열지 못한 샘플이 있음")

        var o = ImpositionOptions()
        o.variant = .odd
        o.paperMarginMM = 5
        let result = try XCTUnwrap(Imposer.impose(files: files, options: o))
        let out = try XCTUnwrap(PDFDocument(data: result.data))
        XCTAssertEqual(out.pageCount, result.pageCount)
        XCTAssertEqual(result.pageCount, result.sections.reduce(0) { $0 + $1.outputPageCount })

        for s in result.sections {
            XCTAssertGreaterThan(s.scale, 0.75, s.file.name)
            XCTAssertLessThanOrEqual(s.scale, 1, s.file.name)
        }
        // 30쪽마다 하나씩 그려서 여백을 잰다(전부 그리면 느리다).
        for i in stride(from: 0, to: out.pageCount, by: 30) {
            let page = try XCTUnwrap(out.page(at: i))
            let media = page.bounds(for: .mediaBox)
            XCTAssertEqual(media.size.width, a4Size.width, accuracy: 0.01)
            XCTAssertEqual(media.size.height, a4Size.height, accuracy: 0.01)
            guard let ink = TestPDF.inkRect(of: page, dpi: 72) else { continue } // 빈 쪽
            let margins = [ink.minX, media.width - ink.maxX, ink.minY, media.height - ink.maxY]
            XCTAssertGreaterThanOrEqual(margins.min() ?? 0, 5 * mm - 1, "page \(i) margins \(margins.map { $0 / mm })")
        }
    }

    func testMockExamFilesFromKICEAndEducationOffice() throws {
        for path in ["2027_6월모평_국어_문제지.pdf", "2027_9월모평_수학_문제지.pdf", "참고_2026_7월학평(교육청)_국어_문제지.pdf"] {
            let file = try XCTUnwrap(SourceFile(url: try sample(path)), path)
            XCTAssertEqual(file.pageCount, 20, path)
            let s = try XCTUnwrap(Imposer.plan(files: [file], options: ImpositionOptions()).first)
            XCTAssertEqual(s.pageSize.width, 841.89, accuracy: 1, path) // A3
            XCTAssertEqual(s.scale, 0.81, accuracy: 0.02, path)
        }
    }
}
