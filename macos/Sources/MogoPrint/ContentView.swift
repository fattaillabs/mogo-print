import MogoCore
import PDFKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        Group {
            if model.files.isEmpty && model.loadingCount == 0 {
                DropZoneView(isTargeted: isTargeted)
            } else {
                HSplitView {
                    SidebarView()
                        .frame(minWidth: 300, idealWidth: 320, maxWidth: 380)
                    PreviewPane()
                        .frame(minWidth: 560)
                }
            }
        }
        // 창 어디에 끌어다 놓아도 파일이 추가된다.
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted && !model.files.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 4)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $model.showPrintConfirm) {
            PrintConfirmView().environmentObject(model)
                .modifier(DebugSnapshot.ActiveLook())
        }
        .alert("확인해 주세요", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("확인") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - 처음 화면

struct DropZoneView: View {
    @EnvironmentObject private var model: AppModel
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            Text("모의고사 PDF를 여기에 끌어다 놓으세요")
                .font(.title2.weight(.semibold))
            Text("여러 파일이나 폴더도 한 번에 돼요. Dock의 앱 아이콘에 놓아도 열려요.")
                .foregroundStyle(.secondary)
            Button("파일 선택…") { model.openPanel() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 18)
                    .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear))
                .padding(28)
        )
    }
}

// MARK: - 왼쪽: 파일 목록과 설정

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    /// 설정 칸 높이. 줄 수에 맞춰 늘린다(Form은 스크롤을 꺼 두었다).
    private var formHeight: CGFloat {
        var rows = 5
        if model.hasCombinedVariants { rows += 1 }
        if model.marginTooSmall { rows += 1 }
        return CGFloat(rows) * 37 + 46
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.files) { file in
                        FileRow(file: file, section: model.sections.first { $0.file.id == file.id })
                    }
                    .onMove { model.move(from: $0, to: $1) }
                    if model.loadingCount > 0 {
                        HStack { ProgressView().controlSize(.small); Text("불러오는 중…").foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("파일 · 끌어서 순서 변경")
                }
            }
            .listStyle(.sidebar)

            Divider()

            Form {
                if model.hasCombinedVariants {
                    Picker("시험지 형", selection: $model.options.variant) {
                        ForEach(ExamVariant.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Stepper(value: $model.options.paperMarginMM, in: 3...15, step: 1) {
                    Text("종이 여백 \(Int(model.options.paperMarginMM))mm")
                }
                if model.marginTooSmall, let hw = model.hardwareMarginMM {
                    Label("이 프린터는 가장자리 \(String(format: "%.1f", hw))mm 안쪽만 찍혀요. 여백을 늘려 주세요.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if model.printers.isEmpty {
                    LabeledContent("프린터", value: "설치된 프린터가 없어요")
                } else {
                    Picker("프린터", selection: $model.printSettings.printer) {
                        ForEach(model.printers, id: \.self) {
                            Text($0.replacingOccurrences(of: "_", with: " ")).tag($0)
                        }
                    }
                }
                Toggle("양면 인쇄 (긴 쪽 넘김)", isOn: $model.printSettings.duplex)
                Toggle("흑백", isOn: $model.printSettings.grayscale)
                Stepper(value: $model.printSettings.copies, in: 1...50) {
                    Text("부수 \(model.printSettings.copies)")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: formHeight)

            HStack {
                Button("PDF로 저장…") { model.savePDF() }
                    .disabled(model.preview == nil)
                Spacer()
                if model.isPrinting { ProgressView().controlSize(.small) }
                Button {
                    model.showPrintConfirm = true
                } label: {
                    Label(model.isPrinting ? "보내는 중…" : "인쇄…", systemImage: "printer")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPrint)
            }
            .padding(12)
        }
    }
}

struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: SourceFile
    let section: ExamSection?

    private var adjusted: Bool { !model.options.adjustment(for: file.url).isDefault }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let s = section {
                        Text("\(s.pageIndices.count)쪽 · \(Int((s.scale * 100).rounded()))%")
                    } else {
                        Text("\(file.pageCount)쪽")
                    }
                    if file.hasBothVariants {
                        Text("홀·짝 합본")
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    if adjusted {
                        Text("손봄")
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                    if section?.padsBlankPage == true {
                        Text("+빈 쪽")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if model.manualCropFileID == file.id {
                    model.manualCropFileID = nil
                } else {
                    model.startManualCrop(file: file)
                }
            } label: {
                Image(systemName: "crop")
                    .foregroundStyle(adjusted || model.manualCropFileID == file.id ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("위·아래 여백 조정")
            Button {
                model.remove(file)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("목록에서 빼기")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 오른쪽: 미리보기

struct PreviewPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.outputPageCount > 0 {
                    Text("A4 \(model.outputPageCount)쪽 · 종이 \(model.sheetCount)장 · 원본 대비 약 \(model.displayScale)%")
                        .font(.callout)
                }
                if model.isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    if model.manualCropFileID == nil {
                        model.startManualCrop(outputPage: currentPage)
                    } else {
                        model.manualCropFileID = nil
                    }
                } label: {
                    Label("여백 조정", systemImage: "crop")
                }
                .disabled(model.sections.isEmpty)
                Button { model.openPanel() } label: { Label("추가", systemImage: "plus") }
                Button("모두 비우기") { model.clear() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ZStack {
                // 수동 조정 중에도 A4 미리보기는 뒤에 그대로 둔다(돌아오면 보던 쪽이 유지되게).
                PDFPreview(document: model.preview, currentPage: $currentPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(model.manualCropFile == nil ? 1 : 0)
                    .allowsHitTesting(model.manualCropFile == nil)
                if let file = model.manualCropFile {
                    ManualCropView(file: file)
                        .id(file.id)
                }
            }
            Divider()
            HStack(spacing: 8) {
                if let status = model.status {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(status).font(.callout).lineLimit(1)
                    Button("닫기") { model.status = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                if model.manualCropFile != nil {
                    Text("위·아래 점선을 끌어서 자를 위치를 정하세요. 같은 위치가 이 파일의 모든 쪽에 적용돼요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if model.outputPageCount > 0 {
                    Text("\(min(currentPage + 1, model.outputPageCount)) / \(model.outputPageCount)쪽 · "
                         + (model.sourceName(forOutputPage: currentPage) ?? "빈 쪽"))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// 여백 수동 조정 화면. 원본 쪽 전체를 보여 주고(잘려 나갈 부분은 흐리게), 위·아래 자르는 선을
/// 점선으로 그려 마우스로 끌게 한다. 손을 떼면 그 위치를 손 조정 값으로 저장한다.
struct ManualCropView: View {
    @EnvironmentObject private var model: AppModel
    let file: SourceFile

    @State private var position = 0
    /// 화면용으로 따로 연 문서. A4 합성 작업이 쓰는 문서를 화면 스레드에서 같이 건드리지 않으려고 둔다.
    @State private var document: PDFDocument?
    @State private var image: NSImage?
    /// 끄는 중인 점선 위치(페이지 pt). 손을 떼면 저장하고 nil로 돌린다.
    @State private var draft: (top: CGFloat, bottom: CGFloat)?

    private var pages: [Int] { file.pageIndices(for: model.options.variant) }
    private var pageIndex: Int { pages[min(max(position, 0), max(pages.count - 1, 0))] }
    private var pageSize: CGSize { file.geometry[pageIndex].size }
    private var base: CGRect { Imposer.baseCrop(file: file, pageIndex: pageIndex, options: model.options) }
    private var committed: CGRect { Imposer.crop(file: file, pageIndex: pageIndex, options: model.options) }
    private var current: CGRect {
        guard let d = draft else { return committed }
        return CGRect(x: committed.minX, y: d.bottom, width: committed.width, height: d.top - d.bottom)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("여백 조정", selection: $model.manualCropFileID) {
                    ForEach(model.files) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 300)
                Button { position -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(position <= 0)
                Text("\(position + 1) / \(pages.count)쪽").monospacedDigit()
                Button { position += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(position >= pages.count - 1)
                Spacer()
                Text("원본 대비 \(Int((Imposer.scale(for: current, options: model.options) * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("원래대로") { reset() }
                    .disabled(model.options.adjustment(for: file.url).top == 0 && model.options.adjustment(for: file.url).bottom == 0)
                Button("완료") { model.manualCropFileID = nil }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            GeometryReader { proxy in canvas(proxy.size, global: proxy.frame(in: .global)) }
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onAppear {
            position = min(model.manualCropStartPosition, max(pages.count - 1, 0))
            document = PDFDocument(url: file.url)
            renderPage()
        }
        .onChange(of: pageIndex) { renderPage() }
    }

    private func renderPage() {
        guard let page = document?.page(at: pageIndex) else { image = nil; return }
        let size = pageSize
        let width: CGFloat = 1400
        image = page.thumbnail(of: CGSize(width: width, height: width * size.height / size.width), for: .cropBox)
    }

    private func reset() {
        var a = model.options.adjustment(for: file.url)
        a.top = 0
        a.bottom = 0
        model.options.adjustments[file.url] = a.isDefault ? nil : a
    }

    private func commit() {
        guard let d = draft else { return }
        let a = CropGuides.adjustment(top: d.top, bottom: d.bottom, base: base,
                                      keeping: model.options.adjustment(for: file.url))
        model.options.adjustments[file.url] = a.isDefault ? nil : a
        draft = nil
    }

    private func canvas(_ size: CGSize, global: CGRect) -> some View {
        let page = pageSize
        let s = max(0.01, min((size.width - 140) / page.width, (size.height - 40) / page.height))
        let w = page.width * s, h = page.height * s
        let origin = CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2)
        func vx(_ px: CGFloat) -> CGFloat { origin.x + px * s }
        func vy(_ py: CGFloat) -> CGFloat { origin.y + (page.height - py) * s }
        let c = current
        let a = model.options.adjustment(for: file.url)
        DebugSnapshot.recordGuide(topY: global.minY + vy(c.maxY), centerX: global.minX + origin.x + w / 2, scale: s)

        return ZStack(alignment: .topLeading) {
            Group {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    Rectangle().fill(Color.white)
                }
            }
            .frame(width: w, height: h)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            .offset(x: origin.x, y: origin.y)

            // 잘려 나갈 부분은 흐리게 덮는다(여백이 다시 보이되 잘린다는 걸 알 수 있게).
            Path { p in
                p.addRect(CGRect(x: origin.x, y: origin.y, width: w, height: h))
                p.addRect(CGRect(x: vx(c.minX), y: vy(c.maxY), width: c.width * s, height: c.height * s))
            }
            .fill(Color.black.opacity(0.22), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // 자동으로 잡은 위치(손으로 옮겼을 때만 연하게 표시)
            if a.top != 0 || draft != nil { referenceLine(y: vy(base.maxY), from: origin.x, width: w) }
            if a.bottom != 0 || draft != nil { referenceLine(y: vy(base.minY), from: origin.x, width: w) }

            guide(.top, y: vy(c.maxY), label: "위 여백 \(mmText(page.height - c.maxY))",
                  origin: origin, width: w, scale: s, page: page)
            guide(.bottom, y: vy(c.minY), label: "아래 여백 \(mmText(c.minY))",
                  origin: origin, width: w, scale: s, page: page)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: "canvas")
    }

    private func mmText(_ pt: CGFloat) -> String {
        String(format: "%.1fmm", max(0, pt) / pointsPerMM)
    }

    private func referenceLine(y: CGFloat, from x: CGFloat, width: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + width, y: y))
        }
        .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        .allowsHitTesting(false)
    }

    /// 끌 수 있는 점선 하나. 페이지 폭보다 조금 길게 그리고, 오른쪽에 여백 값을 붙인다.
    private func guide(_ edge: CropGuides.Edge, y: CGFloat, label: String, origin: CGPoint,
                       width: CGFloat, scale s: CGFloat, page: CGSize) -> some View {
        let x0 = origin.x - 14, x1 = origin.x + width + 14
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: x0, y: y))
                p.addLine(to: CGPoint(x: x1, y: y))
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))

            Text(label)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
                .fixedSize()
                .position(x: x1 + 4 + 48, y: y)

            // 잡기 쉬운 넓은 손잡이(보이지 않음)
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: x1 - x0 + 110, height: 18)
                .position(x: (x0 + x1 + 110) / 2, y: y)
                .onHover { inside in (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                        .onChanged { v in
                            let start = draft ?? (committed.maxY, committed.minY)
                            let py = page.height - (v.location.y - origin.y) / s
                            draft = CropGuides.move(edge, to: py, top: start.top, bottom: start.bottom,
                                                    pageHeight: page.height)
                        }
                        .onEnded { _ in commit() }
                )
        }
    }
}

/// 쪽 전체가 한 화면에 보이도록 맞추는 PDFView. 사용자가 확대/축소하면 그 배율을 유지한다.
final class FitPagePDFView: PDFView {
    private var lastFitScale: CGFloat?

    func fitPage() {
        // scaleFactorForSizeToFit은 연속 보기에서 너비에만 맞추므로 직접 계산한다.
        guard let page = currentPage ?? document?.page(at: 0), bounds.width > 0, bounds.height > 0 else { return }
        let size = page.bounds(for: displayBox).size
        let avail = bounds.insetBy(dx: 20, dy: 20)
        let fit = min(avail.width / size.width, avail.height / size.height)
        guard fit > 0 else { return }
        scaleFactor = fit
        lastFitScale = scaleFactor
    }

    override func layout() {
        super.layout()
        // 아직 사용자가 배율을 바꾸지 않았으면 창 크기에 맞춰 다시 맞춘다.
        if lastFitScale == nil || abs(scaleFactor - (lastFitScale ?? 0)) < 0.001 {
            fitPage()
        }
    }
}

/// 왼쪽 썸네일 줄 + 오른쪽 큰 미리보기.
final class PreviewContainerView: NSView {
    let pdfView = FitPagePDFView()
    let thumbnails = PDFThumbnailView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .underPageBackgroundColor

        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = CGSize(width: 76, height: 108)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.backgroundColor = .controlBackgroundColor

        separator.boxType = .separator
        [thumbnails, separator, pdfView].forEach { addSubview($0) }
    }

    private let separator = NSBox()
    static let thumbnailWidth: CGFloat = 104

    /// SwiftUI가 준 크기를 직접 나눈다(안쪽 Auto Layout은 SwiftUI 크기를 못 받아 높이가 1로 잡혔다).
    override func layout() {
        super.layout()
        let w = Self.thumbnailWidth
        thumbnails.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        separator.frame = NSRect(x: w, y: 0, width: 1, height: bounds.height)
        pdfView.frame = NSRect(x: w + 1, y: 0, width: max(0, bounds.width - w - 1), height: bounds.height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument?
    @Binding var currentPage: Int

    func makeCoordinator() -> Coordinator { Coordinator(currentPage: $currentPage) }

    /// 내용 크기가 정해져 있지 않은 뷰라 주어진 공간을 다 쓴다.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewContainerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 700)
    }

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        context.coordinator.observe(view.pdfView)
        return view
    }

    func updateNSView(_ container: PreviewContainerView, context: Context) {
        context.coordinator.currentPage = $currentPage
        let view = container.pdfView
        guard view.document !== document else { return }
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        view.document = document
        view.fitPage()
        // 설정을 바꿔 다시 만들어도 보던 쪽을 유지한다.
        if let doc = document, pageIndex > 0, pageIndex < doc.pageCount, let page = doc.page(at: pageIndex) {
            view.go(to: page)
        }
        context.coordinator.pageChanged(view)
    }

    final class Coordinator: NSObject {
        var currentPage: Binding<Int>
        private var token: NSObjectProtocol?

        init(currentPage: Binding<Int>) { self.currentPage = currentPage }

        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] note in
                guard let view = note.object as? PDFView else { return }
                MainActor.assumeIsolated { self?.pageChanged(view) }
            }
        }

        @MainActor
        func pageChanged(_ view: PDFView) {
            let index = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
            if currentPage.wrappedValue != index {
                // 화면 갱신 중에 상태를 바꾸지 않도록 다음 차례로 미룬다.
                DispatchQueue.main.async { self.currentPage.wrappedValue = index }
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

// MARK: - 인쇄 확인

struct PrintConfirmView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = model.printSettings
        VStack(alignment: .leading, spacing: 16) {
            Text("이대로 인쇄할까요?")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                row("프린터", s.printer.replacingOccurrences(of: "_", with: " "))
                row("분량", "A4 \(model.outputPageCount)쪽 · 종이 \(model.sheetCount)장 × \(s.copies)부")
                row("설정", "\(s.duplex ? "양면 (긴 쪽 넘김)" : "단면") · \(s.grayscale ? "흑백" : "컬러") · 원본 대비 약 \(model.displayScale)%")
                if model.hasCombinedVariants {
                    row("시험지 형", model.options.variant.rawValue)
                }
            }

            if model.marginTooSmall, let hw = model.hardwareMarginMM {
                Label("종이 여백 \(Int(model.options.paperMarginMM))mm가 프린터 인쇄 범위(\(String(format: "%.1f", hw))mm)보다 좁아서 가장자리가 잘릴 수 있어요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                // 파일이 많으면 창이 길어지지 않게 앞의 몇 개만 보여 준다.
                ForEach(model.sections.prefix(8), id: \.file.id) { sec in
                    Text("• \(sec.file.name)  \(sec.pageIndices.count)쪽")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if model.sections.count > 8 {
                    Text("  외 \(model.sections.count - 8)개 파일")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("인쇄") {
                    model.printNow()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
