import Foundation

/// 本地化入口。
///
/// 采用「**中文原文即 key**」的方式：源码里直接写中文，`.strings` 表里给出各语言译文。
/// 这样有两个好处：
/// 1. `Text("对照")` / `Label("差异", …)` 这类接受 `LocalizedStringKey` 的地方**不用改代码**，
///    SwiftUI 会自动查表；
/// 2. 万一某条漏翻，会回落到 key 本身（也就是中文原文），不会显示出丑陋的键名。
///
/// 需要显式调用的只有三类：`String` 上下文（不是 `LocalizedStringKey`）、
/// 带插值的文案、以及赋值给字典/模型的字符串。
enum L {

    /// 取译文
    static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    /// 带参数的译文，格式串写在 `.strings` 里（例：`"%d 张"`）
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }

    /// 当前生效的界面语言，例如 `zh-Hans` / `en`
    static var current: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    static var isChinese: Bool { current.hasPrefix("zh") }
}
