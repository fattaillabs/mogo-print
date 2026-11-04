import CoreGraphics
import Foundation
import PDFKit

/// 시험지 형(홀수형/짝수형) 선택.
public enum ExamVariant: String, CaseIterable, Identifiable, Sendable {
    case odd = "홀수형"
    case even = "짝수형"
    case all = "전체"
    public var id: String { rawValue }
}

/// 선택과목이 있는 과목(2022~2027학년도 국어·수학).
public enum ElectiveSubject: String, CaseIterable, Identifiable, Sendable, Codable {
    case korean = "국어"
    case math = "수학"
    public var id: String { rawValue }
    public var electives: [Elective] { Elective.allCases.filter { $0.subject == self } }
}

/// 선택과목. 쪽 머리말에 "(화법과 작문)"처럼 괄호로 찍힌 과목명으로 알아본다.
public enum Elective: String, CaseIterable, Identifiable, Sendable, Codable {
    case speechWriting = "화법과 작문"
    case languageMedia = "언어와 매체"
    case probability = "확률과 통계"
    case calculus = "미적분"
    case geometry = "기하"

    public var id: String { rawValue }

    public var subject: ElectiveSubject {
        switch self {
        case .speechWriting, .languageMedia: return .korean
        case .probability, .calculus, .geometry: return .math
        }
    }

    /// 학생들이 부르는 줄임말.
    public var shortName: String {
        switch self {
        case .speechWriting: return "화작"
        case .languageMedia: return "언매"
        case .probability: return "확통"
        case .calculus: return "미적"
        case .geometry: return "기하"
        }
    }

    /// 기준값 파일에 쓰는 한 글자 기호.
    public var code: Character {
        switch self {
        case .speechWriting: return "S"
        case .languageMedia: return "L"
        case .probability: return "P"
        case .calculus: return "C"
        case .geometry: return "G"
        }
    }

    /// 줄임말·전체 이름(띄어쓰기 무시)으로 찾는다. 예: "언매", "언어와 매체", "미적분"
    public init?(name: String) {
        let key = name.replacingOccurrences(of: " ", with: "")
        guard let found = Elective.allCases.first(where: {
            $0.shortName == key || $0.rawValue.replacingOccurrences(of: " ", with: "") == key
        }) else { return nil }
        self = found
    }
}

public let pointsPerMM: CGFloat = 72.0 / 25.4
public let a4Size = CGSize(width: 595.28, height: 841.89)

/// 페이지를 똑바로 세운(/Rotate 반영) 좌표계. 원점은 왼쪽 아래 (0, 0).
public struct PageGeometry: Equatable, Sendable {
    /// 회전을 반영한 페이지 크기(cropBox 기준).
    public let size: CGSize
    /// PDF 사용자 공간 → 똑바로 세운 좌표계 변환.
    public let transform: CGAffineTransform

    public init(page ref: CGPDFPage) {
        let box = ref.getBoxRect(.cropBox)
        let rotated = ref.rotationAngle % 180 != 0
        size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        // getDrawingTransform은 회전을 반영하고, 대상 크기가 같으면 배율은 1이다.
        transform = ref.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                            rotate: 0, preserveAspectRatio: true)
    }

    /// 페이지 크기별로 묶을 때 쓰는 키(1pt 단위로 반올림).
    var sizeKey: String { "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))" }
}

/// 불러온 PDF 한 개와 분석 결과.
public final class SourceFile: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public let document: PDFDocument
    /// 페이지별 형 라벨. 라벨이 없는 페이지는 앞 페이지 라벨을 이어받고,
    /// 첫 라벨이 나오기 전 페이지(표지 등)는 nil이라 어느 형을 고르든 들어간다.
    public let pageVariants: [ExamVariant?]
    /// 페이지별 선택과목. 공통 쪽은 nil.
    public let pageElectives: [Elective?]
    /// 페이지별 내용(잉크) 영역, 똑바로 세운 좌표계. 빈 페이지는 nil.
    public let inkBounds: [CGRect?]
    /// 페이지별 기하 정보.
    public let geometry: [PageGeometry]

    /// 쪽수. 화면 스레드에서 PDFDocument를 건드리지 않도록 미리 저장해 둔다.
    public let pageCount: Int

    public var name: String { url.deletingPathExtension().lastPathComponent }
    /// 이 파일에 든 선택과목(나오는 순서대로).
    public var electives: [Elective] {
        var out: [Elective] = []
        for e in pageElectives.compactMap({ $0 }) where !out.contains(e) { out.append(e) }
        return out
    }

    /// 선택과목이 있으면 그 과목(국어·수학).
    public var electiveSubject: ElectiveSubject? { electives.first?.subject }

    /// 홀수형과 짝수형이 한 파일에 같이 들어 있는지.
    public var hasBothVariants: Bool {
        pageVariants.contains(.odd) && pageVariants.contains(.even)
    }

    public init?(url: URL) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0, !doc.isLocked else { return nil }
        let analysis = ExamAnalyzer.analyze(url: url, pageCount: doc.pageCount, primary: doc)
        guard analysis.geometry.count == doc.pageCount else { return nil }
        self.url = url
        self.document = doc
        self.pageCount = doc.pageCount
        self.pageVariants = ExamAnalyzer.propagate(analysis.labels)
        self.pageElectives = analysis.electives
        self.inkBounds = analysis.ink
        self.geometry = analysis.geometry
    }

    /// 여러 파일을 동시에 연다. 결과 순서는 입력 순서와 같고, 못 연 파일은 nil.
    public static func load(_ urls: [URL]) -> [SourceFile?] {
        var out = [SourceFile?](repeating: nil, count: urls.count)
        out.withUnsafeMutableBufferPointer { buf in
            nonisolated(unsafe) let buf = buf
            DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                buf[i] = SourceFile(url: urls[i])
            }
        }
        return out
    }

    /// 배치 설정(형·선택과목)에 해당하는 페이지 번호(0부터). 공통 쪽은 언제나 들어간다.
    public func pageIndices(for options: ImpositionOptions) -> [Int] {
        let pages = pageIndices(for: options.variant)
        guard let subject = electiveSubject, let chosen = options.electives[subject] else { return pages }
        return pages.filter { pageElectives[$0] == nil || pageElectives[$0] == chosen }
    }

    /// 선택한 형에 해당하는 페이지 번호(0부터).
    public func pageIndices(for variant: ExamVariant) -> [Int] {
        let all = Array(0..<pageCount)
        guard variant != .all, hasBothVariants else { return all }
        return all.filter { pageVariants[$0] == nil || pageVariants[$0] == variant }
    }
}

public enum ExamAnalyzer {
    /// 텍스트에서 형 라벨을 찾는다. "홀수형", "홀 수 형", "( 홀수 )형" 모두 인식.
    /// 한 페이지에 둘 다 있으면(안내문 등) 라벨로 보지 않는다.
    public static func variantLabel(in text: String) -> ExamVariant? {
        let ignored = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "()（）[]［］〔〕「」<>〈〉"))
        var compact = String.UnicodeScalarView()
        compact.append(contentsOf: text.unicodeScalars.filter { !ignored.contains($0) })
        let s = String(compact)
        let hasOdd = s.contains("홀수형")
        let hasEven = s.contains("짝수형")
        if hasOdd == hasEven { return nil }
        return hasOdd ? .odd : .even
    }

    /// 쪽 글자에서 선택과목을 찾는다. 공백을 지우고, 안내문의 "선택과목(언어와 매체)"는 빼고,
    /// 남은 글에서 괄호로 싼 과목명 "(화법과 작문)"을 찾는다. 하나만 나올 때만 그 과목으로 본다.
    public static func electiveLabel(in text: String) -> Elective? {
        var t = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }))
        t = t.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        t = t.replacingOccurrences(of: #"선택과목\([^)]*\)"#, with: "", options: .regularExpression)
        let found = Elective.allCases.filter { t.contains("(\($0.rawValue.replacingOccurrences(of: " ", with: "")))") }
        return found.count == 1 ? found[0] : nil
    }

    /// 라벨이 없는 페이지는 앞 페이지 라벨을 이어받는다.
    public static func propagate(_ labels: [ExamVariant?]) -> [ExamVariant?] {
        var current: ExamVariant? = nil
        return labels.map { label in
            if let label { current = label }
            return current
        }
    }

    /// 페이지 텍스트에서 "홀수형"/"짝수형"을 찾아 페이지별 라벨을 만든다.
    public static func detectVariants(_ doc: PDFDocument) -> [ExamVariant?] {
        propagate((0..<doc.pageCount).map { variantLabel(in: doc.page(at: $0)?.string ?? "") })
    }

    struct Analysis {
        var labels: [ExamVariant?]
        var electives: [Elective?]
        var ink: [CGRect?]
        var geometry: [PageGeometry]
    }

    /// 페이지마다 텍스트 라벨과 잉크 영역을 구한다. 가장 느린 단계라 여러 스레드로 나눈다.
    /// PDFKit 객체는 스레드끼리 나눠 쓰면 안전하지 않으므로 스레드마다 문서를 따로 연다.
    /// 문서를 새로 열면 글꼴을 다시 읽느라 스레드마다 수십 ms가 드니, 8쪽당 한 스레드·최대 4개로 둔다
    /// (M1 실측: 40쪽 기준 4개가 가장 빠르고 8개는 효율 코어까지 써서 오히려 느림).
    /// `primary`(앱이 계속 쓸 문서)는 첫 스레드가 쓴다. 여기서 글꼴을 읽어 두면 나중에 A4로 그릴 때 빨라진다.
    /// 이 함수가 끝나기 전에는 primary를 다른 곳에서 쓰지 않으므로 안전하다.
    static func analyze(url: URL, pageCount n: Int, primary: PDFDocument? = nil) -> Analysis {
        var labels = [ExamVariant?](repeating: nil, count: n)
        var electives = [Elective?](repeating: nil, count: n)
        var ink = [CGRect?](repeating: nil, count: n)
        var geometry = [PageGeometry?](repeating: nil, count: n)
        let workers = max(1, min(n / 8, 4, ProcessInfo.processInfo.activeProcessorCount))
        electives.withUnsafeMutableBufferPointer { electivesBuf in
        labels.withUnsafeMutableBufferPointer { labelsBuf in
            ink.withUnsafeMutableBufferPointer { inkBuf in
                geometry.withUnsafeMutableBufferPointer { geoBuf in
                    // 각 스레드는 서로 다른 칸에만 쓴다.
                    nonisolated(unsafe) let labelsBuf = labelsBuf
                    nonisolated(unsafe) let electivesBuf = electivesBuf
                    nonisolated(unsafe) let inkBuf = inkBuf
                    nonisolated(unsafe) let geoBuf = geoBuf
                    nonisolated(unsafe) let primary = primary
                    DispatchQueue.concurrentPerform(iterations: workers) { w in
                        guard let doc = (w == 0 ? primary : nil) ?? PDFDocument(url: url) else { return }
                        for i in stride(from: w, to: n, by: workers) {
                            guard let page = doc.page(at: i), let ref = page.pageRef else { continue }
                            let geo = PageGeometry(page: ref)
                            geoBuf[i] = geo
                            let text = page.string ?? ""
                            labelsBuf[i] = variantLabel(in: text)
                            electivesBuf[i] = electiveLabel(in: text)
                            inkBuf[i] = inkBounds(of: ref, geometry: geo)
                        }
                    }
                }
            }
        }
        }
        return Analysis(labels: labels, electives: electives, ink: ink, geometry: geometry.compactMap { $0 })
    }

    /// 페이지를 저해상도로 그려서 흰색이 아닌 픽셀의 경계를 찾는다(똑바로 세운 좌표계).
    public static func inkBounds(of page: PDFPage, dpi: CGFloat = 50, threshold: UInt8 = 200) -> CGRect? {
        guard let ref = page.pageRef else { return nil }
        return inkBounds(of: ref, geometry: PageGeometry(page: ref), dpi: dpi, threshold: threshold)
    }

    static func inkBounds(of ref: CGPDFPage, geometry geo: PageGeometry,
                          dpi: CGFloat = 50, threshold: UInt8 = 200) -> CGRect? {
        let s = dpi / 72.0
        let w = Int((geo.size.width * s).rounded(.up))
        let h = Int((geo.size.height * s).rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        ctx.concatenate(geo.transform)
        ctx.drawPDFPage(ref)

        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let buf = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        var minX = w, maxX = -1, minRow = h, maxRow = -1
        for row in 0..<h {
            let line = buf + row * bpr
            var rowHasInk = false
            for x in 0..<w where line[x] < threshold {
                rowHasInk = true
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
            if rowHasInk {
                if row < minRow { minRow = row }
                maxRow = row
            }
        }
        guard maxX >= 0, maxRow >= 0 else { return nil }
        // 비트맵 메모리의 0번째 행이 페이지 맨 위.
        let x0 = CGFloat(minX) / s
        let x1 = min(geo.size.width, CGFloat(maxX + 1) / s)
        let yTop = geo.size.height - CGFloat(minRow) / s
        let yBottom = max(0, geo.size.height - CGFloat(maxRow + 1) / s)
        return CGRect(x: x0, y: yBottom, width: x1 - x0, height: yTop - yBottom)
    }
}
