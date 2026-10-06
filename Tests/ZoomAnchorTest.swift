import AppKit
import Foundation

// 验证 Ctrl+滚轮缩放的光标锚点是否正确，以及缩放上下限、缩小时平移归零等边界。
@main
struct ZoomAnchorTest {
    static var failures = 0
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        print("  \(ok ? "✅" : "❌") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !ok { failures += 1 }
    }

    /// 反推：给定 zoom/pan，锚点处对应的图像坐标
    static func imagePoint(at anchor: CGPoint, zoom: CGFloat, pan: CGSize,
                           viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        let fit = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let ds = fit * zoom
        let lx = (viewSize.width - imageSize.width * ds) / 2 + pan.width
        let ly = (viewSize.height - imageSize.height * ds) / 2 - pan.height
        return CGPoint(x: (anchor.x - lx) / ds, y: (anchor.y - ly) / ds)
    }

    static func main() {
        let view = CGSize(width: 900, height: 600)
        let image = CGSize(width: 7728, height: 5152)      // X-T5 的真实尺寸
        let anchors: [CGPoint] = [
            CGPoint(x: 450, y: 300),    // 正中
            CGPoint(x: 120, y: 500),    // 左下
            CGPoint(x: 860, y: 90),     // 右上
            CGPoint(x: 300, y: 300),    // 偏左
            CGPoint(x: 700, y: 420),    // 偏右下
        ]
        let zooms: [(CGFloat, CGFloat)] = [(1, 1.4), (1, 2.5), (2.5, 1.2), (4, 7), (3.7, 3.71)]

        print("\n═══ 1. 缩放前后，光标下的图像点应停在原处 ═══")
        var worst = 0.0
        for a in anchors {
            for (z1, z2) in zooms {
                // 先随便给一个非零平移，模拟已经拖动过
                let pan0 = CGSize(width: 30, height: -20)
                let before = imagePoint(at: a, zoom: z1, pan: pan0, viewSize: view, imageSize: image)
                let pan1 = CanvasNSView.anchoredPan(currentZoom: z1, newZoom: z2,
                                                    currentPan: pan0, anchor: a,
                                                    viewSize: view, imageSize: image)
                let after = imagePoint(at: a, zoom: z2, pan: pan1, viewSize: view, imageSize: image)
                let err = max(abs(before.x - after.x), abs(before.y - after.y))
                worst = max(worst, err)
            }
        }
        check(worst < 0.01, "全部 \(anchors.count * zooms.count) 种组合锚点误差 < 0.01 图像像素",
              String(format: "最大误差 %.4f px", worst))

        print("\n═══ 2. 从适应窗口(zoom=1, pan=0)开始也准 ═══")
        var worst2 = 0.0
        for a in anchors {
            let before = imagePoint(at: a, zoom: 1, pan: .zero, viewSize: view, imageSize: image)
            let pan1 = CanvasNSView.anchoredPan(currentZoom: 1, newZoom: 3,
                                                currentPan: .zero, anchor: a,
                                                viewSize: view, imageSize: image)
            let after = imagePoint(at: a, zoom: 3, pan: pan1, viewSize: view, imageSize: image)
            worst2 = max(worst2, max(abs(before.x - after.x), abs(before.y - after.y)))
        }
        check(worst2 < 0.01, "误差 < 0.01 图像像素", String(format: "最大误差 %.4f px", worst2))

        print("\n═══ 3. 缩放中心在锚点，不是画面中心 ═══")
        let aL = CGPoint(x: 100, y: 300), aR = CGPoint(x: 800, y: 300)
        let pL = CanvasNSView.anchoredPan(currentZoom: 1, newZoom: 3, currentPan: .zero,
                                          anchor: aL, viewSize: view, imageSize: image)
        let pR = CanvasNSView.anchoredPan(currentZoom: 1, newZoom: 3, currentPan: .zero,
                                          anchor: aR, viewSize: view, imageSize: image)
        check(abs(pL.width - pR.width) > 200, "左右两侧锚点得到明显不同的平移量",
              String(format: "左 %.0f vs 右 %.0f", pL.width, pR.width))

        print("\n═══ 4. 边界情况 ═══")
        let zero = CanvasNSView.anchoredPan(currentZoom: 1, newZoom: 2, currentPan: .zero,
                                            anchor: CGPoint(x: 10, y: 10),
                                            viewSize: .zero, imageSize: image)
        check(zero == .zero, "画布尺寸为 0 时原样返回，不产生 NaN", "\(zero)")

        let nan = CanvasNSView.anchoredPan(currentZoom: 1, newZoom: 2, currentPan: .zero,
                                           anchor: .zero,
                                           viewSize: view, imageSize: .zero)
        check(nan == .zero, "图像尺寸为 0 时原样返回，不产生 NaN")

        print("\n" + String(repeating: "─", count: 52))
        print(failures == 0 ? "✅ 全部通过" : "❌ 有 \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
