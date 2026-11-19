import Foundation

/// GitHub 릴리스로 새 버전을 확인한다. 릴리스에는 이름이 고정된 파일(MogoPrint.dmg, MogoPrint-windows-x64.zip)을 올린다.
public enum UpdateCheck {
    /// 최신 릴리스 정보(GitHub API). 시험할 때는 `MOGO_UPDATE_FEED`로 다른 주소(파일 포함)를 줄 수 있다.
    public static let latestURL = URL(string: "https://api.github.com/repos/fattaillabs/mogo-print/releases/latest")!
    /// 릴리스 목록 페이지(자동으로 바꿀 수 없을 때 연다)
    public static let releasesPage = URL(string: "https://github.com/fattaillabs/mogo-print/releases/latest")!
    /// 맥 업데이트 파일 이름
    public static let macAssetName = "MogoPrint.dmg"
    /// 업데이트 파일을 서명한 팀(Developer ID). 다른 팀이 서명한 앱으로는 바꾸지 않는다.
    public static let teamID = "BUS4S7XFQV"

    public struct Release: Sendable, Equatable {
        public let version: String
        public let notes: String
        public let page: URL
        public let assets: [String: URL]
        public let sizes: [String: Int]

        public init(version: String, notes: String, page: URL, assets: [String: URL], sizes: [String: Int] = [:]) {
            self.version = version
            self.notes = notes
            self.page = page
            self.assets = assets
            self.sizes = sizes
        }
    }

    public enum CheckError: LocalizedError, Equatable {
        case http(Int)
        case badResponse
        public var errorDescription: String? {
            switch self {
            case .http(let code): return "업데이트를 확인하지 못했어요(HTTP \(code))."
            case .badResponse: return "업데이트 정보를 읽지 못했어요."
            }
        }
    }

    private struct APIRelease: Decodable {
        let tag_name: String
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [APIAsset]
    }

    private struct APIAsset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int?
    }

    /// GitHub 릴리스 JSON을 읽는다. 초안·시험판은 업데이트로 보지 않는다(nil).
    public static func parse(_ data: Data) throws -> Release? {
        guard let r = try? JSONDecoder().decode(APIRelease.self, from: data), let page = URL(string: r.html_url) else {
            throw CheckError.badResponse
        }
        if r.draft == true || r.prerelease == true { return nil }
        var assets: [String: URL] = [:], sizes: [String: Int] = [:]
        for a in r.assets {
            guard let url = URL(string: a.browser_download_url) else { continue }
            assets[a.name] = url
            sizes[a.name] = a.size
        }
        return Release(version: normalized(r.tag_name), notes: r.body ?? "", page: page, assets: assets, sizes: sizes)
    }

    /// "v0.2.0" → "0.2.0"
    public static func normalized(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        return t
    }

    /// 숫자 마디로 비교한다(0.10.0 > 0.9.0). 뒤에 붙은 -beta 같은 꼬리가 있으면 같은 숫자의 정식판보다 낮다.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ v: String) -> (nums: [Int], pre: Bool) {
            let s = normalized(v)
            let core = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
            return (core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }, s.contains("-"))
        }
        let (x, xp) = split(a), (y, yp) = split(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        if xp != yp { return xp ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// 최신 릴리스를 가져온다. file:// 주소도 받는다(시험용).
    public static func latest(from url: URL = feedURL) async throws -> Release? {
        if url.isFileURL { return try parse(try Data(contentsOf: url)) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("MogoPrint-Updater", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw CheckError.http(http.statusCode) }
        return try parse(data)
    }

    public static var feedURL: URL {
        if let s = ProcessInfo.processInfo.environment["MOGO_UPDATE_FEED"], !s.isEmpty {
            return s.hasPrefix("/") ? URL(fileURLWithPath: s) : (URL(string: s) ?? latestURL)
        }
        return latestURL
    }
}
