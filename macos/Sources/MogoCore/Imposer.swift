import CoreGraphics
import Foundation
import PDFKit

/// 파일 하나에 대한 손 조정. 값은 mm이고 +면 더 잘라내고 -면 여백을 더 남긴다.
public struct CropAdjustment: Equatable, Hashable, Sendable {
    public var top: CGFloat = 0
    public var bottom: CGFloat = 0
    public var left: CGFloat = 0
    public var right: CGFloat = 0
    /// 자동 자르기를 끄고 페이지 전체를 쓴다.
    public var wholePage = false

    public init(top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0,
                wholePage: Bool = false) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.wholePage = wholePage
    }

    public var isDefault: Bool { self == CropAdjustment() }
}

public struct ImpositionOptions: Equatable, Sendable {
    /// A4 용지 가장자리에 남길 최소 여백(mm). 프린터 인쇄 불가 영역보다 커야 한다.
    public var paperMarginMM: CGFloat = 5
    /// 감지한 내용 영역 바깥에 덧붙일 여유(mm).
    public var paddingMM: CGFloat = 1.5
    public var variant: ExamVariant = .odd
    /// 양면 인쇄 때 다음 파일이 새 종이에서 시작하도록 빈 페이지를 넣을지.
    public var padSectionsToEven: Bool = true
    /// 마지막 파일 뒤에도 빈 쪽을 넣어 전체를 짝수 쪽으로 만들지(양면으로 여러 부 인쇄할 때).
    public var padEndToEven: Bool = false
    /// 원본보다 크게 키우지 않는다(정답표처럼 원래 A4인 파일).
    public var maxScale: CGFloat = 1
    /// 파일별 손 조정(파일 경로 기준).
    public var adjustments: [URL: CropAdjustment] = [:]

    public init() {}

    public func adjustment(for url: URL) -> CropAdjustment {
        adjustments[url] ?? CropAdjustment()
    }
}

/// A4 한 쪽에 놓일 원본 페이지.
public struct PlacedPage: Sendable {
    /// 원본 페이지 번호(0부터).
    public let index: Int
    /// 잘라낼 영역(똑바로 세운 좌표계).
    public let crop: CGRect
    /// 원본 대비 배율.
    public let scale: CGFloat
    public let geometry: PageGeometry
}

/// 한 파일에서 뽑은 페이지 묶음과 그 배치 정보.
public struct ExamSection {
    public let file: SourceFile
    public let pages: [PlacedPage]
    /// 뒤에 빈 페이지를 하나 붙이는지.
    public let padsBlankPage: Bool

    public var pageIndices: [Int] { pages.map(\.index) }
    /// 대표 배율(가장 작은 값).
    public var scale: CGFloat { pages.map(\.scale).min() ?? 1 }
    /// 대표 크롭 영역(첫 쪽).
    public var crop: CGRect { pages.first?.crop ?? .zero }
    /// 대표 페이지 크기(첫 쪽).
    public var pageSize: CGSize { pages.first?.geometry.size ?? .zero }
    /// A4에 놓이는 쪽수(빈 쪽 포함).
    public var outputPageCount: Int { pages.count + (padsBlankPage ? 1 : 0) }
}

public struct ImpositionResult {
    public let sections: [ExamSection]
    public let data: Data
    public let pageCount: Int
}

public enum Imposer {
    public static func plan(files: [SourceFile], options: ImpositionOptions) -> [ExamSection] {
        let margin = options.paperMarginMM * pointsPerMM
        let pad = options.paddingMM * pointsPerMM
        let usable = CGSize(width: a4Size.width - 2 * margin, height: a4Size.height - 2 * margin)

        var sections: [ExamSection] = []
        let nonEmpty = files.filter { !$0.pageIndices(for: options.variant).isEmpty }
        for (n, file) in nonEmpty.enumerated() {
            let indices = file.pageIndices(for: options.variant)
            let adjust = options.adjustment(for: file.url)

            let bases = autoCrops(file: file, indices: indices, adjust: adjust, pad: pad)
            let pages = indices.map { i -> PlacedPage in
                let crop = finalCrop(base: bases[file.geometry[i].sizeKey], page: file.geometry[i], adjust: adjust)
                let scale = min(usable.width / crop.width, usable.height / crop.height, options.maxScale)
                return PlacedPage(index: i, crop: crop, scale: scale, geometry: file.geometry[i])
            }

            let isLast = n == nonEmpty.count - 1
            sections.append(ExamSection(
                file: file,
                pages: pages,
                padsBlankPage: options.padSectionsToEven && pages.count % 2 == 1
                    && (!isLast || options.padEndToEven)
            ))
        }
        return sections
    }

    /// 같은 크기 페이지끼리 내용 영역을 합쳐 자동 범위를 만든다(글자 크기 일정). 크기 키별 범위, 손 조정 전.
    static func autoCrops(file: SourceFile, indices: [Int], adjust: CropAdjustment, pad: CGFloat) -> [String: CGRect] {
        var union: [String: CGRect] = [:]
        for i in indices {
            let key = file.geometry[i].sizeKey
            let pageRect = CGRect(origin: .zero, size: file.geometry[i].size)
            let found: CGRect? = adjust.wholePage ? pageRect : file.inkBounds[i]
            guard let r = found else { continue }
            union[key] = union[key].map { $0.union(r) } ?? r
        }
        // 자동 자르기를 끄면 페이지 전체(덧붙임 없음), 아니면 사방으로 덧붙임만큼 넓힌다.
        return adjust.wholePage ? union : union.mapValues { $0.insetBy(dx: -pad, dy: -pad) }
    }

    /// 자동 범위에 손 조정을 적용하고 페이지 안으로 맞춘다. 너무 작아지면 페이지 전체.
    static func finalCrop(base: CGRect?, page geo: PageGeometry, adjust: CropAdjustment) -> CGRect {
        let pageRect = CGRect(origin: .zero, size: geo.size)
        let crop = cropApplying(adjust, to: base ?? pageRect).intersection(pageRect)
        if crop.isNull || crop.width < 36 || crop.height < 36 { return pageRect }
        return crop
    }

    /// 손 조정 전 자동 범위(수동 조정 화면의 기준). 그 쪽과 크기가 같은, 고른 형의 쪽들을 합친 범위다.
    public static func baseCrop(file: SourceFile, pageIndex i: Int, options: ImpositionOptions) -> CGRect {
        let crops = autoCrops(file: file, indices: file.pageIndices(for: options.variant),
                              adjust: options.adjustment(for: file.url), pad: options.paddingMM * pointsPerMM)
        return crops[file.geometry[i].sizeKey] ?? CGRect(origin: .zero, size: file.geometry[i].size)
    }

    /// 손 조정까지 적용한 최종 범위(실제로 A4에 놓이는 범위).
    public static func crop(file: SourceFile, pageIndex i: Int, options: ImpositionOptions) -> CGRect {
        finalCrop(base: baseCrop(file: file, pageIndex: i, options: options), page: file.geometry[i],
                  adjust: options.adjustment(for: file.url))
    }

    /// 범위를 A4에 놓을 때의 배율.
    public static func scale(for crop: CGRect, options: ImpositionOptions) -> CGFloat {
        let margin = options.paperMarginMM * pointsPerMM
        return min((a4Size.width - 2 * margin) / crop.width, (a4Size.height - 2 * margin) / crop.height, options.maxScale)
    }

    /// 손 조정 값(mm)을 적용한다. +는 안으로 더 자르고 -는 밖으로 넓힌다.
    static func cropApplying(_ a: CropAdjustment, to rect: CGRect) -> CGRect {
        let l = a.left * pointsPerMM, r = a.right * pointsPerMM
        let t = a.top * pointsPerMM, b = a.bottom * pointsPerMM
        return CGRect(x: rect.minX + l, y: rect.minY + b,
                      width: rect.width - l - r, height: rect.height - t - b)
    }

    /// A4 PDF를 만든다. 원본 페이지를 벡터 그대로 축소해서 그리므로 글자가 선명하다.
    public static func render(_ sections: [ExamSection]) -> ImpositionResult? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: a4Size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }

        var pages = 0
        for section in sections {
            for placed in section.pages {
                guard let ref = section.file.document.page(at: placed.index)?.pageRef else { continue }
                ctx.beginPDFPage(nil)
                let w = placed.crop.width * placed.scale
                let h = placed.crop.height * placed.scale
                ctx.saveGState()
                ctx.translateBy(x: (a4Size.width - w) / 2, y: (a4Size.height - h) / 2)
                ctx.scaleBy(x: placed.scale, y: placed.scale)
                ctx.translateBy(x: -placed.crop.minX, y: -placed.crop.minY)
                ctx.clip(to: placed.crop)
                ctx.concatenate(placed.geometry.transform)
                ctx.drawPDFPage(ref)
                ctx.restoreGState()
                ctx.endPDFPage()
                pages += 1
            }
            if section.padsBlankPage {
                ctx.beginPDFPage(nil)
                ctx.endPDFPage()
                pages += 1
            }
        }
        ctx.closePDF()
        return ImpositionResult(sections: sections, data: data as Data, pageCount: pages)
    }

    public static func impose(files: [SourceFile], options: ImpositionOptions) -> ImpositionResult? {
        render(plan(files: files, options: options))
    }
}

public extension URL {
    /// 폴더면 안의 PDF들을(하위 폴더 포함) 경로 이름순으로 펼치고, PDF 파일만 남긴다.
    /// 숨김 파일(._로 시작하는 macOS 메타 파일 등)은 뺀다. 같은 파일은 한 번만 넣는다.
    static func expandPDFs(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default
        func isPDF(_ u: URL) -> Bool {
            u.pathExtension.lowercased() == "pdf" && !u.lastPathComponent.hasPrefix(".")
        }
        func append(_ u: URL) {
            let key = u.standardizedFileURL.resolvingSymlinksInPath().path
            if seen.insert(key).inserted { out.append(u.standardizedFileURL) }
        }
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let base = url.standardizedFileURL.path
                let items = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                    .compactMap { $0 as? URL } ?? []
                items.filter(isPDF)
                    .map { (url: $0, rel: String($0.standardizedFileURL.path.dropFirst(base.count))) }
                    .sorted { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
                    .forEach { append($0.url) }
            } else if isPDF(url) {
                append(url)
            }
        }
        return out
    }
}
