import AppKit
import MogoCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// 개발용 자동 UI 점검. 화면 기록·손쉬운 사용 권한 없이 앱이 스스로 화면을 그려 저장한다.
///
///     MogoPrint --snapshot-dir <폴더> [--snapshot-drop <pdf나 폴더>]... [--snapshot-drop-more <pdf>] [--snapshot-quit]
///
/// - `--snapshot-drop`: 빈 창에 끌어다 놓기를 흉내 낸다. AppKit이 실제 드롭 때 부르는
///   draggingEntered → performDragOperation 경로를 가짜 드래그 정보로 호출한다.
/// - `--snapshot-drop-more`: 미리보기 위에 하나 더 놓는다(PDF 뷰가 드롭을 가로채지 않는지).
/// - 저장: empty.png, main.png/pdf, adjust.png, adjusted.pdf, confirm.png, report.json (PNG는 2배 해상도)
/// - 캡처용: `--snapshot-appearance light`, `--snapshot-size 1180x800`(창 내용 크기), `--snapshot-copies 2`(부수)
/// - `--snapshot-quit`처럼 값 없는 옵션은 반드시 맨 뒤에 둔다(아래 forcedColorScheme 설명).
@MainActor
enum DebugSnapshot {
    private static var args: [String] { ProcessInfo.processInfo.arguments }

    static func values(_ flag: String) -> [String] {
        var out: [String] = []
        for (i, a) in args.enumerated() where a == flag && i + 1 < args.count { out.append(args[i + 1]) }
        return out
    }

    /// `--snapshot-appearance light|dark`로 화면 모드를 정한다.
    /// macOS는 `-이름 값`을 짝지어 읽어서, 값 없는 옵션이 중간에 끼면 뒤의 PDF 경로가 '열 파일'로 처리돼
    /// 창이 안 만들어진다. 그래서 캡처 옵션은 모두 값을 받게 했다(값 없는 --snapshot-quit는 맨 뒤에).
    static var forcedColorScheme: ColorScheme? {
        switch values("--snapshot-appearance").first {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// 자동 점검 중에는 앱이 비활성이라 SwiftUI가 흐린 '비활성 창' 모양으로 그린다(강조 버튼이 하얗게 사라짐).
    /// 캡처가 실제 쓰는 모습과 같도록 활성 창 모양으로 그린다. 평소에는 아무것도 바꾸지 않는다.
    struct ActiveLook: ViewModifier {
        func body(content: Content) -> some View {
            if DebugSnapshot.directory != nil {
                content.environment(\.controlActiveState, .key)
            } else {
                content
            }
        }
    }

    static var directory: URL? {
        values("--snapshot-dir").first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func startIfRequested() {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { await run(dir) }
    }

    private static func run(_ dir: URL) async {
        let model = AppModel.shared
        var report: [String: Any] = [:]
        func log(_ s: String) { FileHandle.standardError.write("[snapshot] \(s)\n".data(using: .utf8)!) }

        _ = await wait(5) { mainWindow != nil }
        if mainWindow == nil {
            log("main window not found (값 없는 옵션이 중간에 있지 않은지 확인); windows=\(NSApp.windows.count)")
        }
        if let size = values("--snapshot-size").first?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            mainWindow?.setContentSize(CGSize(width: size[0], height: size[1]))
        }
        if let copies = values("--snapshot-copies").first.flatMap({ Int($0) }) { model.printSettings.copies = copies }
        let drops = values("--snapshot-drop").map { URL(fileURLWithPath: $0) }
        let more = values("--snapshot-drop-more").map { URL(fileURLWithPath: $0) }

        if !drops.isEmpty {
            await pause(1)
            capture(mainWindow, to: dir.appendingPathComponent("empty.png"))
            let accepted = simulateDrop(drops, at: CGPoint(x: 0.5, y: 0.5))
            report["drop_accepted"] = accepted
            log("drop accepted=\(accepted)")
        }

        // 미리보기가 준비될 때까지 (파일이 없으면 3초만 기다린다)
        let ready = await wait(90) { isReady(model) }
            || (model.files.isEmpty && model.loadingCount == 0)
        report["ready"] = ready

        if !more.isEmpty, !model.files.isEmpty {
            let before = model.files.count
            // 오른쪽 미리보기 한가운데에 놓는다.
            let accepted = simulateDrop(more, at: CGPoint(x: 0.7, y: 0.5))
            _ = await wait(30) { model.files.count > before && isReady(model) }
            report["drop_more_accepted"] = accepted
            report["drop_more_added"] = model.files.count - before
        }

        await pause(2) // PDF 타일이 그려질 때까지
        capture(mainWindow, to: dir.appendingPathComponent("main.png"))
        report["files"] = model.files.map(\.name)
        report["output_pages"] = model.outputPageCount
        report["sheets"] = model.sheetCount
        report["display_scale"] = model.displayScale
        report["sections"] = model.sections.map {
            ["name": $0.file.name, "pages": $0.pageIndices.count, "scale": Double($0.scale), "blank": $0.padsBlankPage]
        }
        report["hardware_margin_mm"] = model.hardwareMarginMM.map { Double($0) } ?? -1
        if let thumbs = findView(PDFThumbnailView.self, in: mainWindow?.contentView) {
            report["thumbnail_view"] = "frame=\(thumbs.frame) hasPDFView=\(thumbs.pdfView != nil)"
        }
        if let pv = findView(PDFView.self, in: mainWindow?.contentView) {
            report["pdf_view"] = "frame=\(pv.frame) pages=\(pv.document?.pageCount ?? -1) scale=\(String(format: "%.3f", pv.scaleFactor)) visible=\(pv.visiblePages.count) window=\(pv.window != nil)"
            // PDFView 내용만 따로 벡터로 저장(창 캡처에는 레이어로 그려진 내용이 안 나올 수 있다).
            try? pv.dataWithPDF(inside: pv.bounds).write(to: dir.appendingPathComponent("preview.pdf"))
        }

        if let first = model.files.first {
            let light = forcedColorScheme == .light
            // 자르기 손보기 창을 화면 밖 창에 그려 레이아웃을 확인한다.
            // (팝오버는 앱이 활성 상태일 때만 유지되는데, 자동 점검은 다른 앱 포커스를 뺏지 않으려 비활성으로 돈다.)
            let host = NSHostingView(rootView: CropAdjustView(file: first).environmentObject(model)
                .modifier(ActiveLook())
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(forcedColorScheme))
            if light { host.appearance = NSAppearance(named: .aqua) }
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let offscreen = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            offscreen.contentView = host
            host.layoutSubtreeIfNeeded()
            await pause(0.3)
            if let rep = bitmap(for: host) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("adjust.png"))
                report["adjust_view_size"] = "\(Int(host.bounds.width))x\(Int(host.bounds.height))"
            }
            // 위를 10mm 더 자르면 그 파일의 배율이 커져야 한다.
            let scaleBefore = model.sections.first { $0.file.id == first.id }?.scale ?? 0
            model.options.adjustments[first.url] = CropAdjustment(top: 10)
            _ = await wait(30) { isReady(model) }
            let scaleAfter = model.sections.first { $0.file.id == first.id }?.scale ?? 0
            report["adjust_scale_before"] = Double(scaleBefore)
            report["adjust_scale_after"] = Double(scaleAfter)
            capturePDF(of: mainWindow, to: dir.appendingPathComponent("adjusted.pdf"))
            model.options.adjustments[first.url] = nil
            _ = await wait(30) { isReady(model) }
        }

        if model.canPrint {
            model.showPrintConfirm = true
            if await wait(3, { mainWindow?.attachedSheet != nil }) {
                await pause(0.7)
                capture(mainWindow?.attachedSheet, to: dir.appendingPathComponent("confirm.png"))
                report["confirm_sheet"] = true
            }
            model.showPrintConfirm = false
            await pause(0.5)
        }

        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("report.json"))
        }
        log("saved to \(dir.path)")
        if args.contains("--snapshot-quit") { NSApp.terminate(nil) }
    }

    // MARK: 기다리기

    private static func isReady(_ model: AppModel) -> Bool {
        model.preview != nil && !model.isWorking && model.loadingCount == 0
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 조건이 맞을 때까지 0.2초마다 확인한다.
    private static func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            await pause(0.2)
        }
        return condition()
    }

    // MARK: 창 찾기·캡처

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.contentView != nil && $0.frame.width > 400 }
    }

    private static func findView<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for s in view.subviews { if let v = findView(type, in: s) { return v } }
        return nil
    }

    /// 2배 해상도 비트맵.
    private static func bitmap(for view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func capture(_ window: NSWindow?, to url: URL) {
        // 제목 표시줄까지 포함하려고 contentView의 상위(프레임) 뷰를 그린다.
        guard let window, let view = window.contentView?.superview ?? window.contentView,
              let rep = bitmap(for: view)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // PDFView는 페이지를 비동기 레이어로 그려서 비트맵 캡처에 하얗게 나온다. 벡터로 따로 그려 그 자리에 덮는다.
        if let pv = findView(PDFView.self, in: window.contentView),
           let image = NSImage(data: pv.dataWithPDF(inside: pv.bounds)) {
            var rect = pv.convert(pv.bounds, to: view)
            if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        // PDFView는 페이지를 비동기 레이어로 그려서 비트맵 캡처에 안 나올 수 있다. 벡터 캡처도 같이 저장한다.
        capturePDF(of: window, to: url.deletingPathExtension().appendingPathExtension("pdf"))
    }

    private static func capturePDF(of window: NSWindow?, to url: URL) {
        guard let window, let view = window.contentView?.superview ?? window.contentView else { return }
        try? view.dataWithPDF(inside: view.bounds).write(to: url)
    }

    // MARK: 끌어다 놓기 흉내

    /// 창 안 상대 위치(0~1)에 파일을 놓는다. 받아들였으면 true.
    private static func simulateDrop(_ urls: [URL], at relative: CGPoint) -> Bool {
        guard let window = mainWindow, let content = window.contentView else { return false }
        let pb = NSPasteboard(name: NSPasteboard.Name("mogoprint-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        let point = NSPoint(x: content.bounds.width * relative.x, y: content.bounds.height * relative.y)
        let info = FakeDraggingInfo(pasteboard: pb, window: window, location: content.convert(point, to: nil))
        // 그 자리에 있는 뷰부터 위로 올라가며 파일 드롭을 받는 뷰를 찾는다(AppKit과 같은 순서).
        // AppKit처럼, 그 점을 덮고 파일 URL을 받을 수 있는 형식을 등록한 뷰 중 가장 앞(깊은) 뷰로 보낸다.
        // SwiftUI는 드롭 영역마다 숨은 하위 뷰를 두고 public.item 같은 상위 형식으로 등록한다.
        let windowPoint = content.convert(point, to: nil)
        let accepts: (NSView) -> Bool = { v in
            v.registeredDraggedTypes.contains { t in
                t == .fileURL || (UTType(t.rawValue).map { UTType.fileURL.conforms(to: $0) } ?? false)
            }
        }
        var candidates: [NSView] = []
        func collect(_ v: NSView) {
            guard !v.isHidden else { return }
            if accepts(v), v.bounds.contains(v.convert(windowPoint, from: nil)) { candidates.append(v) }
            v.subviews.forEach(collect)
        }
        collect(window.contentView?.superview ?? content)
        let hit = content.hitTest(content.convert(point, to: content.superview))
        guard let dest = candidates.last else {
            // 진단: 드롭 형식을 등록한 뷰를 모두 적는다.
            func dump(_ v: NSView, _ depth: Int) {
                if !v.registeredDraggedTypes.isEmpty {
                    FileHandle.standardError.write("[snapshot] \(String(repeating: " ", count: depth))\(type(of: v)) \(v.registeredDraggedTypes.map(\.rawValue))\n".data(using: .utf8)!)
                }
                v.subviews.forEach { dump($0, depth + 1) }
            }
            FileHandle.standardError.write("[snapshot] no drop target; hit=\(hit.map { "\(type(of: $0))" } ?? "nil")\n".data(using: .utf8)!)
            dump(window.contentView?.superview ?? content, 0)
            return false
        }
        FileHandle.standardError.write("[snapshot] drop target: \(type(of: dest))\n".data(using: .utf8)!)
        let entered = dest.draggingEntered(info)
        let updated = dest.draggingUpdated(info)
        guard !updated.isEmpty || !entered.isEmpty else { return false }
        guard dest.prepareForDragOperation(info) else { return false }
        let ok = dest.performDragOperation(info)
        dest.concludeDragOperation(info)
        pb.releaseGlobally()
        return ok
    }
}

/// AppKit이 드롭 대상에 넘기는 드래그 정보를 흉내 낸다.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let window: NSWindow
    let location: NSPoint

    init(pasteboard: NSPasteboard, window: NSWindow, location: NSPoint) {
        self.pasteboard = pasteboard
        self.window = window
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4242 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [],
                                for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let objects = pasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop: ObjCBool = false
        for (i, obj) in objects.enumerated() {
            guard let writer = obj as? NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), i, &stop)
            if stop.boolValue { break }
        }
    }
}
