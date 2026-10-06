import SwiftUI
import AppKit

@main
struct RAFHIFViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var undo = UndoBridge.shared
    @ObservedObject private var scroll = ScrollSettings.shared

    var body: some Scene {
        WindowGroup("RAF-HIF 对照查看器") {
            ContentView()
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开照片文件夹…") {
                    NotificationCenter.default.post(name: .openFolderRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // 撤销：可连按，逐级回退每一次删除
            CommandGroup(replacing: .undoRedo) {
                Button(undo.depth > 1
                       ? L.f("撤销移入废纸篓（还有 %d 步）", undo.depth)
                       : L.t("撤销移入废纸篓")) {
                    NotificationCenter.default.post(name: .undoTrashRequested, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!undo.canUndo)
            }

            // 滚轮翻页灵敏度。不同鼠标上报的滚动增量差别很大，
            // 与其替用户猜，不如给个开关。
            CommandGroup(after: .toolbar) {
                Picker("滚轮翻页灵敏度", selection: $scroll.sensitivity) {
                    Text("慢").tag(0)
                    Text("标准").tag(1)
                    Text("快").tag(2)
                    Text("最快").tag(3)
                }
            }

            // 删除：同时处理 RAF 与 HIF
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("移入废纸篓") {
                    NotificationCenter.default.post(name: .trashRequested, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
