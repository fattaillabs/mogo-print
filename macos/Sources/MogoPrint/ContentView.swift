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
                model.adjustingFileID = file.id
            } label: {
                Image(systemName: "crop").foregroundStyle(adjusted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("자르기 손보기")
            .popover(isPresented: Binding(
                get: { model.adjustingFileID == file.id },
                set: { if !$0, model.adjustingFileID == file.id { model.adjustingFileID = nil } }
            ), arrowEdge: .trailing) {
                CropAdjustView(file: file).environmentObject(model)
            }
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

/// 파일 하나의 자르기 영역을 손으로 조정하는 창.
struct CropAdjustView: View {
    @EnvironmentObject private var model: AppModel
    let file: SourceFile

    /// 기본값으로 돌아가면 항목을 지운다(손봄 표시가 사라지게).
    private var adjust: Binding<CropAdjustment> {
        Binding(
            get: { model.options.adjustment(for: file.url) },
            set: { model.options.adjustments[file.url] = $0.isDefault ? nil : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("자르기 손보기").font(.headline)
            Text(file.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Toggle("자동 자르기 끄기 (페이지 전체 쓰기)", isOn: adjust.wholePage)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                edgeRow("위", adjust.top)
                edgeRow("아래", adjust.bottom)
                edgeRow("왼쪽", adjust.left)
                edgeRow("오른쪽", adjust.right)
            }
            Text("＋는 더 잘라내고 －는 여백을 더 남겨요. 결과는 바로 미리보기에 보여요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("원래대로") { model.options.adjustments[file.url] = nil }
                    .disabled(model.options.adjustment(for: file.url).isDefault)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private func edgeRow(_ title: String, _ value: Binding<CGFloat>) -> some View {
        GridRow {
            Text(title).frame(width: 44, alignment: .leading)
            Stepper(value: value, in: -20...40, step: 1) {
                Text(value.wrappedValue == 0 ? "0mm" : String(format: "%+.0fmm", value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
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
                Button { model.openPanel() } label: { Label("추가", systemImage: "plus") }
                Button("모두 비우기") { model.clear() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            PDFPreview(document: model.preview, currentPage: $currentPage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if let status = model.status {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(status).font(.callout).lineLimit(1)
                    Button("닫기") { model.status = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                if model.outputPageCount > 0 {
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
