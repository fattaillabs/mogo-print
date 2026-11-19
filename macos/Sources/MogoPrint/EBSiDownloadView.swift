import AppKit
import MogoCore
import SwiftUI
import WebKit

/// '기출 받기' 창의 교육청 학력평가 탭. 문제지는 EBSi에서만 제공되므로, 사용자가 앱 안 로그인 창에서
/// EBSi에 로그인한 상태(쿠키)로 목록을 읽어 받는다. 로그인이 확인되기 전에는 목록을 부르지 않는다.
struct EBSiDownloadPane: View {
    @EnvironmentObject private var model: AppModel
    let dismiss: () -> Void

    /// 자동 점검(README 그림)용 예시 목록. 있으면 EBSi에 접속하지 않고 이것을 보여 준다.
    nonisolated(unsafe) static var demo: (page: String, rows: String)?

    @State private var grade: EBSiArchive.Grade = .third
    @State private var info: EBSiArchive.PageInfo?
    @State private var year: Int?
    @State private var months: [(month: Int, exam: String)] = []
    @State private var month: Int?
    @State private var papers: [EBSiArchive.Paper] = []
    @State private var checked: Set<String> = []
    @State private var includeExplanations = false
    @State private var loading = false
    @State private var error: String?
    @State private var progress: String?
    @State private var showLogin = false
    @State private var reloadToken = 0

    private struct MonthsKey: Hashable { let grade: EBSiArchive.Grade; let year: Int?; let token: Int }
    private struct PapersKey: Hashable { let grade: EBSiArchive.Grade; let year: Int?; let month: Int?; let token: Int }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if info?.loggedIn != false { choosers }

            Group {
                if info?.loggedIn == false {
                    loginPrompt
                } else if loading || info == nil {
                    ProgressView("EBSi에서 목록을 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 10) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("다시 시도") { reloadToken += 1 }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if papers.isEmpty {
                    Text(months.isEmpty ? "이 해에는 아직 올라온 학력평가가 없어요." : "이 시험은 아직 올라온 문제지가 없어요.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    paperList
                }
            }
            .frame(maxHeight: .infinity)

            Toggle("해설지도 받기", isOn: $includeExplanations)
            Text("EBSi 기출문제에서 받아 다운로드 폴더의 '모고 프린트' 폴더에 저장해요. 문제지 저작권은 시·도교육청에 있어요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let progress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("받기") { Task { await download() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(checked.isEmpty || progress != nil || loading)
            }
        }
        .task(id: MonthsKey(grade: grade, year: year, token: reloadToken)) { await loadMonths() }
        .task(id: PapersKey(grade: grade, year: year, month: month, token: reloadToken)) { await loadPapers() }
        .sheet(isPresented: $showLogin) {
            EBSiLoginSheet { showLogin = false; reloadToken += 1 }
        }
    }

    private var choosers: some View {
        HStack(spacing: 12) {
            Picker("학년", selection: $grade) {
                ForEach(EBSiArchive.Grade.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            Picker("연도", selection: $year) {
                ForEach(info?.years ?? [], id: \.self) { Text("\(String($0))년").tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(width: 100)
            .disabled(info?.loggedIn != true)
            Picker("시험", selection: $month) {
                ForEach(months, id: \.month) { Text($0.exam).tag(Optional($0.month)) }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(months.isEmpty)
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 12) {
            Text("교육청 학력평가 문제지는 EBSi에서만 제공돼요.\nEBSi에 로그인하면 여기서 바로 받을 수 있어요.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("EBSi 로그인…") { showLogin = true }
                .controlSize(.large)
            Text("아이디와 비밀번호는 EBSi 화면에 직접 넣고, 모고 프린트는 저장하지 않아요.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paperList: some View {
        List {
            ForEach(areas, id: \.self) { area in
                Section(EBSiArchive.areaName(area)) {
                    ForEach(papers.filter { $0.area == area }) { p in
                        Toggle(isOn: Binding(
                            get: { checked.contains(p.id) },
                            set: { if $0 { checked.insert(p.id) } else { checked.remove(p.id) } }
                        )) {
                            Text(label(p))
                        }
                    }
                }
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
    }

    private func label(_ p: EBSiArchive.Paper) -> String {
        guard let v = p.variant else { return p.subject }
        return p.subject + " " + v.rawValue
    }

    private var areas: [String] {
        var out: [String] = []
        for p in papers where !out.contains(p.area) { out.append(p.area) }
        return out
    }

    // MARK: 불러오기

    /// 로그인 여부와 연도·영역을 읽고, 그 학년·연도에 학평이 있었던 달을 찾는다.
    private func loadMonths() async {
        loading = true
        error = nil
        papers = []
        if let demo = Self.demo {
            let page = EBSiArchive.parsePage(demo.page)
            info = page
            if year == nil { year = page.years.first; return }
            months = EBSiArchive.educationOfficeMonths(EBSiArchive.parseRows(demo.rows))
            if month == nil { month = months.first?.month }
            return
        }
        do {
            let cookies = await EBSiSession.cookieHeader()
            let page = try await EBSiArchive.pageInfo(grade, cookies: cookies)
            info = page
            guard page.loggedIn else { loading = false; return }
            if year == nil || !page.years.contains(year!) { year = page.years.first; return } // 연도가 바뀌면 다시 불린다
            guard let y = year else { loading = false; return }
            months = try await EBSiArchive.months(grade, year: y, info: page, cookies: cookies)
            if month == nil || !months.contains(where: { $0.month == month }) { month = months.first?.month }
            if months.isEmpty { loading = false }
        } catch {
            self.error = "EBSi에 연결하지 못했어요.\n\(error.localizedDescription)"
            loading = false
        }
    }

    private func loadPapers() async {
        guard let info, info.loggedIn, let y = year, let m = month, months.contains(where: { $0.month == m }) else { return }
        if let demo = Self.demo {
            papers = EBSiArchive.parseRows(demo.rows).filter { $0.year == y && $0.month == m }
            checked = EBSiArchive.preselect(papers, electives: model.options.electives)
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            let found = try await EBSiArchive.papers(grade, year: y, month: m, info: info, cookies: await EBSiSession.cookieHeader())
            papers = found
            checked = EBSiArchive.preselect(found, electives: model.options.electives)
        } catch EBSiArchive.FetchError.notLoggedIn {
            self.info = nil
            reloadToken += 1
        } catch {
            papers = []
            self.error = "목록을 불러오지 못했어요: \(error.localizedDescription)"
        }
        loading = false
    }

    private func download() async {
        let chosen = papers.filter { checked.contains($0.id) }
        guard let first = chosen.first else { return }
        let dir = EBSiArchive.folder(first, base: KICEDownloadView.baseDir)
        var saved: [URL] = []
        do {
            for p in chosen {
                progress = "\(p.subject) 받는 중…"
                if let url = try await EBSiArchive.save(p, to: dir) { saved.append(url) }
                if includeExplanations, let url = try await EBSiArchive.save(p, explanation: true, to: dir) { saved.append(url) }
            }
        } catch {
            progress = nil
            self.error = "받지 못했어요: \(error.localizedDescription)"
            return
        }
        progress = nil
        model.add(urls: saved, keepOrder: true)
        dismiss()
    }
}

/// 앱 안 웹 화면의 EBSi 로그인 쿠키.
enum EBSiSession {
    /// 앱 안 웹 화면 저장소에 있는 EBSi 쿠키를 요청 헤더로 만든다(만료된 것은 뺀다).
    @MainActor
    static func cookieHeader() async -> String {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let host = "www.ebsi.co.kr"
        let now = Date()
        let matching = cookies.filter { c in
            let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return (host == domain || host.hasSuffix("." + domain)) && (c.expiresDate.map { $0 > now } ?? true)
        }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"] ?? ""
    }

    /// 앱 안 웹 화면의 EBSi 로그인 정보를 지운다(로그아웃).
    @MainActor
    static func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("ebs") })
    }
}

/// EBSi 로그인 창. 사용자가 EBSi 화면에 직접 로그인하고, 기출문제 페이지로 돌아와 로그인 상태가 확인되면 닫힌다.
struct EBSiLoginSheet: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("EBSi 로그인").font(.headline)
                Spacer()
                Text("아이디와 비밀번호는 모고 프린트가 저장하지 않아요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("닫기") { onDone() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            EBSiWebView(onLoggedIn: onDone)
        }
        .frame(width: 620, height: 720)
    }
}

private struct EBSiWebView: NSViewRepresentable {
    let onLoggedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoggedIn: onLoggedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: EBSiArchive.loginURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onLoggedIn: () -> Void
        private var done = false
        init(onLoggedIn: @escaping () -> Void) { self.onLoggedIn = onLoggedIn }

        /// 기출문제 페이지로 돌아왔을 때 그 페이지의 로그인 표시(loginTF)를 확인한다.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, webView.url?.path.contains("previousPaperList") == true else { return }
            webView.evaluateJavaScript("typeof loginTF !== 'undefined' ? loginTF : ''") { [weak self] value, _ in
                guard let self, !self.done, (value as? String) == "true" else { return }
                self.done = true
                DispatchQueue.main.async { self.onLoggedIn() }
            }
        }

        /// 새 창으로 열리는 링크(간편 로그인 등)는 같은 화면에서 연다.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "확인")
            alert.addButton(withTitle: "취소")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
