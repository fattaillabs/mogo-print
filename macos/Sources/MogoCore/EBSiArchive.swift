import Foundation

/// EBSi 기출문제에서 교육청 전국연합학력평가(학평) 문제지를 받는다.
///
/// 학평 문제지는 시·도교육청이 EBSi에서만 제공하고, EBSi는 로그인한 회원에게만 기출문제 목록을 보여 준다.
/// 그래서 앱은 사용자가 앱 안 로그인 창(웹 화면)에서 직접 로그인한 상태(쿠키)로만 목록을 읽는다.
/// 로그인 여부는 공개 페이지(`previousPaperList.ebs`)의 `loginTF` 값으로 먼저 확인하고, 로그인이 아니면 목록을 부르지 않는다.
public enum EBSiArchive {
    public static let site = URL(string: "https://www.ebsi.co.kr")!
    /// 파일 서버. 목록의 파일 경로를 뒤에 붙인다.
    public static let fileBase = "https://wdown.ebsi.co.kr/W61001/01exam"
    /// 로그인 페이지. 로그인하면 기출문제 페이지로 돌아온다.
    public static let loginURL = URL(string: "https://www.ebsi.co.kr/ebs/pot/potl/login.ebs?alertYn=N&destination=%2Febs%2Fxip%2Fxipc%2FpreviousPaperList.ebs")!
    static let userAgent = "Mozilla/5.0 (Macintosh) MogoPrint"
    /// 목록은 한 번에 15줄씩 온다. 이상한 응답에도 끝나도록 쪽 수를 제한한다.
    static let maxPages = 12

    public enum Grade: Int, CaseIterable, Identifiable, Sendable {
        case first = 1, second, third
        public var id: Int { rawValue }
        public var name: String { "고\(rawValue)" }
        public var targetCode: String { "D\(rawValue)00" }
    }

    public enum FetchError: LocalizedError, Equatable {
        case notLoggedIn
        case http(Int)
        case notAFile(String)

        public var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "EBSi에 로그인해야 받을 수 있어요."
            case .http(let code): return "EBSi에 연결하지 못했어요(HTTP \(code))."
            case .notAFile(let name): return "\(name)을(를) 받지 못했어요. 잠시 뒤 다시 해 보세요."
            }
        }
    }

    // MARK: 기출문제 페이지(검색 조건)

    /// 검색 영역 하나(국어, 수학 …): 영역 번호와 그 영역의 과목 번호들.
    public struct Area: Sendable, Hashable {
        public let name: String
        public let order: String
        public let subjectIDs: [String]
    }

    public struct PageInfo: Sendable, Hashable {
        public let loggedIn: Bool
        public let years: [Int]
        public let areas: [Area]
    }

    /// 페이지 검색 칸의 이름 → 영역 이름. (영역 번호 칸, 과목 체크박스 칸)
    static let areaFields: [(name: String, orderField: String, subjectField: String)] = [
        ("국어", "korArOrd", "sFormPartKor"),
        ("수학", "mathArOrd", "sFormPartMath"),
        ("영어", "engArOrd", "sFormPartEng"),
        ("한국사", "hisArOrd", "sFormPartHis"),
        ("사회탐구", "srch1ArOrd", "sFormPartSoc"),
        ("과학탐구", "srch2ArOrd", "sFormPartSci"),
        ("직업탐구", "jobArOrd", "sFormPartCareer"),
        ("제2외국어/한문", "scndForgnlngArOrd", "sFormPartLang"),
    ]

    /// 기출문제 페이지에서 로그인 여부, 고를 수 있는 연도, 영역·과목 번호를 읽는다.
    public static func parsePage(_ html: String) -> PageInfo {
        let login = matches(#"var\s+loginTF\s*=\s*['"](\w+)['"]"#, in: html).first?[1] == "true"
        let years = matches(#"name=["']year["'][^>]*value=["'](\d{4})["']"#, in: html).compactMap { Int($0[1]) }
        var areas: [Area] = []
        for f in areaFields {
            guard let order = matches(#"name=["']\#(f.orderField)["'][^>]*value=["'](\d+)["']"#, in: html).first?[1] else { continue }
            let ids = matches(#"name=["']\#(f.subjectField)["'][^>]*value=["']([^"']+)["']"#, in: html).map { $0[1] }
            if !ids.isEmpty { areas.append(Area(name: f.name, order: order, subjectIDs: unique(ids))) }
        }
        return PageInfo(loggedIn: login, years: unique(years), areas: areas)
    }

    // MARK: 목록

    /// 목록 한 줄: 시험 하나의 과목 하나.
    public struct Paper: Sendable, Hashable, Identifiable {
        public var id: String { paperPath }
        /// 목록에 보이는 글. 예: "2026 10월 국어 고3 10월 학평(서울) 화법과 작문"
        public let title: String
        public let year: Int
        public let month: Int
        /// 목록의 영역 표시(국어, 수학, 영어, 한국사, 사탐, 과탐 …)
        public let area: String
        public let grade: Int?
        /// 시험 이름. 예: "10월 학평(서울)", "2026학년도 대학수학능력시험"
        public let exam: String
        /// 과목. 예: "화법과 작문", "통합사회"
        public let subject: String
        /// 홀수형·짝수형으로 나뉜 시험이면 그 형
        public let variant: ExamVariant?
        public let subjectID: String
        public let paperPath: String
        public let explanationPath: String?

        /// 교육청 학력평가인지(수능·모평은 평가원에서 받는다)
        public var isEducationOffice: Bool { exam.contains("학평") }
        /// 주관 교육청. 예: "서울"
        public var office: String? {
            guard let r = exam.range(of: #"\(([^)]+)\)"#, options: .regularExpression) else { return nil }
            return String(exam[r].dropFirst().dropLast())
        }
        /// 고3 국어·수학 선택과목 파일이면 그 과목
        public var elective: Elective? { Elective(name: subject) }
        public var paperURL: URL { URL(string: EBSiArchive.fileBase + paperPath)! }
        public var explanationURL: URL? { explanationPath.flatMap { URL(string: EBSiArchive.fileBase + $0) } }
    }

    /// 목록 응답(HTML 조각)에서 줄을 읽는다. 한 줄은 `div.qus_box`, 왼쪽 칸 글이 시험·과목, 버튼이 파일 경로를 들고 있다.
    public static func parseRows(_ html: String) -> [Paper] {
        let blocks = html.components(separatedBy: #"class="qus_box"#).dropFirst()
        var out: [Paper] = []
        for chunk in blocks {
            // 나눈 자리가 여는 태그 한가운데라 앞에 ` kor">` 같은 태그 꼬리가 남는다. 첫 '>'까지 버린다.
            let block = chunk.firstIndex(of: ">").map { String(chunk[chunk.index(after: $0)...]) } ?? chunk
            let calls = matches(#"goDownLoad([PH])\(([^)]*)\)"#, in: block).map { m in
                (kind: m[1], args: matches(#"'([^']*)'"#, in: m[2]).map { $0[1] })
            }
            guard let p = calls.first(where: { $0.kind == "P" }), let path = p.args.first, path.hasSuffix(".pdf") else { continue }
            let h = calls.first(where: { $0.kind == "H" })?.args.first
            let left = block.components(separatedBy: "qus_inner right").first ?? block
            var text = clean(left)
            if let r = text.range(of: "자료다운") { text = String(text[..<r.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespaces)
            guard let m = matches(#"^(\d{4})\s+(\d{1,2})월\s+(\S+)\s+(?:고(\d)\s+)?(.+)$"#, in: text).first,
                  let year = Int(m[1]), let month = Int(m[2]) else { continue }
            var rest = m[5]
            var variant: ExamVariant?
            for v in [ExamVariant.odd, .even] where rest.hasSuffix(" " + v.rawValue) {
                variant = v
                rest = String(rest.dropLast(v.rawValue.count + 1))
            }
            // "10월 학평(서울) 화법과 작문" → 시험 "10월 학평(서울)", 과목 "화법과 작문"
            var exam = rest, subject = ""
            if let r = rest.range(of: #"^.*?\)\s*"#, options: .regularExpression) {
                exam = rest[r].trimmingCharacters(in: .whitespaces)
                subject = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = rest.range(of: "대학수학능력시험") {
                exam = String(rest[..<r.upperBound])
                subject = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if subject.isEmpty { subject = m[3] }
            out.append(Paper(title: text, year: year, month: month, area: m[3], grade: Int(m[4]), exam: exam,
                             subject: subject, variant: variant, subjectID: p.args.count > 5 ? p.args[5] : "",
                             paperPath: path, explanationPath: h?.hasSuffix(".pdf") == true ? h : nil))
        }
        return out
    }

    /// 목록 응답의 "총 N개".
    public static func parseTotal(_ html: String) -> Int? {
        matches(#"총\s*(\d+)\s*개"#, in: clean(html)).first.flatMap { Int($0[1]) }
    }

    /// 한 달에 있는 시험 이름(학평만). 예: [(10, "10월 학평(서울)")]
    public static func educationOfficeMonths(_ papers: [Paper]) -> [(month: Int, exam: String)] {
        var seen = Set<Int>(), out: [(Int, String)] = []
        for p in papers.sorted(by: { $0.month > $1.month }) where p.isEducationOffice && seen.insert(p.month).inserted {
            out.append((p.month, p.exam))
        }
        return out
    }

    // MARK: 요청

    /// 쿠키 헤더(앱 안 로그인 창에서 가져온 EBSi 쿠키)
    public typealias Cookies = String

    static func pageURL(_ grade: Grade) -> URL {
        URL(string: "https://www.ebsi.co.kr/ebs/xip/xipc/previousPaperList.ebs?targetCd=\(grade.targetCode)")!
    }

    static let listURL = URL(string: "https://www.ebsi.co.kr/ebs/xip/xipc/previousPaperListAjax.ajax")!

    static func request(_ url: URL, cookies: Cookies, form: [(String, String)]? = nil, referer: URL? = nil) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !cookies.isEmpty { req.setValue(cookies, forHTTPHeaderField: "Cookie") }
        if let referer { req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        req.httpShouldHandleCookies = false
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            req.httpBody = Data(formEncode(form).utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw FetchError.http(http.statusCode) }
        return data
    }

    static func formEncode(_ form: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }

    /// 기출문제 페이지를 읽어 로그인 여부와 검색 조건을 얻는다(공개 페이지).
    public static func pageInfo(_ grade: Grade, cookies: Cookies) async throws -> PageInfo {
        parsePage(String(decoding: try await request(pageURL(grade), cookies: cookies), as: UTF8.self))
    }

    /// 목록 요청에 보낼 칸. 화면에서 연도·월·과목을 체크하고 검색할 때와 같은 값이다.
    static func listForm(_ grade: Grade, year: Int, months: [Int], areas: [Area], page: Int) -> [(String, String)] {
        [("targetCd", grade.targetCode), ("yearList", String(year)),
         ("monthList", months.map { String(format: "%02d", $0) }.joined(separator: ",")),
         ("arOrd", areas.map(\.order).joined(separator: ",")),
         ("subjIdList", areas.flatMap(\.subjectIDs).joined(separator: ",")),
         ("sort", "recent"), ("paperId", ""), ("paperNo", ""), ("lvl", ""), ("currentPage", String(page))]
    }

    /// 시험용: 목록 요청 칸(전 영역).
    public static func listFormForTesting(_ grade: Grade, year: Int, months: [Int], info: PageInfo, page: Int) -> [(String, String)] {
        listForm(grade, year: year, months: months, areas: info.areas, page: page)
    }

    /// 로그인한 상태로 목록을 쪽마다 받아 모은다. 로그인이 아니면 부르지 않는다.
    static func list(_ grade: Grade, year: Int, months: [Int], areas: [Area], info: PageInfo, cookies: Cookies) async throws -> [Paper] {
        guard info.loggedIn else { throw FetchError.notLoggedIn }
        var all: [Paper] = []
        var total: Int?
        for page in 1...maxPages {
            let html = String(decoding: try await request(listURL, cookies: cookies,
                                                          form: listForm(grade, year: year, months: months, areas: areas, page: page),
                                                          referer: pageURL(grade)), as: UTF8.self)
            total = total ?? parseTotal(html)
            let rows = parseRows(html).filter { r in !all.contains { $0.paperPath == r.paperPath } }
            all += rows
            if rows.isEmpty || all.count >= (total ?? 0) { break }
        }
        return all
    }

    /// 그 학년·연도에 학평이 있었던 달(최근 달부터). 국어 영역만으로 찾는다(요청이 적다).
    public static func months(_ grade: Grade, year: Int, info: PageInfo, cookies: Cookies) async throws -> [(month: Int, exam: String)] {
        let korean = info.areas.filter { $0.name == "국어" }
        let rows = try await list(grade, year: year, months: Array(3...12), areas: korean.isEmpty ? info.areas : korean,
                                  info: info, cookies: cookies)
        return educationOfficeMonths(rows)
    }

    /// 그 달 학평의 모든 과목 줄.
    public static func papers(_ grade: Grade, year: Int, month: Int, info: PageInfo, cookies: Cookies) async throws -> [Paper] {
        try await list(grade, year: year, months: [month], areas: info.areas, info: info, cookies: cookies)
            .filter { $0.isEducationOffice && $0.year == year && $0.month == month }
    }

    // MARK: 저장

    /// 받은 파일을 둘 폴더. 예: <base>/2026년 10월 고3 학력평가(서울)
    public static func folder(_ p: Paper, base: URL) -> URL {
        let office = p.office.map { "(\($0))" } ?? ""
        let grade = p.grade.map { " 고\($0)" } ?? ""
        return base.appendingPathComponent("\(p.year)년 \(p.month)월\(grade) 학력평가\(office)", isDirectory: true)
    }

    /// 파일 이름. 예: 2026_10월학평_고3_국어_화법과작문_문제지.pdf
    public static func fileName(_ p: Paper, explanation: Bool) -> String {
        let grade = p.grade.map { "_고\($0)" } ?? ""
        let area = p.area == p.subject ? "" : "_\(areaName(p.area))"
        let subject = p.subject.replacingOccurrences(of: " ", with: "")
        let variant = p.variant.map { "_\($0.rawValue)" } ?? ""
        return KICEArchive.safe("\(p.year)_\(p.month)월학평\(grade)\(area)_\(subject)\(variant)_\(explanation ? "해설" : "문제지").pdf")
    }

    public static func areaName(_ a: String) -> String {
        switch a {
        case "사탐": return "사회탐구"
        case "과탐": return "과학탐구"
        case "직탐": return "직업탐구"
        default: return a
        }
    }

    /// 문제지(또는 해설) 하나를 받아 저장한다. 이미 받아 둔 파일이 있으면 다시 받지 않는다.
    public static func save(_ p: Paper, explanation: Bool = false, to dir: URL) async throws -> URL? {
        guard let url = explanation ? p.explanationURL : p.paperURL else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName(p, explanation: explanation))
        if let size = try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int, size > 0 { return dest }
        let data = try await request(url, cookies: "", referer: pageURL(.third))
        guard data.starts(with: Array("%PDF".utf8)) else { throw FetchError.notAFile(p.title) }
        try data.write(to: dest, options: .atomic)
        return dest
    }

    /// 기본으로 고를 줄: 국어·수학·영어·한국사(탐구·제2외국어는 사용자가 고른다). 선택과목을 정해 두었으면 그 과목 파일만.
    public static func preselect(_ papers: [Paper], electives: [ElectiveSubject: Elective]) -> Set<String> {
        Set(papers.filter { p in
            guard ["국어", "수학", "영어", "한국사"].contains(p.area) else { return false }
            if let e = p.elective, let chosen = electives[e.subject] { return e == chosen }
            return true
        }.map(\.id))
    }

    // MARK: 도우미

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    static func clean(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func unique<T: Hashable>(_ xs: [T]) -> [T] {
        var seen = Set<T>()
        return xs.filter { seen.insert($0).inserted }
    }
}
