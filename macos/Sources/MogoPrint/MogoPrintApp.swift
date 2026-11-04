import AppKit
import SwiftUI

@main
struct MogoPrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("모고 프린트", id: "main") {
            ContentView()
                .environmentObject(model)
                // 자동 점검 캡처용 화면 모드(--snapshot-appearance). 평소에는 시스템 설정을 따른다.
                // NSApp.appearance를 바꾸면 SwiftUI 창이 아예 안 만들어져서 화면 쪽에서 정한다.
                .preferredColorScheme(DebugSnapshot.forcedColorScheme)
                .modifier(DebugSnapshot.ActiveLook())
                .frame(minWidth: 960, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("열기…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("인쇄…") { model.showPrintConfirm = true }
                    .keyboardShortcut("p")
                    .disabled(!model.canPrint)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 자동 점검(--snapshot-dir) 중에는 쓰던 앱의 포커스를 뺏지 않는다.
        if !ProcessInfo.processInfo.arguments.contains("--snapshot-dir") {
            NSApp.activate(ignoringOtherApps: true)
        }
        Task { @MainActor in DebugSnapshot.startIfRequested() }
    }

    /// Dock 아이콘에 끌어다 놓거나 Finder에서 "다음으로 열기"로 열 때.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
