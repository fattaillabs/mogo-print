import Foundation
import MogoCore
import XCTest

/// 시험지별 기준값(docs/expected/samples.json)과 비교한다. Windows 버전도 같은 파일로 검증해 두 버전의 결과를 맞춘다.
///
/// 값을 새로 쓰려면: `MOGO_UPDATE_GOLDEN=1 swift test --filter GoldenTests`
final class GoldenTests: XCTestCase {
    private let mm = pointsPerMM
    private var goldenURL: URL { TestPDF.repoRoot.appendingPathComponent("docs/expected/samples.json") }

    /// 한 파일을 기본 설정(A4, 종이 여백 5mm, 덧붙임 1.5mm, 홀수형)으로 배치했을 때의 값.
    private func measure(_ url: URL, relativeTo dir: URL) throws -> [String: Any] {
        let file = try XCTUnwrap(SourceFile(url: url), url.lastPathComponent)
        let section = try XCTUnwrap(Imposer.plan(files: [file], options: ImpositionOptions()).first)
        let size = section.pageSize, crop = section.crop
        let labels = file.pageVariants.map { v -> String in
            switch v { case .odd: return "O"; case .even: return "E"; default: return "-" }
        }.joined()
        // JSON에 24.300000000000001처럼 찍히지 않게 소수 한 자리 십진수로 넣는다.
        func r1(_ v: CGFloat) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", Double(v / mm))) }
        return [
            "path": Self.key(url, relativeTo: dir),
            "pages": file.pageCount,
            "labels": labels,
            // 쪽별 선택과목(규칙 3-1): S 화법과 작문, L 언어와 매체, P 확률과 통계, C 미적분, G 기하, - 공통
            "elective_labels": String(file.pageElectives.map { $0?.code ?? "-" }),
            "both_variants": file.hasBothVariants,
            "odd_page_count": file.pageIndices(for: .odd).count,
            "even_page_count": file.pageIndices(for: .even).count,
            "page_size_mm": [r1(size.width), r1(size.height)],
            "crop_margin_mm": ["left": r1(crop.minX), "top": r1(size.height - crop.maxY),
                               "right": r1(size.width - crop.maxX), "bottom": r1(crop.minY)],
            "scale": NSDecimalNumber(string: String(format: "%.4f", Double(section.scale))),
        ]
    }

    /// Samples 기준 상대 경로. 맥 파일명은 NFD라서 윈도우와 같도록 NFC로 맞춘다.
    private static func key(_ url: URL, relativeTo dir: URL) -> String {
        let base = dir.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(base.count)).precomposedStringWithCanonicalMapping
    }

    func testSamplesMatchGolden() throws {
        guard let dir = TestPDF.samplesDir else { throw XCTSkip("Samples 폴더 없음") }
        let urls = URL.expandPDFs([dir])
        let measured = try urls.map { try measure($0, relativeTo: dir) }
            .sorted { ($0["path"] as! String) < ($1["path"] as! String) }

        if ProcessInfo.processInfo.environment["MOGO_UPDATE_GOLDEN"] == "1" {
            let doc: [String: Any] = [
                "about": "모고 프린트 시험지별 기준값. macOS·Windows 버전이 같은 값을 내야 한다. 규칙은 docs/ALGORITHM.md. 허용 오차: 여백 ±1.5mm(렌더러 차이), 배율 ±0.01",
                "settings": ["paper": "A4", "paper_margin_mm": 5, "padding_mm": 1.5, "variant": "odd", "ink_dpi": 50, "ink_threshold": 200],
                "files": measured,
            ]
            try FileManager.default.createDirectory(at: goldenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: goldenURL)
            print("golden written: \(goldenURL.path) (\(measured.count) files)")
            return
        }

        let data = try Data(contentsOf: goldenURL)
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = try XCTUnwrap(golden["files"] as? [[String: Any]])
        let byPath = Dictionary(uniqueKeysWithValues: measured.map { ($0["path"] as! String, $0) })
        XCTAssertEqual(Set(byPath.keys), Set(expected.map { $0["path"] as! String }), "시험지 목록이 기준값과 다름")

        for e in expected {
            let path = e["path"] as! String
            guard let m = byPath[path] else { continue }
            for k in ["pages", "labels", "elective_labels", "both_variants", "odd_page_count", "even_page_count"] {
                // JSON에서 읽은 값은 NSNumber라서 객체 비교로 본다(true와 1을 같게).
                XCTAssertTrue((m[k]! as AnyObject).isEqual(e[k]!), "\(path) \(k): \(m[k]!) ≠ \(e[k]!)")
            }
            func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? .nan }
            XCTAssertEqual(num(m["scale"]), num(e["scale"]), accuracy: 0.01, "\(path) scale")
            let mc = m["crop_margin_mm"] as! [String: Any], ec = e["crop_margin_mm"] as! [String: Any]
            for side in ["left", "top", "right", "bottom"] {
                XCTAssertEqual(num(mc[side]), num(ec[side]), accuracy: 1.0, "\(path) \(side)")
            }
        }
    }
}
