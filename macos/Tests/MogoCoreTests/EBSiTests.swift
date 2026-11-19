import Foundation
import MogoCore
import XCTest

/// EBSi 기출문제 페이지·목록 읽기. EBSi 내용은 옮기지 않고 확인한 구조(줄 상자, 왼쪽 칸 글, 버튼 함수)만 흉내 낸 HTML로 시험한다.
final class EBSiTests: XCTestCase {
    private let page = """
    <script>var loginTF = 'true'; var first = 'true';</script>
    <form name="paperListFrm"><input type="hidden" name="targetCd" value="D300"/></form>
    <input type="checkbox" name="year" id="year2026" value="2026"><input type="checkbox" name="year" id="year2025" value="2025">
    <input type="hidden" name="korArOrd" value="1"/>
    <input type="checkbox" name="sFormPartKor" value="140117"><input type="checkbox" name="sFormPartKor" value="140118">
    <input type="checkbox" name="sFormPartKor" value="korPast">
    <input type="hidden" name="mathArOrd" value="2"/>
    <input type="checkbox" name="sFormPartMath" value="140119"><input type="checkbox" name="sFormPartMath" value="140120">
    <input type="hidden" name="engArOrd" value="3"/><input type="checkbox" name="sFormPartEng" value="80003">
    <input type="hidden" name="srch1ArOrd" value="5"/><input type="checkbox" name="sFormPartSoc" value="63002">
    """

    private func row(_ left: String, _ calls: String) -> String {
        """
        <div class="qus_box kor"><div class="qus_inner left"><p>\(left)</p><span>자료다운</span>\(calls)</div>
        <div class="qus_inner right"><a onclick="paperOn('1', 'x', '0', '2026');">응시하기</a></div></div>
        """
    }

    private func p(_ path: String, _ subj: String, even: String = "0") -> String {
        "<a onclick=\"goDownLoadP('\(path)', '/w', '202610203', '301', '2', '\(subj)', '\(even)', '\(path.dropLast(4))', '1');\">문제</a>"
    }
    private func h(_ path: String) -> String { "<a onclick=\"goDownLoadH('\(path)', '/w', '202610203', '301', '2', '1', '0', 'x');\">해설</a>" }
    private func j() -> String { "<a onclick=\"goDownLoadJ('https://wdown/x.png', '/w', '1', '1', '1', '1', '0', 'h', 't', '1');\">정답</a>" }

    func testParsePage() {
        let info = EBSiArchive.parsePage(page)
        XCTAssertTrue(info.loggedIn)
        XCTAssertEqual(info.years, [2026, 2025])
        XCTAssertEqual(info.areas.map(\.name), ["국어", "수학", "영어", "사회탐구"])
        XCTAssertEqual(info.areas[0].order, "1")
        XCTAssertEqual(info.areas[0].subjectIDs, ["140117", "140118", "korPast"])
        XCTAssertFalse(EBSiArchive.parsePage(page.replacingOccurrences(of: "'true'", with: "'false'")).loggedIn)
        XCTAssertFalse(EBSiArchive.parsePage("<html>점검 중</html>").loggedIn)
    }

    func testParseRows() {
        let html = "<p>기출문제 목록 총 5개가 검색 되었습니다.</p>"
            + row("2026 10월 국어 고3 10월 학평(서울) 화법과 작문",
                  p("/20261020/go3/korA_1_mun_AAA.pdf", "140117") + j() + h("/20261020/go3/korA_1_hsj_BBB.pdf"))
            + row("2026 10월 수학 고3 10월 학평(서울) 미적분", p("/20261020/go3/mathB_1_mun_CCC.pdf", "140120"))
            + row("2026 10월 과탐 고1 10월 학평(경기) 통합과학", p("/20261020/go1/g_sci_mun_DDD.pdf", "1"))
            + row("2025 11월 국어 2026학년도 대학수학능력시험 언어와 매체 짝수형",
                  p("/20251113/go3/korB_2_mun_EEE.pdf", "140118", even: "1"))
            + row("2026 10월 영어 고3 10월 학평(서울) 영어", "<a onclick=\"goDownLoadR('/x.mp3');\">듣기</a>") // 문제지 없음
        XCTAssertEqual(EBSiArchive.parseTotal(html), 5)
        let rows = EBSiArchive.parseRows(html)
        XCTAssertEqual(rows.count, 4)
        guard rows.count == 4 else { return }

        let k = rows[0]
        XCTAssertEqual(k.year, 2026)
        XCTAssertEqual(k.month, 10)
        XCTAssertEqual(k.area, "국어")
        XCTAssertEqual(k.grade, 3)
        XCTAssertEqual(k.exam, "10월 학평(서울)")
        XCTAssertEqual(k.office, "서울")
        XCTAssertEqual(k.subject, "화법과 작문")
        XCTAssertEqual(k.elective, .speechWriting)
        XCTAssertEqual(k.subjectID, "140117")
        XCTAssertTrue(k.isEducationOffice)
        XCTAssertEqual(k.paperURL.absoluteString, "https://wdown.ebsi.co.kr/W61001/01exam/20261020/go3/korA_1_mun_AAA.pdf")
        XCTAssertEqual(k.explanationURL?.absoluteString, "https://wdown.ebsi.co.kr/W61001/01exam/20261020/go3/korA_1_hsj_BBB.pdf")
        XCTAssertNil(rows[1].explanationURL)
        XCTAssertEqual(rows[2].grade, 1)
        XCTAssertEqual(rows[2].office, "경기")
        XCTAssertEqual(rows[2].subject, "통합과학")

        let s = rows[3] // 수능은 학평이 아니다
        XCTAssertFalse(s.isEducationOffice)
        XCTAssertNil(s.grade)
        XCTAssertEqual(s.exam, "2026학년도 대학수학능력시험")
        XCTAssertEqual(s.subject, "언어와 매체")
        XCTAssertEqual(s.variant, .even)
    }

    func testMonthsAndNames() {
        let html = row("2026 10월 국어 고3 10월 학평(서울) 언어와 매체", p("/a/k1.pdf", "1"))
            + row("2026 10월 국어 고3 10월 학평(서울) 화법과 작문", p("/a/k2.pdf", "1"))
            + row("2026 9월 국어 2027학년도 9월 모의평가 언어와 매체", p("/a/k3.pdf", "1"))
            + row("2026 7월 국어 고3 7월 학평(인천) 화법과 작문", p("/a/k4.pdf", "1"))
        let rows = EBSiArchive.parseRows(html)
        XCTAssertEqual(rows.count, 4)
        guard rows.count == 4 else { return }
        let months = EBSiArchive.educationOfficeMonths(rows)
        XCTAssertEqual(months.map(\.month), [10, 7])          // 모평(9월)은 빼고 최근 달부터
        XCTAssertEqual(months.map(\.exam), ["10월 학평(서울)", "7월 학평(인천)"])

        XCTAssertEqual(EBSiArchive.fileName(rows[1], explanation: false), "2026_10월학평_고3_국어_화법과작문_문제지.pdf")
        XCTAssertEqual(EBSiArchive.fileName(rows[1], explanation: true), "2026_10월학평_고3_국어_화법과작문_해설.pdf")
        XCTAssertEqual(EBSiArchive.folder(rows[3], base: URL(fileURLWithPath: "/b")).lastPathComponent, "2026년 7월 고3 학력평가(인천)")

        let english = EBSiArchive.parseRows(row("2026 10월 영어 고1 10월 학평(경기) 영어", p("/a/e.pdf", "1")))[0]
        XCTAssertEqual(EBSiArchive.fileName(english, explanation: false), "2026_10월학평_고1_영어_문제지.pdf") // 영역=과목이면 한 번만
        let social = EBSiArchive.parseRows(row("2026 10월 사탐 고1 10월 학평(경기) 통합사회", p("/a/s.pdf", "1")))[0]
        XCTAssertEqual(EBSiArchive.fileName(social, explanation: false), "2026_10월학평_고1_사회탐구_통합사회_문제지.pdf")
    }

    func testPreselectFollowsElectives() {
        let html = row("2026 10월 국어 고3 10월 학평(서울) 화법과 작문", p("/k/a.pdf", "1"))
            + row("2026 10월 국어 고3 10월 학평(서울) 언어와 매체", p("/k/b.pdf", "1"))
            + row("2026 10월 수학 고3 10월 학평(서울) 확률과 통계", p("/m/a.pdf", "1"))
            + row("2026 10월 수학 고3 10월 학평(서울) 미적분", p("/m/b.pdf", "1"))
            + row("2026 10월 영어 고3 10월 학평(서울) 영어", p("/e.pdf", "1"))
            + row("2026 10월 사탐 고3 10월 학평(서울) 경제", p("/s.pdf", "1"))
        let rows = EBSiArchive.parseRows(html)
        // 선택과목을 안 정했으면 국어·수학 선택과목 파일을 모두, 탐구는 고르지 않는다.
        XCTAssertEqual(EBSiArchive.preselect(rows, electives: [:]), ["/k/a.pdf", "/k/b.pdf", "/m/a.pdf", "/m/b.pdf", "/e.pdf"])
        XCTAssertEqual(EBSiArchive.preselect(rows, electives: [.korean: .languageMedia, .math: .calculus]),
                       ["/k/b.pdf", "/m/b.pdf", "/e.pdf"])
    }

    func testListRequestForm() {
        let info = EBSiArchive.parsePage(page)
        let form = Dictionary(uniqueKeysWithValues: EBSiArchive.listFormForTesting(.first, year: 2025, months: [3, 10], info: info, page: 2))
        XCTAssertEqual(form["targetCd"], "D100")
        XCTAssertEqual(form["yearList"], "2025")
        XCTAssertEqual(form["monthList"], "03,10")
        XCTAssertEqual(form["arOrd"], "1,2,3,5")
        XCTAssertEqual(form["subjIdList"], "140117,140118,korPast,140119,140120,80003,63002")
        XCTAssertEqual(form["currentPage"], "2")
    }

    /// 로그인이 아니면 목록 요청을 보내지 않고 바로 실패한다(네트워크에 닿지 않는다).
    func testDoesNotListWhenLoggedOut() async {
        let info = EBSiArchive.parsePage(page.replacingOccurrences(of: "'true'", with: "'false'"))
        do {
            _ = try await EBSiArchive.papers(.third, year: 2026, month: 10, info: info, cookies: "")
            XCTFail("로그인 없이 목록을 불렀음")
        } catch {
            XCTAssertEqual(error as? EBSiArchive.FetchError, .notLoggedIn)
        }
    }
}
