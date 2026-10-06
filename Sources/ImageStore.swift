import Foundation
import ImageIO
import CoreGraphics
import CoreImage
import AppKit
import UniformTypeIdentifiers

/// 解码策略。注意这只影响 RAW 一侧。
enum DecodeMode: String, CaseIterable, Identifiable {
    case rawDecode = "解码 RAW"
    case embedded  = "内嵌预览"
    var id: String { rawValue }
    /// rawValue 只作稳定标识（同时充当本地化 key），显示一律用 label
    var label: String { L.t(rawValue) }
    var hint: String {
        switch self {
        case .rawDecode:
            return L.t("真正解码 RAW 数据，能看到系统渲染与富士直出的真实差异（较慢）")
        case .embedded:
            return L.t("只对 RAW 生效：读 RAW 内嵌的 JPEG 预览。它约等于相机直出，因此会和 HIF 几乎一样")
        }
    }
    /// 供界面标注用
    var appliesToRawOnly: Bool { self == .embedded }
}

/// 带缓存的图像解码器。所有解码都在后台线程完成。
final class ImageStore {
    static let shared = ImageStore()

    private final class Box { let img: CGImage; init(_ i: CGImage) { img = i } }

    private let cache = NSCache<NSString, Box>()
    private let queue = DispatchQueue(label: "rafhif.decode", qos: .userInitiated, attributes: .concurrent)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private init() {
        cache.totalCostLimit = 640 * 1024 * 1024   // ~640MB 上限，超出自动淘汰
        cache.countLimit = 300
    }

    /// 把请求尺寸向上取整到 8 的倍数 —— 基本等同精确尺寸。
    ///
    /// 这里必须贴合，不能像早先那样取 2 的幂：只要解码尺寸与画布物理像素不一致，
    /// 画布就会对**整幅图**再做一次重采样，每个像素都会被改动
    /// （实测：需要 1800 却解 1856，仅 3% 的过量就让平均差达到 4.3/255）。
    /// 8 px 粒度既能 1:1 直通，又能避免浮点抖动产生大量只差一两像素的缓存条目。
    ///
    /// 之所以敢用这么细的粒度：只有换片、缩放（去抖 320ms）、画布尺寸变化（同样去抖）
    /// 才会重新取档位，不会每帧都解码。
    static func bucket(_ maxPixel: Int) -> Int {
        let v = ((maxPixel + 7) / 8) * 8
        return min(max(v, 64), 8192)
    }

    private func key(_ url: URL, _ bucket: Int, _ mode: DecodeMode) -> String {
        "\(url.path)|\(bucket)|\(mode.rawValue)"
    }

    /// 同步查缓存（不触发解码），用于避免闪烁
    func cached(_ url: URL, maxPixel: Int, mode: DecodeMode) -> CGImage? {
        cache.object(forKey: key(url, Self.bucket(maxPixel), mode) as NSString)?.img
    }

    /// 异步解码
    func load(_ url: URL, maxPixel: Int, mode: DecodeMode, completion: @escaping (CGImage?) -> Void) {
        let b = Self.bucket(maxPixel)
        let k = key(url, b, mode)
        if let hit = cache.object(forKey: k as NSString) {
            completion(hit.img)
            return
        }
        queue.async {
            let img = Self.decode(url, maxPixel: b, mode: mode)
            if let img {
                self.cache.setObject(Box(img), forKey: k as NSString,
                                     cost: img.bytesPerRow * img.height)
            }
            DispatchQueue.main.async { completion(img) }
        }
    }

    func loadAsync(_ url: URL, maxPixel: Int, mode: DecodeMode) async -> CGImage? {
        await withCheckedContinuation { cont in
            load(url, maxPixel: maxPixel, mode: mode) { cont.resume(returning: $0) }
        }
    }

    /// 实际解码。
    ///
    /// 「内嵌预览」只对 RAW 有意义 —— RAW 文件里埋着一张 JPEG 预览图，才有"读预览"与
    /// "真解码"之分。HEIF / JPG 本身已经是成片，没有这个区分；若把 FromImageIfAbsent
    /// 用在 HEIF 上，ImageIO 会返回一个没有像素数据的空壳图，画出来就是全透明（看着全黑）。
    static func decode(_ url: URL, maxPixel: Int, mode: DecodeMode) -> CGImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }

        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if mode == .embedded && isRawSource(src) {
            // 只有 RAW 才允许退回内嵌预览
            opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }

        if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
           isUsable(img) {
            return img
        }

        // 兜底 1：完整解码
        if let img = CGImageSourceCreateImageAtIndex(
            src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
           isUsable(img) {
            return img
        }

        // 兜底 2：无条件强制生成缩略图
        var forced = opts
        forced.removeValue(forKey: kCGImageSourceCreateThumbnailFromImageIfAbsent)
        forced[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(src, 0, forced as CFDictionary)
    }

    /// 读取图片的**原始**像素尺寸（不受解码精度影响）。
    /// 显示比例必须相对它来算，否则解码精度一变读数就跟着变。
    static func nativeSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 是否为 RAW 格式（只有 RAW 才有"内嵌预览"的概念）
    static func isRawSource(_ src: CGImageSource) -> Bool {
        guard let id = CGImageSourceGetType(src) as String?, let ut = UTType(id) else { return false }
        return ut.conforms(to: .rawImage)
    }

    /// ImageIO 在某些参数组合下会返回没有像素数据的空壳 CGImage（绘制出来完全透明）。
    /// 这种图必须丢掉，否则界面上就是一片黑。
    static func isUsable(_ img: CGImage) -> Bool {
        guard img.width > 0, img.height > 0 else { return false }
        guard let dp = img.dataProvider, dp.data != nil else { return false }
        return true
    }

    /// 生成差异图：|RAF - HIF| 并放大对比度
    func difference(_ a: CGImage, _ b: CGImage) -> CGImage? {
        var ciA = CIImage(cgImage: a)
        var ciB = CIImage(cgImage: b)

        // 统一到同一尺寸
        let exA = ciA.extent, exB = ciB.extent
        if exA.width != exB.width || exA.height != exB.height, exB.width > 0, exB.height > 0 {
            ciB = ciB.transformed(by: CGAffineTransform(scaleX: exA.width / exB.width,
                                                        y: exA.height / exB.height))
            ciA = CIImage(cgImage: a)
        }

        guard let blend = CIFilter(name: "CIDifferenceBlendMode",
                                   parameters: [kCIInputImageKey: ciB,
                                                kCIInputBackgroundImageKey: ciA]),
              let diff = blend.outputImage else { return nil }

        // 线性放大差异。注意不能用 CIColorControls 的 contrast：
        // 它以 0.5 中灰为中心拉开，而差异值都贴近 0，提高对比度会把它们压成纯黑。
        let gain = adaptiveGain(diff)
        let boosted = diff.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let extent = ciA.extent
        return ciContext.createCGImage(boosted, from: extent)
    }

    /// 依据差异亮度的高分位数决定放大倍数。
    /// 不同照片对的差异幅度差别很大，固定倍数不是过暗就是过曝。
    private func adaptiveGain(_ img: CIImage, target: Double = 225) -> CGFloat {
        let ex = img.extent
        guard ex.width > 1, ex.height > 1 else { return 4 }
        let scale = 200.0 / Double(max(ex.width, ex.height))
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = small.extent.integral
        guard rect.width > 1, rect.height > 1,
              let cg = ciContext.createCGImage(small, from: rect) else { return 4 }

        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { p in
            if let ctx = CGContext(data: p.baseAddress, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var hist = [Int](repeating: 0, count: 256)
        for v in buf { hist[Int(v)] += 1 }
        let total = w * h
        var acc = 0
        var p99 = 8
        for i in 0..<256 {
            acc += hist[i]
            if acc >= Int(Double(total) * 0.99) { p99 = i; break }
        }
        let g = target / Double(max(p99, 3))
        return CGFloat(min(max(g, 1.0), 30.0))
    }
}

// MARK: - 异步缩略图

import SwiftUI

/// 侧边栏 / 网格用的异步缩略图
struct ThumbView: View {
    let url: URL?
    var size: CGFloat = 128
    var mode: DecodeMode = .rawDecode

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.22))
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size * 0.72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(url?.path ?? "nil")|\(mode.rawValue)") {
            guard let url else { image = nil; failed = true; return }
            failed = false
            if let hit = ImageStore.shared.cached(url, maxPixel: Int(size * 2), mode: mode) {
                image = hit; return
            }
            let img = await ImageStore.shared.loadAsync(url, maxPixel: Int(size * 2), mode: mode)
            if Task.isCancelled { return }
            image = img
            failed = (img == nil)
        }
    }
}
