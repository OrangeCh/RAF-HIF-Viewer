// 查看剪贴板内容： Tools/clipboard.swift [clear]
import AppKit
let pb = NSPasteboard.general
if CommandLine.arguments.contains("clear") {
    pb.clearContents(); print("剪贴板已清空"); exit(0)
}
print("  可用类型: \(pb.types?.map { $0.rawValue } ?? [])")
if let d = pb.data(forType: .png) {
    print("  ✅ PNG: \(d.count / 1024) KB", terminator: "")
    if let img = NSImage(data: d) { print("  尺寸 \(Int(img.size.width))×\(Int(img.size.height))") }
    else { print("  (无法解析)") }
} else {
    print("  ❌ 没有 PNG 数据")
}
