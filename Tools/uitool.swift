// 开发期用的 UI 调试小工具（辅助功能权限已授予时可用）
//   uitool click   <pid> <x> <y>   左键点击
//   uitool rclick  <pid> <x> <y>   右键点击
//   uitool scroll  <pid> <x> <y> <n> <dy>   发 n 次滚轮，每次增量 dy
//   uitool key     <pid> <keycode>          发一次按键
import AppKit
import CoreGraphics

let a = CommandLine.arguments
guard a.count >= 4 else {
    print("usage: uitool <click|rclick|scroll|key> <pid> ..."); exit(1)
}
let cmd = a[1]
guard let pid = Int32(a[2]) else {
    print("usage: uitool <click|rclick|scroll|key> <pid> ..."); exit(1)
}
if let app = NSRunningApplication(processIdentifier: pid) {
    app.activate(options: [.activateAllWindows])
}
usleep(600_000)

switch cmd {
case "click", "rclick":
    let pt = CGPoint(x: Double(a[3])!, y: Double(a[4])!)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(300_000)
    let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) =
        cmd == "click" ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
    CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: pt, mouseButton: btn)?.post(tap: .cghidEventTap)
    usleep(90_000)
    CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: pt, mouseButton: btn)?.post(tap: .cghidEventTap)
    print("\(cmd) at \(pt.x),\(pt.y)")
case "scroll":
    let pt = CGPoint(x: Double(a[3])!, y: Double(a[4])!)
    let n = Int(a[5])!, dy = Int32(a[6])!
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(300_000)
    for _ in 0..<n {
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                           wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) {
            e.location = pt; e.post(tap: .cghidEventTap)
        }
        usleep(150_000)
    }
    print("scroll \(n)x dy=\(dy)")
case "key":
    let code = CGKeyCode(UInt16(a[3])!)
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(50_000)
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    print("key \(code)")
default:
    print("unknown: \(cmd)")
}
