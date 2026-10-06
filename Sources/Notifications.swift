import Foundation

// 菜单命令与界面之间的通信通道。
// 单独成文件，这样测试目标也能引用，而不必把带 @main 的 App.swift 拉进来。
extension Notification.Name {
    static let openFolderRequested = Notification.Name("openFolderRequested")
    static let undoTrashRequested  = Notification.Name("undoTrashRequested")
    static let trashRequested      = Notification.Name("trashRequested")
}
