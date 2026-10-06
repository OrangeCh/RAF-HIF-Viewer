// 按标题查找 AX 元素并执行 press（用于点菜单项）
//   axpress <pid> <title>
import ApplicationServices
import Foundation

func attr(_ el: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ n: String) -> String { (attr(el, n) as? String) ?? "" }

var target: AXUIElement?
func walk(_ el: AXUIElement, _ d: Int, _ want: String) {
    guard d < 14, target == nil else { return }
    let role = str(el, kAXRoleAttribute)
    if role == "AXMenuItem", str(el, kAXTitleAttribute) == want {
        target = el; return
    }
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for k in kids { walk(k, d + 1, want) }
    }
}
let pid = Int32(CommandLine.arguments[1])!
let want = CommandLine.arguments[2]
walk(AXUIElementCreateApplication(pid), 0, want)
if let t = target {
    let err = AXUIElementPerformAction(t, kAXPressAction as CFString)
    print("press \"\(want)\" → \(err == .success ? "成功" : "失败 code=\(err.rawValue)")")
} else {
    print("找不到菜单项 \"\(want)\"（菜单可能没打开）")
}
