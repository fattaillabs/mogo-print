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
        .sheet(isPresented: $model.showKICE) {
            KICEDownloadView().environmentObject(model)
                .modifier(DebugSnapshot.ActiveLook())
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
            HStack(spacing: 12) {
                Button("파일 선택…") { model.openPanel() }
                Button("평가원에서 받기…") { model.showKICE = true }
            }
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
        rows += model.electiveSubjects.count
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
                ForEach(model.electiveSubjects) { subject in
                    Picker("\(subject.rawValue) 선택과목", selection: model.electiveBinding(subject)) {
                        Text("전체").tag(Elective?.none)
                        ForEach(subject.electives) { Text($0.shortName).tag(Optional($0)) }
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
                    if let subject = file.electiveSubject, let chosen = model.options.electives[subject] {
                        Text(chosen.shortName)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
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
            .help("여백 조정")
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
                    Text("A4 \(model.outputPageCount)쪽 · 종이 \(model.sheetCount)장 · 원본 대비 글자 크기 \(model.displayScale)%")
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
                Button { model.showKICE = true } label: { Label("기출 받기", systemImage: "arrow.down.circle") }
                Button { model.openPanel() } label: { Label("추가", systemImage: "plus") }
                Button("모두 비우기") { model.clear() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ZStack {
                // 수동 조정 중에도 A4 미리보기는 뒤에 그대로 둔다(돌아오면 보던 쪽이 유지되게).
                PDFPreview(document: model.preview, currentPage: $currentPage, hidden: model.manualCropFile != nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Text("점선을 끌어서 자를 위치를 정하세요. 같은 위치가 이 파일의 모든 쪽에 적용돼요.")
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

/// 여백 수동 조정 화면. 원본 쪽 전체를 보여 주고(잘려 나갈 부분은 흐리게), 네 변의 자르는 선을
/// 점선으로 그려 마우스로 끌게 한다. 손을 떼면 그 위치를 손 조정 값으로 저장한다.
struct ManualCropView: View {
    @EnvironmentObject private var model: AppModel
    let file: SourceFile

    @State private var position = 0
    /// 화면용으로 따로 연 문서. A4 합성 작업이 쓰는 문서를 화면 스레드에서 같이 건드리지 않으려고 둔다.
    @State private var document: PDFDocument?
    @State private var image: NSImage?
    /// 끄는 중인 범위(페이지 pt). 손을 떼면 저장하고 nil로 돌린다.
    @State private var draft: CGRect?

    private var pages: [Int] { file.pageIndices(for: model.options) }
    private var pageIndex: Int { pages[min(max(position, 0), max(pages.count - 1, 0))] }
    private var pageSize: CGSize { file.geometry[pageIndex].size }
    private var base: CGRect { Imposer.baseCrop(file: file, pageIndex: pageIndex, options: model.options) }
    private var committed: CGRect { Imposer.crop(file: file, pageIndex: pageIndex, options: model.options) }
    private var current: CGRect { draft ?? committed }
    private var adjust: CropAdjustment { model.options.adjustment(for: file.url) }
    private var hasEdgeAdjustment: Bool {
        adjust.top != 0 || adjust.bottom != 0 || adjust.left != 0 || adjust.right != 0
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
                Text("원본 대비 글자 크기 \(Int((Imposer.scale(for: current, options: model.options) * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("원래대로") { reset() }
                    .disabled(!hasEdgeAdjustment)
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

    /// 네 변 조정만 지우고 '자동 자르기 끄기'는 그대로 둔다.
    private func reset() {
        let a = CropAdjustment(wholePage: adjust.wholePage)
        model.options.adjustments[file.url] = a.isDefault ? nil : a
    }

    private func commit() {
        guard let d = draft else { return }
        let a = CropGuides.adjustment(crop: d, base: base, keeping: adjust)
        model.options.adjustments[file.url] = a.isDefault ? nil : a
        draft = nil
    }

    /// 화면에 그릴 때의 배치(페이지 → 화면 좌표).
    private struct Layout {
        let origin: CGPoint, scale: CGFloat, page: CGSize
        var width: CGFloat { page.width * scale }
        var height: CGFloat { page.height * scale }
        func x(_ px: CGFloat) -> CGFloat { origin.x + px * scale }
        func y(_ py: CGFloat) -> CGFloat { origin.y + (page.height - py) * scale }
        /// 화면 좌표 → 페이지 좌표(가로·세로)
        func pageX(_ vx: CGFloat) -> CGFloat { (vx - origin.x) / scale }
        func pageY(_ vy: CGFloat) -> CGFloat { page.height - (vy - origin.y) / scale }
    }

    private func canvas(_ size: CGSize, global: CGRect) -> some View {
        let page = pageSize
        // 오른쪽에는 위·아래 값 표시, 위쪽에는 좌우 값 표시 자리를 남긴다.
        let s = max(0.01, min((size.width - 150) / page.width, (size.height - 90) / page.height))
        let w = page.width * s, h = page.height * s
        let L = Layout(origin: CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2 + 10), scale: s, page: page)
        let c = current
        DebugSnapshot.recordGuide(topY: global.minY + L.y(c.maxY), centerX: global.minX + L.x(c.midX), scale: s)

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
            .offset(x: L.origin.x, y: L.origin.y)

            // 잘려 나갈 부분은 흐리게 덮는다(여백이 다시 보이되 잘린다는 걸 알 수 있게).
            Path { p in
                p.addRect(CGRect(x: L.origin.x, y: L.origin.y, width: w, height: h))
                p.addRect(CGRect(x: L.x(c.minX), y: L.y(c.maxY), width: c.width * s, height: c.height * s))
            }
            .fill(Color.black.opacity(0.22), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // 자동으로 잡은 위치(옮긴 변만 연하게 표시)
            ForEach(CropGuides.Edge.allCases, id: \.self) { edge in
                if draft != nil || moved(edge) { referenceLine(edge, base: base, layout: L) }
            }
            ForEach(CropGuides.Edge.allCases, id: \.self) { edge in
                guide(edge, crop: c, layout: L)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: "canvas")
    }

    private func moved(_ edge: CropGuides.Edge) -> Bool {
        switch edge {
        case .top: return adjust.top != 0
        case .bottom: return adjust.bottom != 0
        case .left: return adjust.left != 0
        case .right: return adjust.right != 0
        }
    }

    /// 점선의 화면 위치(가로선이면 y, 세로선이면 x)와 여백 값(원본 쪽 가장자리에서 점선까지).
    private func place(_ edge: CropGuides.Edge, _ r: CGRect, _ L: Layout) -> (pos: CGFloat, marginPt: CGFloat) {
        switch edge {
        case .top: return (L.y(r.maxY), L.page.height - r.maxY)
        case .bottom: return (L.y(r.minY), r.minY)
        case .left: return (L.x(r.minX), r.minX)
        case .right: return (L.x(r.maxX), L.page.width - r.maxX)
        }
    }

    private func isHorizontal(_ edge: CropGuides.Edge) -> Bool { edge == .top || edge == .bottom }

    private func linePath(_ edge: CropGuides.Edge, at pos: CGFloat, _ L: Layout, overhang: CGFloat) -> Path {
        Path { p in
            if isHorizontal(edge) {
                p.move(to: CGPoint(x: L.origin.x - overhang, y: pos))
                p.addLine(to: CGPoint(x: L.origin.x + L.width + overhang, y: pos))
            } else {
                p.move(to: CGPoint(x: pos, y: L.origin.y - overhang))
                p.addLine(to: CGPoint(x: pos, y: L.origin.y + L.height + overhang))
            }
        }
    }

    private func referenceLine(_ edge: CropGuides.Edge, base: CGRect, layout L: Layout) -> some View {
        linePath(edge, at: place(edge, base, L).pos, L, overhang: 0)
            .stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            .allowsHitTesting(false)
    }

    /// 끌 수 있는 점선 하나. 위·아래 값은 오른쪽에, 왼쪽·오른쪽 값은 쪽 위에 붙인다.
    private func guide(_ edge: CropGuides.Edge, crop c: CGRect, layout L: Layout) -> some View {
        let (pos, margin) = place(edge, c, L)
        let name: String = switch edge {
        case .top: "위"
        case .bottom: "아래"
        case .left: "왼쪽"
        case .right: "오른쪽"
        }
        let horizontal = isHorizontal(edge)
        let labelPoint = horizontal
            ? CGPoint(x: L.origin.x + L.width + 14 + 58, y: pos)
            : CGPoint(x: pos, y: L.origin.y - 26)
        return ZStack(alignment: .topLeading) {
            linePath(edge, at: pos, L, overhang: horizontal ? 14 : 10)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .allowsHitTesting(false)

            Text("\(name) 여백 \(String(format: "%.1f", max(0, margin) / pointsPerMM))mm")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
                .fixedSize()
                .position(labelPoint)
                .allowsHitTesting(false)

            // 잡기 쉬운 넓은 손잡이(보이지 않음). 마우스를 올리면 양쪽 화살표 커서가 된다.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: horizontal ? L.width + 28 : 16, height: horizontal ? 16 : L.height + 20)
                .position(horizontal ? CGPoint(x: L.origin.x + L.width / 2, y: pos)
                                     : CGPoint(x: pos, y: L.origin.y + L.height / 2))
                .modifier(ResizeCursor(edge: edge))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                        .onChanged { v in
                            let value = horizontal ? L.pageY(v.location.y) : L.pageX(v.location.x)
                            draft = CropGuides.move(edge, to: value, crop: draft ?? committed, pageSize: L.page)
                        }
                        .onEnded { _ in commit() }
                )
        }
    }
}

/// 점선 위에서 쓰는 양쪽 화살표 커서. macOS 15부터는 창 가장자리 크기 조절과 같은 커서를 쓰고,
/// 그 전에는 AppKit의 위아래·좌우 크기 조절 커서로 대신한다.
private struct ResizeCursor: ViewModifier {
    let edge: CropGuides.Edge

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.frameResize(position: position, directions: .all))
        } else {
            content.onHover { inside in
                let cursor: NSCursor = (edge == .top || edge == .bottom) ? .resizeUpDown : .resizeLeftRight
                (inside ? cursor : NSCursor.arrow).set()
            }
        }
    }

    @available(macOS 15.0, *)
    private var position: FrameResizePosition {
        switch edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
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
    /// 수동 조정 중에는 완전히 숨긴다. 투명하게만 두면 PDF 뷰의 텍스트 선택(I자) 커서 영역이 살아 있어
    /// 점선 위의 크기 조절 커서를 덮어쓴다.
    var hidden = false

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
        container.isHidden = hidden
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
                row("설정", "\(s.duplex ? "양면 (긴 쪽 넘김)" : "단면") · \(s.grayscale ? "흑백" : "컬러") · 원본 대비 글자 크기 \(model.displayScale)%")
                if model.hasCombinedVariants {
                    row("시험지 형", model.options.variant.rawValue)
                }
                if !model.electiveSubjects.isEmpty {
                    row("선택과목", model.electiveSubjects.map { subject in
                        "\(subject.rawValue) \(model.options.electives[subject]?.shortName ?? "전체")"
                    }.joined(separator: " · "))
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
