import AppKit
import MogoCore
import SwiftUI

/// 자동 업데이트. 앱을 열 때 GitHub 최신 릴리스를 확인하고, 새 버전이 있으면 화면 아래 한 줄로 알린다.
/// 업데이트하면 DMG를 받아 그 안의 앱이 FatTail Labs가 서명·공증한 앱인지 확인한 뒤, 앱이 끝나면 바꾸고 다시 연다.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    enum Phase: Equatable {
        case idle, checking, upToDate, available
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published var available: UpdateCheck.Release?
    @Published var phase: Phase = .idle
    @Published var showSheet = false

    private let skippedKey = "updateSkippedVersion"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// 앱을 열 때 조용히 확인한다(자동 점검 중이거나 MOGO_NO_UPDATE_CHECK=1이면 하지 않는다).
    func checkAutomatically() {
        guard DebugSnapshot.directory == nil,
              ProcessInfo.processInfo.environment["MOGO_NO_UPDATE_CHECK"] != "1" else { return }
        Task { await check(manual: false) }
    }

    /// manual이면 결과(최신, 새 버전, 실패)를 창으로 보여 준다.
    func check(manual: Bool) async {
        guard !isBusy else { return }
        phase = .checking
        do {
            guard let r = try await UpdateCheck.latest(), UpdateCheck.isNewer(r.version, than: currentVersion),
                  r.assets[UpdateCheck.macAssetName] != nil else {
                available = nil
                phase = manual ? .upToDate : .idle
                if manual { showSheet = true }
                return
            }
            if !manual, UserDefaults.standard.string(forKey: skippedKey) == r.version {
                available = nil
                phase = .idle
                return
            }
            available = r
            phase = .available
            if manual { showSheet = true }
        } catch {
            phase = manual ? .failed(error.localizedDescription) : .idle
            if manual { showSheet = true }
        }
    }

    func skip() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: skippedKey) }
        available = nil
        phase = .idle
        showSheet = false
    }

    // MARK: 설치

    /// 지금 앱을 바꿀 수 있는 위치인지(쓰기 권한, 격리 실행·DMG 안 실행이 아님).
    var canReplaceInPlace: Bool {
        let app = Bundle.main.bundleURL
        let parent = app.deletingLastPathComponent().path
        return !app.path.contains("/AppTranslocation/") && !app.path.hasPrefix("/Volumes/")
            && FileManager.default.isWritableFile(atPath: parent)
    }

    func install() async {
        guard let r = available, let url = r.assets[UpdateCheck.macAssetName] else { return }
        guard canReplaceInPlace else {
            NSWorkspace.shared.open(r.page)
            phase = .failed("이 위치에서는 앱을 바꿀 수 없어요. 열린 페이지에서 새 버전을 받아 응용 프로그램 폴더에 넣어 주세요.")
            return
        }
        let app = Bundle.main.bundleURL
        phase = .downloading(0)
        do {
            let dmg = try await download(url, expectedSize: r.sizes[UpdateCheck.macAssetName])
            phase = .installing
            let version = r.version
            let staged = try await Task.detached { try Self.stage(dmg: dmg, nextTo: app, version: version) }.value
            try Self.launchSwapper(app: app, staged: staged)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    enum InstallError: LocalizedError {
        case download(String)
        case verify(String)
        case tool(String)
        var errorDescription: String? {
            switch self {
            case .download(let m): return "새 버전을 받지 못했어요. \(m)"
            case .verify(let m): return "받은 파일을 확인하지 못해 업데이트를 멈췄어요. \(m)"
            case .tool(let m): return "업데이트를 설치하지 못했어요. \(m)"
            }
        }
    }

    /// 받으면서 진행률을 갱신한다. file:// 주소(시험용)는 복사한다.
    private func download(_ url: URL, expectedSize: Int?) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MogoPrint-update-\(UUID().uuidString.prefix(8)).dmg")
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: dest)
            phase = .downloading(1)
            return dest
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("MogoPrint-Updater", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw InstallError.download("HTTP \(http.statusCode)") }
        let total = Double(expectedSize ?? Int(response.expectedContentLength))
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        var buffer = Data(), written = 0
        buffer.reserveCapacity(1 << 18)
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 1 << 18 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { phase = .downloading(min(1, Double(written) / total)) }
            }
        }
        try handle.write(contentsOf: buffer)
        phase = .downloading(1)
        return dest
    }

    /// DMG를 열어 안의 앱을 확인하고, 지금 앱 옆에 숨긴 이름으로 복사해 둔다.
    nonisolated static func stage(dmg: URL, nextTo app: URL, version: String) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("MogoPrint-mount-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
            try? FileManager.default.removeItem(at: mount)
            try? FileManager.default.removeItem(at: dmg)
        }
        let newApp = mount.appendingPathComponent("MogoPrint.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw InstallError.verify("DMG 안에 MogoPrint.app이 없어요.") }
        try verify(newApp, version: version)
        let staged = app.deletingLastPathComponent().appendingPathComponent(".MogoPrint-update-\(version).app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        return staged
    }

    /// 서명이 온전하고, FatTail Labs 팀(Developer ID)이 서명한 모고 프린트이며, 공증을 받았고, 버전이 맞는지 본다.
    nonisolated static func verify(_ app: URL, version: String) throws {
        do { try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) }
        catch { throw InstallError.verify("서명이 온전하지 않아요.") }
        let info = (try? run("/usr/bin/codesign", ["-dv", app.path])) ?? ""
        guard info.contains("TeamIdentifier=\(UpdateCheck.teamID)"), info.contains("Identifier=com.fattaillabs.mogoprint") else {
            throw InstallError.verify("FatTail Labs가 서명한 앱이 아니에요.")
        }
        if ProcessInfo.processInfo.environment["MOGO_UPDATE_ALLOW_UNNOTARIZED"] != "1" {
            do { try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) }
            catch { throw InstallError.verify("애플 공증을 받지 않은 앱이에요.") }
        }
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let v = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? ""
        guard UpdateCheck.compare(v, version) == .orderedSame else { throw InstallError.verify("버전이 맞지 않아요(\(v)).") }
    }

    /// 앱이 끝나기를 기다렸다가 새 앱으로 바꾸고 다시 여는 작은 셸 스크립트를 띄운다.
    nonisolated static func launchSwapper(app: URL, staged: URL) throws {
        let script = """
        #!/bin/sh
        # 모고 프린트 업데이트: 앱이 끝나면 새 앱으로 바꾸고 다시 연다. 바꾸기에 실패하면 원래 앱을 되돌린다.
        pid="$1"; app="$2"; new="$3"
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done
        old="$app.old.$$"
        if mv "$app" "$old"; then
          if mv "$new" "$app"; then rm -rf "$old"; else mv "$old" "$app"; fi
        fi
        open "$app"
        rm -f "$0"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mogoprint-update-\(UUID().uuidString.prefix(8)).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [url.path, String(ProcessInfo.processInfo.processIdentifier), app.path, staged.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    /// 도구를 실행하고 출력(표준 출력+오류)을 돌려준다. 실패하면 오류.
    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw InstallError.tool("\((tool as NSString).lastPathComponent) \(p.terminationStatus)") }
        return out
    }
}

/// 새 버전이 있을 때 화면 아래·첫 화면에 보이는 한 줄.
struct UpdateNotice: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        if let r = updater.available, updater.phase == .available || updater.isBusy {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Text("새 버전 \(r.version)이 나왔어요").font(.callout)
                Button("업데이트…") { updater.showSheet = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }
}

/// 업데이트 창: 새 버전 안내와 바뀐 내용, 받는 중·설치 중 표시, 최신 버전·실패 안내.
struct UpdateSheet: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch updater.phase {
            case .upToDate:
                Text("최신 버전을 쓰고 있어요").font(.title3.bold())
                Text("모고 프린트 \(updater.currentVersion)").foregroundStyle(.secondary)
                HStack { Spacer(); Button("확인") { updater.showSheet = false }.keyboardShortcut(.defaultAction) }
            case .failed(let message):
                Text("업데이트하지 못했어요").font(.title3.bold())
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("릴리스 페이지 열기") { NSWorkspace.shared.open(updater.available?.page ?? UpdateCheck.releasesPage) }
                    Spacer()
                    Button("닫기") { updater.showSheet = false; updater.phase = updater.available == nil ? .idle : .available }
                        .keyboardShortcut(.cancelAction)
                }
            case .checking:
                ProgressView("업데이트를 확인하는 중…").frame(maxWidth: .infinity)
            default:
                if let r = updater.available { availableView(r) }
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    @ViewBuilder
    private func availableView(_ r: UpdateCheck.Release) -> some View {
        Text("새 버전이 나왔어요").font(.title3.bold())
        Text("모고 프린트 \(r.version) · 지금 쓰는 버전은 \(updater.currentVersion)이에요.").foregroundStyle(.secondary)
        ScrollView {
            Text(Self.notes(r.notes))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(height: 220)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        switch updater.phase {
        case .downloading(let p):
            ProgressView(value: p) { Text("받는 중…").font(.callout) }
        case .installing:
            ProgressView { Text("설치하는 중이에요. 잠시 뒤 앱이 다시 열려요.").font(.callout) }
        default:
            EmptyView()
        }
        HStack {
            Button("이 버전 건너뛰기") { updater.skip() }
            Spacer()
            Button("나중에") { updater.showSheet = false }
                .keyboardShortcut(.cancelAction)
            Button("업데이트") { Task { await updater.install() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .disabled(updater.isBusy)
    }

    /// 릴리스 설명(마크다운)을 읽기 좋게: 제목 줄은 굵게, 나머지는 줄 안 서식만.
    static func notes(_ markdown: String) -> AttributedString {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { return "**" + t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**" }
            return String(line)
        }
        let text = lines.joined(separator: "\n")
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
