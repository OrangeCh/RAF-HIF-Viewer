import Foundation
import CoreGraphics

/// 滚轮翻页的灵敏度。
///
/// 为什么做成可调：不同鼠标/触控板上报的滚动增量差别极大 ——
/// 传统滚轮一格是一个事件且 `hasPreciseScrollingDeltas == false`；
/// 而带平滑滚动的鼠标（如苹果鼠标、部分逻辑鼠标）会像触控板那样
/// 上报一连串小增量。同一个阈值不可能对两者都合适，
/// 与其猜，不如给用户一个开关。
@MainActor
final class ScrollSettings: ObservableObject {
    static let shared = ScrollSettings()

    /// 0 慢 / 1 标准 / 2 快 / 3 最快
    @Published var sensitivity: Int {
        didSet { UserDefaults.standard.set(sensitivity, forKey: Self.key) }
    }

    private static let key = "scrollPageSensitivity"

    private init() {
        let v = UserDefaults.standard.object(forKey: Self.key) as? Int
        // 默认「标准」。这个值是实测定下来的：曾因为把滚轮事件误判成
        // 触控板而把阈值调到 9（快），后来查明那是 Mos 的"模拟触控板"
        // 在改写事件，关掉之后标准档就合适了。
        sensitivity = v ?? 1
    }

    /// 触发一次翻页所需的累计滚动量（点）。只对「精确增量」设备生效；
    /// 传统滚轮一格就是一个事件，不受这个值影响。
    var stepThreshold: CGFloat {
        switch sensitivity {
        case 0:  return 40
        case 1:  return 20
        case 3:  return 4
        default: return 9        // 2 = 快（默认）
        }
    }
}
