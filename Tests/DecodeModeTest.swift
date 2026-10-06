import Foundation
import ImageIO
import CoreGraphics
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


// 诊断：两种读取模式在各文件类型下的实际表现
@main
struct DecodeModeTest {
    static func main() {
        let dir = testLibraryDir().path
        // 默认取第一张；也可以命令行传文件名
        let files = CommandLine.arguments.count > 1
            ? Array(CommandLine.arguments.dropFirst())
            : ["DSCF0001"]

        print(String(format: "%-12@ %-10@ %-14@ %-10@ %-10@ %-9@ %s",
                     "文件" as NSString, "模式" as NSString, "尺寸" as NSString,
                     "均值" as NSString, "最大值" as NSString, "纯黑?" as NSString, "说明" as NSString))
        print(String(repeating: "─", count: 92))

        for stem in files {
            for ext in ["RAF", "HIF"] {
                let url = URL(fileURLWithPath: "\(dir)/\(stem).\(ext)")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                for mode in DecodeMode.allCases {
                    guard let img = ImageStore.decode(url, maxPixel: 2048, mode: mode) else {
                        print(String(format: "%-12@ %-10@ %@", "\(stem).\(ext)" as NSString,
                                     mode.rawValue as NSString, "解码失败" as NSString))
                        continue
                    }
                    let st = stats(img)
                    let alpha: String
                    switch img.alphaInfo {
                    case .none, .noneSkipLast, .noneSkipFirst: alpha = "无alpha"
                    case .premultipliedLast, .premultipliedFirst: alpha = "预乘alpha"
                    case .last, .first: alpha = "有alpha"
                    case .alphaOnly: alpha = "仅alpha"
                    @unknown default: alpha = "?"
                    }
                    let black = st.mean < 1.0
                    print(String(format: "%-12@ %-10@ %-14@ %-10@ %-10@ %-9@ %@",
                                 "\(stem).\(ext)" as NSString, mode.rawValue as NSString,
                                 "\(img.width)x\(img.height)" as NSString,
                                 String(format: "%.1f", st.mean) as NSString,
                                 "\(st.maxv)" as NSString,
                                 (black ? "是 ⚠️" : "否") as NSString,
                                 alpha as NSString))
                }
            }
        }
    }

    static func stats(_ img: CGImage) -> (mean: Double, maxv: Int) {
        let w = min(img.width, 400), h = min(img.height, 267)
        var buf = [UInt8](repeating: 0, count: w * h)
        // 先铺一层洋红，这样如果图像是透明的，就能看出来
        buf.withUnsafeMutableBytes { p in
            if let ctx = CGContext(data: p.baseAddress, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var s = 0, mx = 0
        for v in buf { s += Int(v); mx = max(mx, Int(v)) }
        return (Double(s) / Double(buf.count), mx)
    }
}
