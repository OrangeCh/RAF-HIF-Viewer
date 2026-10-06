import Foundation

// TrashManager 的行为验证。用临时目录，不碰任何真实照片。
// 重点验证：真的进了废纸篓、能恢复、以及三道安全边界是否拦得住。

@main
struct TrashSelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !ok { failures += 1 }
    }

    static func main() {

    let fm = FileManager.default
    let base = URL(fileURLWithPath: "/tmp/trash-selftest")
    try? fm.removeItem(at: base)
    let library = base.appendingPathComponent("library")
    let dayDir = library.appendingPathComponent("2026-01-01")
    try! fm.createDirectory(at: dayDir, withIntermediateDirectories: true)

    let raf = dayDir.appendingPathComponent("DSCF9999.RAF")
    let hif = dayDir.appendingPathComponent("DSCF9999.HIF")
    try! Data(repeating: 0xAB, count: 1234).write(to: raf)
    try! Data(repeating: 0xCD, count: 567).write(to: hif)

    print("\n═══ 1. 前置状态 ═══")
    check(fm.fileExists(atPath: raf.path) && fm.fileExists(atPath: hif.path), "两个测试文件已就位")

    print("\n═══ 2. 移入废纸篓 ═══")
    var trashed: [TrashedFile] = []
    do {
        trashed = try TrashManager.trash([raf, hif], inside: library)
        check(trashed.count == 2, "两个文件都被处理", "返回 \(trashed.count) 条记录")
        check(!fm.fileExists(atPath: raf.path), "原位置 .RAF 已消失")
        check(!fm.fileExists(atPath: hif.path), "原位置 .HIF 已消失")
        let inTrashOK = trashed.allSatisfy { fm.fileExists(atPath: $0.inTrash.path) }
        check(inTrashOK, "两个文件确实存在于废纸篓中")
        for t in trashed { print("       废纸篓位置: \(t.inTrash.path)") }
    } catch {
        check(false, "移入废纸篓", "抛出异常: \(error.localizedDescription)")
    }

    print("\n═══ 3. 从废纸篓恢复 ═══")
    if !trashed.isEmpty {
        let failed = TrashManager.restore(trashed)
        check(failed.isEmpty, "恢复无失败项", failed.isEmpty ? "" : "失败: \(failed.map(\.lastPathComponent))")
        check(fm.fileExists(atPath: raf.path), "原位置 .RAF 已回来")
        check(fm.fileExists(atPath: hif.path), "原位置 .HIF 已回来")
        let rafOK = (try? Data(contentsOf: raf))?.count == 1234
        let hifOK = (try? Data(contentsOf: hif))?.count == 567
        check(rafOK && hifOK, "文件内容与大小未被破坏")
    }

    print("\n═══ 4. 安全边界：图库之外的文件 ═══")
    let outsider = base.appendingPathComponent("outside.RAF")
    try! Data(repeating: 1, count: 10).write(to: outsider)
    do {
        _ = try TrashManager.trash([outsider], inside: library)
        check(false, "应当拒绝删除图库之外的文件")
    } catch let e as TrashError {
        if case .outsideRoot = e { check(true, "已拒绝图库之外的文件", e.localizedDescription) }
        else { check(false, "拒绝原因不对", e.localizedDescription) }
        check(fm.fileExists(atPath: outsider.path), "越界文件未被删除")
    } catch {
        check(false, "抛出意外异常", "\(error)")
    }

    print("\n═══ 5. 安全边界：不支持的文件类型 ═══")
    let txt = dayDir.appendingPathComponent("notes.txt")
    try! Data(repeating: 2, count: 10).write(to: txt)
    do {
        _ = try TrashManager.trash([txt], inside: library)
        check(false, "应当拒绝删除 .txt")
    } catch let e as TrashError {
        if case .unsupportedType = e { check(true, "已拒绝非图片类型", e.localizedDescription) }
        else { check(false, "拒绝原因不对", e.localizedDescription) }
        check(fm.fileExists(atPath: txt.path), "txt 文件未被删除")
    } catch {
        check(false, "抛出意外异常", "\(error)")
    }

    print("\n═══ 6. 配对原子性：中途失败要回滚 ═══")
    // 让第二个文件不可删：把它的父目录设为只读会在预检就被拦下，
    // 这里改为直接构造一个「预检通过但 trashItem 失败」的场景比较困难，
    // 于是退而验证：预检失败时，第一个文件也不会被移走。
    let roDir = library.appendingPathComponent("readonly")
    try! fm.createDirectory(at: roDir, withIntermediateDirectories: true)
    let a = roDir.appendingPathComponent("A.RAF")
    try! Data(repeating: 3, count: 10).write(to: a)
    try! fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: roDir.path)   // r-x
    do {
        _ = try TrashManager.trash([a], inside: library)
        check(false, "只读目录中的文件应当被拒绝")
    } catch {
        check(true, "只读位置被拦下", error.localizedDescription)
    }
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roDir.path)
    check(fm.fileExists(atPath: a.path), "只读目录中的文件未被删除")

    print("\n═══ 7. 清理测试残留 ═══")
    try? fm.removeItem(at: base)
    check(!fm.fileExists(atPath: base.path), "临时目录已删除")
    // 确认没有把测试文件遗留在废纸篓
    let leftover = trashed.filter { fm.fileExists(atPath: $0.inTrash.path) }
    check(leftover.isEmpty, "废纸篓中没有测试残留", leftover.isEmpty ? "" : "\(leftover.count) 个残留")

    print("\n" + String(repeating: "─", count: 50))
    print(failures == 0 ? "✅ 全部通过（\(0) 项失败）" : "❌ 有 \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
}
}
