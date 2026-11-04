import Foundation
import PDFKit
import XCTest

/// mogo-cli 실행 파일을 직접 돌려 본다. 저장소에 들어 있는 예시 문제지(docs/demo)를 쓴다.
final class CLITests: XCTestCase {
    private var demo: URL { TestPDF.repoRoot.appendingPathComponent("docs/demo") }

    private func cli() throws -> URL {
        // swift test는 실행 파일도 같은 폴더(.build/<설정>)에 만든다.
        let dir = Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("mogo-cli")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw XCTSkip("mogo-cli 빌드 없음: \(url.path)") }
        return url
    }

    @discardableResult
    private func run(_ args: [String]) throws -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = try cli()
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    func testHelp() throws {
        let r = try run(["--help"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("사용법"))
        XCTAssertTrue(r.out.contains("--print"))
    }

    func testSummaryOfDemoFolder() throws {
        let r = try run([demo.path])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("예시_국어_문제지: 4쪽 → 2쪽"), r.out)
        XCTAssertTrue(r.out.contains("홀·짝 합본→홀수형"), r.out)
        XCTAssertTrue(r.out.contains("합계: A4 5쪽, 종이 3장"), r.out)
    }

    func testJSON() throws {
        let r = try run(["--json", "--variant", "even", demo.path])
        XCTAssertEqual(r.code, 0, r.err)
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any])
        XCTAssertEqual(doc["output_pages"] as? Int, 5)
        XCTAssertEqual(doc["variant"] as? String, "even")
        let files = try XCTUnwrap(doc["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0]["used_pages"] as? [Int], [3, 4])
        XCTAssertEqual(files[0]["both_variants"] as? Bool, true)
        XCTAssertEqual((files[0]["scale"] as? NSNumber)?.doubleValue ?? 0, 0.80, accuracy: 0.02)
    }

    func testOutputWritesA4PDF() throws {
        let out = TestPDF.tempDir().appendingPathComponent("결과.pdf")
        let r = try run(["--variant", "even", "-o", out.path, demo.appendingPathComponent("예시_국어_문제지.pdf").path])
        XCTAssertEqual(r.code, 0, r.err)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 2)
        let box = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 595.28, accuracy: 0.01)
        XCTAssertEqual(box.height, 841.89, accuracy: 0.01)
    }

    func testPrintDryRunShowsLpCommand() throws {
        // 프린터 이름을 직접 주고 --dry-run이면 실제로 보내지 않는다.
        var r = try run(["-p", "--dry-run", "--printer", "Test_Printer", "--copies", "2", demo.path])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("lp -d Test_Printer -n 2"), r.out)
        XCTAssertTrue(r.out.contains("sides=two-sided-long-edge"))
        XCTAssertTrue(r.out.contains("collate=true"))
        // 양면으로 2부면 마지막 파일 뒤에도 빈 쪽이 들어가 6쪽.
        XCTAssertTrue(r.out.contains("합계: A4 6쪽"), r.out)

        r = try run(["-p", "--dry-run", "--printer", "Test_Printer", "--single-sided", "--color", demo.path])
        XCTAssertTrue(r.out.contains("sides=one-sided"))
        XCTAssertTrue(r.out.contains("print-color-mode=color"))
        XCTAssertTrue(r.out.contains("합계: A4 5쪽, 종이 5장"), r.out)
    }

    func testBadArguments() throws {
        XCTAssertEqual(try run(["--variant", "odd-ish", demo.path]).code, 1)
        XCTAssertEqual(try run(["--no-such-option", demo.path]).code, 1)
        XCTAssertEqual(try run(["/no/such/file.pdf"]).code, 1)
        XCTAssertEqual(try run([]).code, 1)
    }
}
