import Foundation
import AppKit

/// 测试用的图库目录。用环境变量 `RAFHIF_TEST_DIR` 指定，**不写死路径** ——
/// 免得把开发者本机的目录结构带进公开仓库。
func testLibraryDir() -> URL {
    let env = ProcessInfo.processInfo.environment["RAFHIF_TEST_DIR"]
    guard let p = env, !p.isEmpty else {
        FileHandle.standardError.write(
            "请先设置环境变量 RAFHIF_TEST_DIR 指向含有 RAF/HIF 文件的目录\n"
                .data(using: .utf8)!)
        exit(1)
    }
    return URL(fileURLWithPath: p)
}


// 验证默认值，以及"按模式只解码需要的一侧"这个优化是否真的生效。
// 用软链接指向卡上的真实文件，避免复制 85 MB。
//
// 注意：必须跑在真实的主 run loop 里（NSApplication.run）。
// ImageStore 的回调走 DispatchQueue.main.async，Swift 并发任务在主 actor 上也走主队列，
// 而 RunLoop.run(mode:before:) 并不会 drain 主队列 —— 手动泵 run loop 会永远等不到结果。
@main
struct DefaultsTest {
    static var failures = 0

    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !ok { failures += 1 }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        Task { @MainActor in
            await runAll()
            print("\n" + String(repeating: "─", count: 52))
            print(failures == 0 ? "✅ 全部通过" : "❌ 有 \(failures) 项失败")
            exit(failures == 0 ? 0 : 1)
        }
        app.run()   // 真正的主 run loop
    }

    @MainActor
    static func runAll() async {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/defaults-lib")
        try? fm.removeItem(at: root)
        let day = root.appendingPathComponent("2026-09-29")
        try! fm.createDirectory(at: day, withIntermediateDirectories: true)

        let src = testLibraryDir()
        let stem = ProcessInfo.processInfo.environment["RAFHIF_TEST_STEM"] ?? "DSCF0001"
        for n in ["\(stem).RAF", "\(stem).HIF"] {
            try! fm.createSymbolicLink(at: day.appendingPathComponent(n),
                                       withDestinationURL: src.appendingPathComponent(n))
        }

        let model = AppModel()

        print("\n═══ 1. 默认值 ═══")
        check(model.mode == .solo, "默认视图模式 = 单图", model.mode.rawValue)
        check(model.soloSide == .hif, "单图默认显示 HIF", model.soloSide.rawValue)
        check(model.decodeMode == .rawDecode, "读取方式仍是「解码 RAW」", model.decodeMode.rawValue)

        print("\n═══ 2. 单图 + HIF：只解码 HIF，不解 RAF ═══")
        model.openRoot(root)
        check(model.currentPairs.count == 1, "找到 1 组配对", "\(model.currentPairs.count)")

        await model.loadImages()
        check(model.imageA == nil, "未加载 RAF（imageA 为空）")
        check(model.imageB != nil, "已加载 HIF（imageB 有图）",
              model.imageB.map { "\($0.width)x\($0.height)" } ?? "nil")

        print("\n═══ 3. 切到 RAF 侧：这时才去解 RAW ═══")
        model.soloSide = .raf
        await model.loadImages()
        check(model.imageA != nil, "已加载 RAF",
              model.imageA.map { "\($0.width)x\($0.height)" } ?? "nil")
        check(model.imageB == nil, "此时未加载 HIF")

        print("\n═══ 4. 切到对照模式：两侧都要 ═══")
        model.mode = .compare
        await model.loadImages()
        check(model.imageA != nil && model.imageB != nil, "RAF 与 HIF 都已加载")

        print("\n═══ 5. 切回单图 HIF：应命中缓存 ═══")
        model.mode = .solo
        model.soloSide = .hif
        let t0 = CFAbsoluteTimeGetCurrent()
        await model.loadImages()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        check(model.imageB != nil, "HIF 已就绪")
        check(ms < 80, "从缓存返回，耗时很短", String(format: "%.0f ms", ms))

        print("\n═══ 6. 模式来回切换后仍记得所选的一侧 ═══")
        model.mode = .compare
        model.mode = .solo
        check(model.soloSide == .hif, "仍记得选的是 HIF", model.soloSide.rawValue)

        print("\n═══ 7. 单图显示 HIF 时，读取方式只影响 RAW ═══")
        let w0 = model.imageB?.width
        model.decodeMode = .embedded
        await model.loadImages()
        check(model.imageB?.width == w0, "HIF 画面一致",
              "\(w0 ?? -1) → \(model.imageB?.width ?? -1)")

        try? fm.removeItem(at: root)
    }
}
