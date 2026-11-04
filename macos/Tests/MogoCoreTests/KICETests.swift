import Compression
import Foundation
import MogoCore
import PDFKit
import XCTest

final class ZipArchiveTests: XCTestCase {
    private let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    /// 테스트용 ZIP을 직접 만든다. 평가원 ZIP처럼 UTF-8 표시 없이 CP949 이름을 넣을 수 있다.
    private func makeZip(_ items: [(name: Data, utf8: Bool, data: Data, deflate: Bool)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
        var body: [UInt8] = [], central: [UInt8] = []
        for item in items {
            var payload = [UInt8](item.data)
            if item.deflate {
                var out = [UInt8](repeating: 0, count: item.data.count + 1024)
                let n = item.data.withUnsafeBytes { src in
                    compression_encode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!,
                                              item.data.count, nil, COMPRESSION_ZLIB)
                }
                payload = Array(out[0..<n])
            }
            let flags = item.utf8 ? 0x800 : 0, method = item.deflate ? 8 : 0
            let name = [UInt8](item.name), offset = body.count
            body += le32(0x0403_4B50) + le16(20) + le16(flags) + le16(method) + le32(0) + le32(0)
                + le32(payload.count) + le32(item.data.count) + le16(name.count) + le16(0) + name + payload
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(flags) + le16(method) + le32(0) + le32(0)
                + le32(payload.count) + le32(item.data.count) + le16(name.count) + le16(0) + le16(0)
                + le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let eocd = le32(0x0605_4B50) + le16(0) + le16(0) + le16(items.count) + le16(items.count)
            + le32(central.count) + le32(body.count) + le16(0)
        return Data(body + central + eocd)
    }

    func testReadsCP949AndUTF8NamesStoredAndDeflated() throws {
        let text = Data(String(repeating: "모고 프린트 ", count: 400).utf8)
        let zip = makeZip([
            (name: "07 경제_문제.pdf".data(using: cp949)!, utf8: false, data: Data("%PDF-1.4 a".utf8), deflate: false),
            (name: Data("폴더/".utf8), utf8: true, data: Data(), deflate: false),
            (name: Data("폴더/국어영역_홀수형.pdf".utf8), utf8: true, data: text, deflate: true),
        ])
        let entries = try ZipArchive.entries(zip)
        XCTAssertEqual(entries.map(\.path), ["07 경제_문제.pdf", "폴더/국어영역_홀수형.pdf"]) // 폴더 항목은 뺀다
        XCTAssertEqual(entries[1].name, "국어영역_홀수형.pdf")
        XCTAssertEqual(entries[0].data, Data("%PDF-1.4 a".utf8))
        XCTAssertEqual(entries[1].data, text)
    }

    func testRejectsNonZipAndBrokenZip() {
        XCTAssertThrowsError(try ZipArchive.entries(Data("<html>not found</html>".utf8)))
        let good = makeZip([(name: Data("a.pdf".utf8), utf8: true, data: Data("x".utf8), deflate: false)])
        XCTAssertThrowsError(try ZipArchive.entries(good.prefix(20) + good.suffix(22))) // 몸통이 잘린 ZIP
    }

    /// 실제 평가원 ZIP(있을 때만). 파일 이름이 CP949라 macOS 기본 unzip으로는 깨진다.
    func testRealKICEZips() throws {
        guard let dir = TestPDF.samplesDir?.appendingPathComponent("_zips"),
              FileManager.default.fileExists(atPath: dir.path) else { throw XCTSkip("Samples/_zips 없음") }
        let social = try ZipArchive.entries(Data(contentsOf: dir.appendingPathComponent("2026수능_사회탐구영역_문제지.zip")))
        XCTAssertEqual(social.count, 9)
        XCTAssertTrue(social.map(\.name).contains("07 경제_문제.pdf"))
        XCTAssertTrue(social.allSatisfy { $0.data.starts(with: Array("%PDF".utf8)) })
        let korean = try ZipArchive.entries(Data(contentsOf: dir.appendingPathComponent("2022수능_1교시_국어영역_문제지.zip")))
        XCTAssertEqual(Set(korean.map(\.name)), ["국어영역_홀수형.pdf", "국어영역_짝수형.pdf"])
        XCTAssertNotNil(PDFDocument(data: korean[0].data))
    }
}

final class KICEArchiveTests: XCTestCase {
    func testAttachmentKinds() {
        XCTAssertEqual(KICEAttachment.kind(of: "국어영역_문제지.pdf"), .paper)
        XCTAssertEqual(KICEAttachment.kind(of: "국어영역.zip"), .paper)              // 2019: '문제지'라는 말이 없다
        XCTAssertEqual(KICEAttachment.kind(of: "국어영역A형-홀수.pdf"), .paper)      // 2015: A·B형
        XCTAssertEqual(KICEAttachment.kind(of: "1교시_국어영역_정답표.pdf"), .answer)
        XCTAssertEqual(KICEAttachment.kind(of: "정답표_2015_수능_국어A_홀수.pdf"), .answer)
        XCTAssertEqual(KICEAttachment.kind(of: "사회탐구영역_정답.zip"), .answer)
        XCTAssertEqual(KICEAttachment.kind(of: "영어영역듣기평가음원.zip"), .listening)
        XCTAssertEqual(KICEAttachment.kind(of: "영어영역듣기평가대본.pdf"), .listening)
        XCTAssertEqual(KICEAttachment.kind(of: "듣기평가.zip"), .listening)
    }

    func testExamNamesAndURLs() throws {
        XCTAssertEqual(KICEExam(name: "수능"), .suneung)
        XCTAssertEqual(KICEExam(name: "6월"), .june)
        XCTAssertEqual(KICEExam(name: "9월 모평"), .september)
        XCTAssertNil(KICEExam(name: "7월"))
        XCTAssertEqual(KICEExam.suneung.filePrefix(year: 2026), "2026수능")
        XCTAssertEqual(KICEExam.june.filePrefix(year: 2027), "2027_6월모평")

        let q = try XCTUnwrap(URLComponents(url: KICEArchive.listURL(.september, year: 2027), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(q.first { $0.name == "boardID" }?.value, "1500236")
        XCTAssertEqual(q.first { $0.name == "C01" }?.value, "2027")
        XCTAssertEqual(q.first { $0.name == "C02" }?.value, "9월")
        XCTAssertEqual(KICEArchive.downloadURL(KICEAttachment(title: "a.pdf", fileSeq: "abc123")).absoluteString,
                       "https://www.suneung.re.kr/boardCnts/fileDown.do?fileSeq=abc123")
    }

    /// 두 게시판의 표 모양(열 순서가 다르다)을 흉내 낸 HTML로 읽기를 확인한다.
    func testParseBoards() {
        func row(_ cells: [String], files: [(String, String)]) -> String {
            let links = files.map { "<a href='#;' onclick=\"fn_fileDown('\($0.0)');\" title='\($0.1)'><img alt='\($0.1)'></a>" }.joined()
            return "<tr style=\"text-align:center;\">" + cells.map { "<td >\($0)</td>" }.joined() + "<td>\(links)</td></tr>"
        }
        let suneung = """
        <select name="C01" title="학년도"><option value="" >학년도</option><option value="2027" >2027</option><option value="2026" >2026</option></select>
        <table><thead><tr><th>번호</th><th>학년도</th><th>영역</th><th>제목</th><th>등록일</th><th>조회</th><th>파일</th></tr></thead><tbody>
        \(row(["5093801", "2026", "국어", "<a href='#'>문제 및 정답</a>", "2025-11-17", "250459"], files: [("aa11", "국어영역_문제지.pdf"), ("bb22", "국어영역_정답표.pdf")]))
        \(row(["5093796", "2026", "제2외국어/한문", "문제 및 정답", "2025-11-17", "10"], files: [("cc33", "제2외국어한문영역_문제지.zip")]))
        </tbody></table>
        """
        XCTAssertEqual(KICEArchive.parseYears(suneung), [2027, 2026])
        let rows = KICEArchive.parseRows(suneung)
        XCTAssertEqual(rows.map(\.area), ["국어", "제2외국어/한문"])
        XCTAssertEqual(rows[0].year, 2026)
        XCTAssertNil(rows[0].month)
        XCTAssertEqual(rows[0].papers.map(\.fileSeq), ["aa11"])
        XCTAssertEqual(rows[0].answers.map(\.title), ["국어영역_정답표.pdf"])
        XCTAssertTrue(rows[1].hasManySubjects)
        XCTAssertTrue(rows[1].papers[0].isZip)

        // 모의평가 게시판: 학년도 다음에 '월' 열, 파일 열이 조회 앞에 있다.
        let mock = """
        <table><thead><tr><th>번호</th><th>학년도</th><th>월</th><th>영역</th><th>제목</th><th>등록일</th><th>파일</th><th>조회</th></tr></thead>
        <tbody>\(row(["5096543", "2027", "9월", "수학", "문제 및 정답", "2026-09-05"], files: [("dd44", "수학영역_문제지.pdf")]))</tbody></table>
        """
        let m = KICEArchive.parseRows(mock)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].month, "9월")
        XCTAssertEqual(m[0].area, "수학")
        XCTAssertFalse(m[0].hasManySubjects)
    }

    /// 실제 평가원 홈페이지에서 받아 본다. MOGO_NETWORK_TESTS=1일 때만 돈다.
    func testLiveDownload() async throws {
        guard ProcessInfo.processInfo.environment["MOGO_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("MOGO_NETWORK_TESTS=1일 때만 평가원 홈페이지에 접속한다")
        }
        let years = try await KICEArchive.years(.suneung)
        XCTAssertTrue(years.contains(2026))
        let rows = try await KICEArchive.rows(.suneung, year: 2026)
        XCTAssertEqual(rows.map(\.area).prefix(4), ["국어", "수학", "영어", "한국사"])
        let dir = TestPDF.tempDir()
        let history = try XCTUnwrap(rows.first { $0.area == "한국사" }?.papers.first)
        let saved = try await KICEArchive.save(history, exam: .suneung, year: 2026, to: dir)
        XCTAssertEqual(saved.map(\.lastPathComponent), ["2026수능_한국사영역_문제지.pdf"])
        XCTAssertNotNil(SourceFile(url: saved[0]))

        // 2022학년도 국어는 홀·짝 PDF가 ZIP으로 묶여 있다.
        let old = try await KICEArchive.rows(.suneung, year: 2022)
        let zip = try XCTUnwrap(old.first { $0.area == "국어" }?.papers.first)
        let unzipped = try await KICEArchive.save(zip, exam: .suneung, year: 2022, to: dir)
        XCTAssertEqual(Set(unzipped.map(\.lastPathComponent)), ["국어영역_홀수형.pdf", "국어영역_짝수형.pdf"])

        // 모의평가 게시판
        let june = try await KICEArchive.rows(.june, year: 2027)
        XCTAssertTrue(june.allSatisfy { $0.month == "6월" })
        XCTAssertTrue(june.contains { $0.area == "국어" })
    }
}

final class KICEPreselectTests: XCTestCase {
    func testPreselect() {
        let d = URL(fileURLWithPath: "/tmp/x")
        let files: [(url: URL, area: String)] = [
            (d.appendingPathComponent("2026수능_국어영역_문제지.pdf"), "국어"),
            (d.appendingPathComponent("국어영역_홀수형.pdf"), "국어"),
            (d.appendingPathComponent("국어영역_짝수형.pdf"), "국어"),
            (d.appendingPathComponent("07 경제_문제.pdf"), "사회탐구"),
        ]
        let odd = KICEArchive.preselect(files, manySubjectAreas: ["사회탐구"], variant: .odd)
        XCTAssertEqual(odd, [files[0].url, files[1].url])   // 홀수형만, 탐구 과목은 고르지 않음
        let even = KICEArchive.preselect(files, manySubjectAreas: ["사회탐구"], variant: .even)
        XCTAssertEqual(even, [files[0].url, files[2].url])
        let all = KICEArchive.preselect(files, manySubjectAreas: [], variant: .all)
        XCTAssertEqual(all.count, 4)
    }
}
