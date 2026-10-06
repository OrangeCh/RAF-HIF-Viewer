import Foundation
import AppKit

// 端到端验证 AppModel 的删除/撤销流程。用临时图库，不碰真实照片。
@main
struct E2ETest {
    static var failures = 0

    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !ok { failures += 1 }
    }

    static func main() async {
        await MainActor.run { runAll() }
        print("\n" + String(repeating: "─", count: 52))
        print(failures == 0 ? "✅ 端到端全部通过" : "❌ 有 \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    static func runAll() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/e2e-lib")
        try? fm.removeItem(at: root)

        // 造一个仿真的图库：一个只有 1 张的文件夹，一个 3 张的文件夹
        func makePair(_ day: String, _ stem: String) {
            let d = root.appendingPathComponent(day)
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            try? Data(repeating: 0x11, count: 32).write(to: d.appendingPathComponent("\(stem).RAF"))
            try? Data(repeating: 0x22, count: 32).write(to: d.appendingPathComponent("\(stem).HIF"))
        }
        makePair("2026-01-01", "DSCF0001")
        makePair("2026-01-02", "DSCF0002")
        makePair("2026-01-02", "DSCF0003")
        makePair("2026-01-02", "DSCF0004")

        let model = AppModel()
        model.openRoot(root)

        print("\n═══ 1. 初始状态 ═══")
        check(model.groups.count == 2, "识别到 2 个日期文件夹", "\(model.groups.map(\.name))")
        check(model.currentPairs.count == 1, "首个文件夹有 1 张")
        check(model.groupPairCount("2026-01-02") == 3, "第 2 个文件夹有 3 张")

        print("\n═══ 2. 删除后自动前进到下一张 ═══")
        model.selectGroup("2026-01-02")
        model.selectPair("2026-01-02/DSCF0002")          // 选中间那张
        check(model.currentPair?.stem == "DSCF0002", "已选中中间那张", model.currentPair?.stem ?? "-")

        model.performTrash()

        let d2 = root.appendingPathComponent("2026-01-02")
        check(!fm.fileExists(atPath: d2.appendingPathComponent("DSCF0002.RAF").path)
              && !fm.fileExists(atPath: d2.appendingPathComponent("DSCF0002.HIF").path),
              "RAF 与 HIF 两个文件都已移出")
        check(model.groupPairCount("2026-01-02") == 2, "列表里该文件夹剩 2 张")
        check(model.currentPair?.stem == "DSCF0003",
              "自动前进到下一张 DSCF0003", model.currentPair?.stem ?? "-")
        check(model.canUndoTrash, "记录了可撤销的操作")
        check(model.trashDepth == 1, "撤销栈深度为 1")
        check(model.toast != nil, "显示了提示", model.toast ?? "")

        print("\n═══ 3. 撤销恢复 ═══")
        model.undoTrash()
        check(fm.fileExists(atPath: d2.appendingPathComponent("DSCF0002.RAF").path)
              && fm.fileExists(atPath: d2.appendingPathComponent("DSCF0002.HIF").path),
              "两个文件都已回到原位")
        check(model.groupPairCount("2026-01-02") == 3, "列表恢复为 3 张")
        check(model.currentPair?.stem == "DSCF0002",
              "选中状态回到被删的那张", model.currentPair?.stem ?? "-")

        print("\n═══ 4. 删掉文件夹里最后一张（整个文件夹应消失） ═══")
        model.selectGroup("2026-01-01")
        model.selectPair("2026-01-01/DSCF0001")
        model.performTrash()
        check(model.groups.count == 1, "空的日期文件夹已从列表移除",
              "\(model.groups.map(\.name))")
        check(model.selectedGroup == "2026-01-02", "自动切到还有照片的文件夹",
              model.selectedGroup ?? "-")

        print("\n═══ 5. 撤销把整个文件夹带回来 ═══")
        model.undoTrash()
        check(model.groups.count == 2, "日期文件夹已重新出现", "\(model.groups.map(\.name))")
        check(fm.fileExists(atPath: root.appendingPathComponent("2026-01-01/DSCF0001.RAF").path),
              "文件已回到原位")

        print("\n═══ 6. 多级撤销：连删 3 张，再连按 ⌘Z 逐级退回 ═══")
        model.confirmBeforeTrash = false
        model.selectGroup("2026-01-02")
        let stems = ["DSCF0002", "DSCF0003", "DSCF0004"]
        for s in stems {
            model.selectPair("2026-01-02/\(s)")
            model.performTrash()
        }
        check(model.trashDepth == 3, "连删 3 张后撤销栈深度为 3", "\(model.trashDepth)")
        check(model.groupPairCount("2026-01-02") == 0, "该文件夹已空")
        check(!model.groups.contains { $0.name == "2026-01-02" }, "空文件夹已移出列表")

        // 逐级撤销，每次应恢复最近删掉的那张
        for (i, expected) in stems.reversed().enumerated() {
            model.undoTrash()
            let back = fm.fileExists(atPath: root.appendingPathComponent("2026-01-02/\(expected).RAF").path)
            check(back, "第 \(i + 1) 次撤销恢复了 \(expected)", back ? "" : "文件没回来")
            check(model.trashDepth == 2 - i, "撤销栈剩余 \(2 - i) 步", "实际 \(model.trashDepth)")
        }
        check(model.groupPairCount("2026-01-02") == 3, "3 张全部回到列表")
        check(!model.canUndoTrash, "栈已清空，无可撤销")

        print("\n═══ 7. 栈空后再按 ⌘Z 应当无动作 ═══")
        model.undoTrash()
        check(model.groupPairCount("2026-01-02") == 3, "文件数量不变，未发生异常")

        print("\n═══ 8. 右键菜单：删除的是被点的那一张，不是当前选中的 ═══")
        model.confirmBeforeTrash = false
        model.selectGroup("2026-01-02")
        model.selectPair("2026-01-02/DSCF0002")           // 选中 DSCF0002
        check(model.currentPair?.stem == "DSCF0002", "当前选中 DSCF0002")

        // 对另一张（DSCF0004）发起删除
        let target = model.currentPairs.first { $0.stem == "DSCF0004" }!
        model.requestTrash(target)
        check(!fm.fileExists(atPath: d2.appendingPathComponent("DSCF0004.RAF").path),
              "被点的 DSCF0004 已移入废纸篓")
        check(fm.fileExists(atPath: d2.appendingPathComponent("DSCF0002.RAF").path),
              "当前选中的 DSCF0002 未受影响")
        check(model.groupPairCount("2026-01-02") == 2, "列表剩 2 张")
        check(model.lastTrashStem == "DSCF0004", "撤销记录指向 DSCF0004",
              model.lastTrashStem ?? "-")

        model.undoTrash()
        check(fm.fileExists(atPath: d2.appendingPathComponent("DSCF0004.RAF").path),
              "撤销后 DSCF0004 回来了")
        check(model.groupPairCount("2026-01-02") == 3, "列表恢复 3 张")

        print("\n═══ 9. 右键菜单删除 + 开启确认时不直接删 ═══")
        model.confirmBeforeTrash = true
        let t2 = model.currentPairs.first { $0.stem == "DSCF0003" }!
        model.requestTrash(t2)
        check(model.pendingTrashPair?.stem == "DSCF0003",
              "待确认项是 DSCF0003", model.pendingTrashPair?.stem ?? "nil")
        check(fm.fileExists(atPath: d2.appendingPathComponent("DSCF0003.RAF").path),
              "等待确认期间文件仍在")
        model.performTrash(t2)
        check(!fm.fileExists(atPath: d2.appendingPathComponent("DSCF0003.RAF").path),
              "确认后才真正删除")
        check(model.pendingTrashPair == nil, "待确认状态已清空")
        model.undoTrash()
        model.confirmBeforeTrash = false

        print("\n═══ 10. 取消确认开关不会误删 ═══")
        model.confirmBeforeTrash = true
        model.selectGroup("2026-01-02")
        model.selectPair("2026-01-02/DSCF0002")
        model.requestTrash()
        check(model.pendingTrashPair != nil, "弹出确认框而非直接删除",
              model.pendingTrashPair?.stem ?? "nil")
        check(fm.fileExists(atPath: root.appendingPathComponent("2026-01-02/DSCF0002.RAF").path),
              "等待确认期间文件仍在")

        print("\n═══ 11. 清理 ═══")
        // 把测试期间产生的删除记录都还原，避免污染废纸篓
        model.confirmBeforeTrash = false
        model.pendingTrashPair = nil
        while model.canUndoTrash { model.undoTrash() }
        try? fm.removeItem(at: root)
        check(!fm.fileExists(atPath: root.path), "临时图库已删除")
    }
}

extension AppModel {
    func groupPairCount(_ name: String) -> Int {
        groups.first { $0.name == name }?.pairs.count ?? 0
    }
    var lastTrashStem: String? { trashHistory.last?.pairStem }
}
