import AppKit
import MogoCore
import os
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var files: [SourceFile] = []
    @Published var options = ImpositionOptions() {
        didSet { if oldValue != options { rebuild() } }
    }
    @Published var printSettings = PrintSettings(printer: "") {
        didSet {
            if oldValue.printer != printSettings.printer { refreshHardwareMargin() }
            // 양면 여부·부수에 따라 빈 페이지가 달라지므로 다시 만든다.
            if padding(for: oldValue) != padding(for: printSettings) { rebuild() }
        }
    }
    @Published private(set) var printers: [String] = []
    /// 고른 프린터의 A4 인쇄 불가 여백(mm). 모르면 nil.
    @Published private(set) var hardwareMarginMM: CGFloat?
    @Published private(set) var preview: PDFDocument?
    @Published private(set) var sections: [ExamSection] = []
    @Published private(set) var outputPageCount = 0
    @Published private(set) var isWorking = false
    @Published private(set) var isPrinting = false
    @Published private(set) var loadingCount = 0
    @Published var status: String?
    @Published var errorMessage: String?
    @Published var showPrintConfirm = false
    /// 자르기 손보기 창이 열린 파일(한 번에 하나).
    @Published var adjustingFileID: UUID?

    private var outputData: Data?
    private var generation = 0
    /// 지금 불러오는 중인 파일(같은 파일을 두 번 넣지 않으려고).
    private var loadingPaths = Set<String>()
    /// A4 합성은 한 번에 하나씩만 한다. PDFKit 문서를 여러 스레드가 같이 그리면 안전하지 않다.
    private let renderQueue = DispatchQueue(label: "mogoprint.render", qos: .userInitiated)
    /// 합성 큐가 밀렸을 때 낡은 요청을 건너뛰려고 최신 번호를 스레드 안전하게 둔다.
    private let latestGeneration = OSAllocatedUnfairLock(initialState: 0)

    init() {
        let found = Printing.printers()
        printers = found.names
        printSettings = PrintSettings(printer: found.defaultName ?? "")
        refreshHardwareMargin()
    }

    // MARK: 파일

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func add(urls: [URL]) {
        let existing = Set(files.map { Self.key($0.url) }).union(loadingPaths)
        // 여러 파일을 한 번에 끌어 놓으면 SwiftUI가 도착 순서를 섞어서 넘길 수 있다(실측).
        // 한 묶음 안에서는 Finder 기본 정렬처럼 이름순으로 맞춘다. 순서는 목록에서 끌어서 바꾸면 된다.
        let batch = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let pdfs = URL.expandPDFs(batch).filter { !existing.contains(Self.key($0)) }
        guard !pdfs.isEmpty else {
            if !urls.isEmpty && URL.expandPDFs(urls).isEmpty {
                errorMessage = "PDF 파일(또는 PDF가 든 폴더)만 열 수 있어요."
            }
            return
        }
        let keys = pdfs.map(Self.key)
        loadingPaths.formUnion(keys)
        loadingCount += pdfs.count
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = SourceFile.load(pdfs)
            DispatchQueue.main.async {
                self.loadingCount -= pdfs.count
                self.loadingPaths.subtract(keys)
                let ok = loaded.compactMap { $0 }
                self.files += ok
                let failed = zip(pdfs, loaded).filter { $0.1 == nil }.map { $0.0.lastPathComponent }
                if !failed.isEmpty {
                    self.errorMessage = "열지 못한 PDF가 있어요. 암호가 걸렸거나 손상된 파일일 수 있어요.\n"
                        + failed.joined(separator: "\n")
                }
                self.rebuild()
            }
        }
    }

    func remove(_ file: SourceFile) {
        files.removeAll { $0.id == file.id }
        options.adjustments[file.url] = nil
        rebuild()
    }

    func move(from source: IndexSet, to destination: Int) {
        files.move(fromOffsets: source, toOffset: destination)
        rebuild()
    }

    func clear() {
        files = []
        status = nil
        options.adjustments = [:]
        rebuild()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, .folder]
        panel.message = "모의고사 PDF 파일이나 폴더를 고르세요"
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    // MARK: 변환

    var hasCombinedVariants: Bool { files.contains { $0.hasBothVariants } }

    var sheetCount: Int {
        printSettings.duplex ? (outputPageCount + 1) / 2 : outputPageCount
    }

    /// 화면에 보여줄 대표 배율(가장 작은 값).
    var displayScale: Int {
        Int(((sections.map(\.scale).min() ?? 0) * 100).rounded())
    }

    /// 종이 여백이 프린터가 찍을 수 있는 범위보다 좁은지.
    var marginTooSmall: Bool {
        guard let hw = hardwareMarginMM else { return false }
        return options.paperMarginMM + 0.05 < hw
    }

    /// 결과 쪽 번호(0부터)가 어느 파일에서 왔는지. 빈 쪽이면 nil.
    func sourceName(forOutputPage index: Int) -> String? {
        var start = 0
        for s in sections {
            if index < start + s.pages.count { return s.file.name }
            start += s.outputPageCount
            if index < start { return nil }
        }
        return nil
    }

    private func padding(for s: PrintSettings) -> (Bool, Bool) {
        (s.duplex, s.duplex && s.copies > 1)
    }

    private func refreshHardwareMargin() {
        hardwareMarginMM = Printing.hardwareMarginMM(printer: printSettings.printer)
    }

    func rebuild() {
        generation += 1
        let gen = generation
        latestGeneration.withLock { $0 = gen }
        let files = self.files
        var opts = options
        opts.padSectionsToEven = printSettings.duplex
        // 양면으로 여러 부를 뽑을 때 다음 부가 앞 부의 마지막 장 뒷면에서 시작하지 않게 한다.
        opts.padEndToEven = printSettings.duplex && printSettings.copies > 1
        guard !files.isEmpty else {
            preview = nil
            sections = []
            outputData = nil
            outputPageCount = 0
            isWorking = false
            return
        }
        isWorking = true
        let latest = latestGeneration
        renderQueue.async {
            // 큐에서 기다리는 사이 더 새 요청이 들어왔으면 건너뛴다.
            guard latest.withLock({ $0 }) == gen else { return }
            let result = Imposer.impose(files: files, options: opts)
            let doc = result.flatMap { PDFDocument(data: $0.data) }
            DispatchQueue.main.async {
                guard gen == self.generation else { return } // 더 최신 요청이 있으면 버린다
                self.isWorking = false
                self.sections = result?.sections ?? []
                self.outputData = result?.data
                self.outputPageCount = result?.pageCount ?? 0
                self.preview = doc
                if result == nil { self.errorMessage = "A4로 변환하지 못했어요." }
            }
        }
    }

    // MARK: 출력

    var jobTitle: String { files.map(\.name).joined(separator: ", ") }

    var canPrint: Bool {
        preview != nil && !isWorking && !isPrinting && !printSettings.printer.isEmpty
    }

    func printNow() {
        guard let data = outputData, !isPrinting else { return }
        let settings = printSettings
        let title = jobTitle
        isPrinting = true
        status = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MogoPrint-\(UUID().uuidString.prefix(8)).pdf")
            var message: String?
            var failure: String?
            do {
                try data.write(to: url)
                let id = try Printing.submit(file: url, settings: settings, title: title)
                message = "인쇄를 보냈어요. \(settings.printer.replacingOccurrences(of: "_", with: " "))"
                    + (id.isEmpty ? "" : " · 작업 \(id)")
            } catch {
                failure = error.localizedDescription
            }
            // lp는 파일을 인쇄 대기열로 복사한 뒤 끝나므로 지워도 된다.
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self.isPrinting = false
                if let message { self.status = message }
                if let failure { self.errorMessage = failure }
            }
        }
    }

    func savePDF() {
        guard let data = outputData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (files.count == 1 ? files[0].name : "모의고사") + "_A4.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            status = "저장했어요: \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
