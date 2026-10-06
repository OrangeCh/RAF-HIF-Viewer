import Foundation

/// 让菜单栏能反映"还能撤销几步"。
///
/// 菜单是在 App 的 commands 里构建的，拿不到 ContentView 里那个 AppModel 实例，
/// 所以用一个轻量的共享对象把状态传过去。
@MainActor
final class UndoBridge: ObservableObject {
    static let shared = UndoBridge()
    @Published var canUndo = false
    @Published var depth = 0
    private init() {}
}
