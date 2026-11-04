import Foundation

/// 평가원 수능 홈페이지 기출문제 게시판에서 시험지를 받는다.
/// - 수능: boardID 1500234, 학년도 검색 칸 C01
/// - 모의평가: boardID 1500236, 학년도 C01 + 월 C02(6월·9월)
/// - 첨부 받기: /boardCnts/fileDown.do?fileSeq=<해시>
/// 시험지 저작권은 평가원에 있으므로 받은 파일은 사용자의 컴퓨터에만 저장한다.
public enum KICEExam: String, CaseIterable, Identifiable, Sendable {
    case suneung = "대학수학능력시험"
    case june = "6월 모의평가"
    case september = "9월 모의평가"

    public var id: String { rawValue }
    var boardID: String { self == .suneung ? "1500234" : "1500236" }
    var month: String? {
        switch self {
        case .suneung: return nil
        case .june: return "6월"
        case .september: return "9월"
        }
    }

    /// 짧은 이름. 예: 수능, 6월 모평
    public var shortName: String {
        switch self {
        case .suneung: return "수능"
        case .june: return "6월 모평"
        case .september: return "9월 모평"
        }
    }

    /// 받은 파일 이름 앞에 붙이는 말. 예: 2026수능, 2027_6월모평
    public func filePrefix(year: Int) -> String {
        guard let month else { return "\(year)수능" }
        return "\(year)_\(month)모평"
    }

    /// 명령줄에서 쓰는 이름으로 찾는다: 수능, 6월, 9월(모평·모의평가를 붙여도 됨)
    public init?(name: String) {
        let key = name.replacingOccurrences(of: " ", with: "")
        if key == "수능" || key == "대학수학능력시험" { self = .suneung }
        else if key.hasPrefix("6월") { self = .june }
        else if key.hasPrefix("9월") { self = .september }
        else { return nil }
    }
}

public struct KICEAttachment: Sendable, Hashable {
    public enum Kind: Sendable { case paper, answer, listening }

    /// 게시판에 보이는 파일 이름. 예: 국어영역_문제지.pdf
    public let title: String
    public let fileSeq: String

    public init(title: String, fileSeq: String) {
        self.title = title
        self.fileSeq = fileSeq
    }

    public var kind: Kind { Self.kind(of: title) }
    public var isZip: Bool { title.lowercased().hasSuffix(".zip") }

    /// 이름으로 나눈다: '정답'이 들어가면 정답표, 듣기·음원·대본이면 듣기 자료, 나머지는 문제지.
    /// (2019학년도 '국어영역.zip', 2015학년도 '국어영역A형-홀수.pdf'처럼 '문제지'라는 말이 없는 해도 있다.)
    public static func kind(of title: String) -> Kind {
        let t = title.replacingOccurrences(of: " ", with: "")
        if t.contains("정답") { return .answer }
        if ["듣기", "음원", "대본"].contains(where: { t.contains($0) }) { return .listening }
        return .paper
    }
}

/// 게시판 한 줄(학년도·영역 하나).
public struct KICERow: Sendable, Identifiable, Hashable {
    public let id: String
    public let year: Int
    public let month: String?
    /// 영역. 예: 국어, 사회탐구, 제2외국어/한문
    public let area: String
    public let attachments: [KICEAttachment]

    public var papers: [KICEAttachment] { attachments.filter { $0.kind == .paper } }
    public var answers: [KICEAttachment] { attachments.filter { $0.kind == .answer } }
    /// 탐구·제2외국어처럼 과목 여러 개가 한 첨부에 묶여 오는 영역.
    public var hasManySubjects: Bool { area.contains("탐구") || area.contains("외국어") || area.contains("한문") }
}

public enum KICEArchive {
    public static let site = URL(string: "https://www.suneung.re.kr")!

    public enum FetchError: LocalizedError {
        case http(Int)
        case notAFile(String)

        public var errorDescription: String? {
            switch self {
            case .http(let code): return "평가원 홈페이지에 연결하지 못했어요(HTTP \(code))."
            case .notAFile(let name): return "\(name)을(를) 받지 못했어요. 잠시 뒤 다시 해 보세요."
            }
        }
    }

    // MARK: 주소

    public static func listURL(_ exam: KICEExam, year: Int?) -> URL {
        var c = URLComponents(url: site.appendingPathComponent("boardCnts/list.do"), resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "boardID", value: exam.boardID), URLQueryItem(name: "m", value: "0403"),
                 URLQueryItem(name: "s", value: "suneung")]
        if let year { q.append(URLQueryItem(name: "C01", value: String(year))) }
        if let month = exam.month { q.append(URLQueryItem(name: "C02", value: month)) }
        c.queryItems = q
        return c.url!
    }

    public static func downloadURL(_ a: KICEAttachment) -> URL {
        var c = URLComponents(url: site.appendingPathComponent("boardCnts/fileDown.do"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "fileSeq", value: a.fileSeq)]
        return c.url!
    }

    // MARK: 게시판 읽기

    /// 학년도 검색 칸(C01)의 선택지. 최신 학년도부터.
    public static func parseYears(_ html: String) -> [Int] {
        guard let r = html.range(of: #"<select name="C01"[\s\S]*?</select>"#, options: .regularExpression) else { return [] }
        let block = String(html[r])
        return matches(#"<option value="(\d{4})""#, in: block).compactMap { Int($0[1]) }.sorted(by: >)
    }

    /// 목록 표의 줄들. 머리줄에서 '학년도'·'월'·'영역' 열 위치를 찾아 읽는다(두 게시판의 열 순서가 다르다).
    public static func parseRows(_ html: String) -> [KICERow] {
        guard let head = html.range(of: #"<thead[\s\S]*?</thead>"#, options: .regularExpression) else { return [] }
        let headers = matches(#"<th[^>]*>([\s\S]*?)</th>"#, in: String(html[head])).map { clean($0[1]) }
        guard let yearCol = headers.firstIndex(of: "학년도"), let areaCol = headers.firstIndex(of: "영역") else { return [] }
        let monthCol = headers.firstIndex(of: "월")

        return matches(#"<tr[^>]*>([\s\S]*?)</tr>"#, in: html).compactMap { m -> KICERow? in
            let tr = m[1]
            let cells = matches(#"<td[^>]*>([\s\S]*?)</td>"#, in: tr).map { $0[1] }
            guard cells.count > max(yearCol, areaCol), let year = Int(clean(cells[yearCol])) else { return nil }
            let files = matches(#"fn_fileDown\('([0-9a-fA-F]+)'\);?"\s*title='([^']+)'"#, in: tr)
                .map { KICEAttachment(title: decodeEntities($0[2]), fileSeq: $0[1]) }
            guard !files.isEmpty else { return nil }
            let id = clean(cells[0])
            return KICERow(id: id.isEmpty ? "\(year)-\(clean(cells[areaCol]))" : id, year: year,
                           month: monthCol.map { clean(cells[$0]) }, area: clean(cells[areaCol]), attachments: files)
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    private static func clean(_ cell: String) -> String {
        decodeEntities(cell.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#40;", with: "(").replacingOccurrences(of: "&#41;", with: ")")
    }

    // MARK: 받기

    static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("Mozilla/5.0 (Macintosh) MogoPrint", forHTTPHeaderField: "User-Agent")
        req.setValue(listURL(.suneung, year: nil).absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw FetchError.http(http.statusCode) }
        return data
    }

    /// 그 시험에서 고를 수 있는 학년도(최신부터).
    public static func years(_ exam: KICEExam) async throws -> [Int] {
        parseYears(String(decoding: try await get(listURL(exam, year: nil)), as: UTF8.self))
    }

    /// 그 시험·학년도의 영역별 줄(국어, 수학, 영어, 한국사, 탐구 …). 아직 안 올라왔으면 빈 배열.
    public static func rows(_ exam: KICEExam, year: Int) async throws -> [KICERow] {
        let html = String(decoding: try await get(listURL(exam, year: year)), as: UTF8.self)
        return parseRows(html).filter { $0.year == year && (exam.month == nil || $0.month == exam.month) }
    }

    /// 받은 파일을 둘 폴더. 예: <base>/2026학년도 대학수학능력시험
    public static func folder(_ exam: KICEExam, year: Int, base: URL) -> URL {
        base.appendingPathComponent("\(year)학년도 \(exam.rawValue)", isDirectory: true)
    }

    /// 첨부 하나를 받아 PDF로 저장한다. ZIP이면 풀어서 안의 PDF만 저장한다. 저장한 PDF 경로를 돌려준다.
    /// 이미 받아 둔 파일이 있으면 다시 받지 않는다.
    public static func save(_ a: KICEAttachment, exam: KICEExam, year: Int, to dir: URL) async throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "\(exam.filePrefix(year: year))_\(safe((a.title as NSString).deletingPathExtension))"

        if !a.isZip {
            let url = dir.appendingPathComponent(base + ".pdf")
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 0 { return [url] }
            let data = try await get(downloadURL(a))
            guard data.starts(with: Array("%PDF".utf8)) else { throw FetchError.notAFile(a.title) }
            try data.write(to: url, options: .atomic)
            return [url]
        }

        let folder = dir.appendingPathComponent(base, isDirectory: true)
        let existing = URL.expandPDFs([folder])
        if !existing.isEmpty { return existing }
        let data = try await get(downloadURL(a))
        guard data.starts(with: [0x50, 0x4B]) else { throw FetchError.notAFile(a.title) }
        let pdfs = try ZipArchive.entries(data).filter {
            $0.name.lowercased().hasSuffix(".pdf") && !$0.name.hasPrefix(".") && !$0.path.contains("__MACOSX")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved: [URL] = []
        for e in pdfs.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let url = folder.appendingPathComponent(safe(e.name))
            try e.data.write(to: url, options: .atomic)
            saved.append(url)
        }
        return saved
    }

    /// 받은 파일 가운데 목록에 기본으로 넣을 것. 탐구·제2외국어처럼 과목이 여러 개인 영역은 고르지 않고
    /// (응시 과목만 사용자가 고른다), 홀·짝 파일이 따로 오면(2022학년도 이전) 지금 고른 형만 넣는다.
    public static func preselect(_ files: [(url: URL, area: String)], manySubjectAreas: Set<String>,
                                 variant: ExamVariant) -> Set<URL> {
        let key: String? = variant == .odd ? "홀" : (variant == .even ? "짝" : nil)
        return Set(files.filter { f in
            if manySubjectAreas.contains(f.area) { return false }
            let name = f.url.deletingPathExtension().lastPathComponent
            if let key, name.contains("홀") || name.contains("짝") { return name.contains(key) }
            return true
        }.map(\.url))
    }

    /// 파일 이름에 쓸 수 없는 글자(/ :)를 바꾼다.
    static func safe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "·").replacingOccurrences(of: ":", with: "-")
    }
}
