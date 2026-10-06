import AppKit
import CoreGraphics
import Foundation
import ImageIO

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


// 离屏渲染验证工具：把真实的 CanvasNSView 画进位图，
// 用于检查适应窗口 / 缩放 / 平移的几何是否正确。

func decode(_ path: String, maxPixel: Int) -> CGImage? {
    ImageStore.decode(URL(fileURLWithPath: path), maxPixel: maxPixel, mode: .rawDecode)
}

func render(view: NSView, size: CGSize, to url: URL) {
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                       styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    win.displayIfNeeded()

    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        print("  !! bitmapImageRepForCachingDisplay 失败"); return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("  !! PNG 编码失败"); return
    }
    try? data.write(to: url)
    print("  -> \(url.lastPathComponent)  \(rep.pixelsWide)x\(rep.pixelsHigh)  \(data.count/1024) KB")
}

@main
struct Harness {
    static func main() {
        let dir = testLibraryDir().path
        let stem = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DSCF0001"
        let outDir = URL(fileURLWithPath: "/tmp/shots")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        print("解码 \(stem) ...")
        guard let raf = decode("\(dir)/\(stem).RAF", maxPixel: 2048) else {
            print("RAF 解码失败"); exit(1)
        }
        guard let hif = decode("\(dir)/\(stem).HIF", maxPixel: 2048) else {
            print("HIF 解码失败"); exit(1)
        }
        print("  RAF \(raf.width)x\(raf.height)   HIF \(hif.width)x\(hif.height)")

        let size = CGSize(width: 900, height: 600)

        // 1) 适应窗口
        let v1 = CanvasNSView(frame: NSRect(origin: .zero, size: size))
        v1.imageA = raf; v1.imageB = hif; v1.showB = true; v1.blend = 1
        v1.zoom = 1
        render(view: v1, size: size, to: outDir.appendingPathComponent("canvas_fit.png"))

        // 2) 放大 4 倍，居中
        let v2 = CanvasNSView(frame: NSRect(origin: .zero, size: size))
        v2.imageA = raf
        v2.zoom = 4
        render(view: v2, size: size, to: outDir.appendingPathComponent("canvas_zoom4.png"))

        // 3) 放大 4 倍 + 平移
        let v3 = CanvasNSView(frame: NSRect(origin: .zero, size: size))
        v3.imageA = raf
        v3.zoom = 4
        v3.pan = CGSize(width: 260, height: -150)
        render(view: v3, size: size, to: outDir.appendingPathComponent("canvas_zoom4_pan.png"))

        // 4) 叠加一半 RAF 一半 HIF（闪烁模式）
        let v4 = CanvasNSView(frame: NSRect(origin: .zero, size: size))
        v4.imageA = raf; v4.imageB = hif; v4.showB = true; v4.blend = 0.5
        v4.zoom = 1
        render(view: v4, size: size, to: outDir.appendingPathComponent("canvas_blend50.png"))

        // 5) 差异图
        if let diff = ImageStore.shared.difference(raf, hif) {
            let st = stats(diff)
            print(String(format: "  差异图统计: 平均 %.1f  最大 %d  非零像素 %.1f%%",
                         st.mean, st.maxv, st.nonzeroPct))
            let v5 = CanvasNSView(frame: NSRect(origin: .zero, size: size))
            v5.imageA = diff
            v5.zoom = 1
            render(view: v5, size: size, to: outDir.appendingPathComponent("canvas_diff.png"))
        } else {
            print("  !! 差异图生成失败 (CIDifferenceBlendMode 可能不可用)")
        }

        print("完成")
    }

    /// 统计灰度均值/最大值/非零比例，用于判断差异图是否真的画出来了
    static func stats(_ img: CGImage) -> (mean: Double, maxv: Int, nonzeroPct: Double) {
        let w = min(img.width, 800), h = min(img.height, 533)
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { p in
            if let ctx = CGContext(data: p.baseAddress, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var s = 0, mx = 0, nz = 0
        for v in buf { let i = Int(v); s += i; mx = max(mx, i); if i > 2 { nz += 1 } }
        return (Double(s) / Double(buf.count), mx, Double(nz) * 100 / Double(buf.count))
    }
}
