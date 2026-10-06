import Foundation
import ImageIO
import CoreGraphics

// MARK: - 配对模型

/// 一张照片的 RAF / HIF 配对
struct PhotoPair: Identifiable, Hashable {
    let stem: String
    let folderName: String
    let raf: URL?
    let hif: URL?
    let jpg: URL?

    var id: String { folderName + "/" + stem }

    /// 左右两侧的图源：左 = RAW（优先），右 = HEIF
    var leftURL: URL? { raf ?? hif ?? jpg }
    var rightURL: URL? { hif }
    var hasBoth: Bool { raf != nil && hif != nil }

    var tag: String {
        if hasBoth { return "RAF+HIF" }
        if raf != nil { return L.t("仅 RAF") }
        if hif != nil { return L.t("仅 HIF") }
        return L.t("仅 JPG")
    }
}

/// 一个日期文件夹
struct FolderGroup: Identifiable, Hashable {
    let name: String
    let path: URL
    let pairs: [PhotoPair]
    var id: String { name }
}

// MARK: - 目录扫描

enum LibraryScanner {
    static let rafExt: Set<String> = ["raf"]
    static let heifExt: Set<String> = ["hif", "heic", "heif"]
    static let otherExt: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]

    /// 在给定目录下查找配对文件（不递归）
    static func pairs(in folder: URL) -> [PhotoPair] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var raf: [String: URL] = [:]
        var hif: [String: URL] = [:]
        var jpg: [String: URL] = [:]

        for f in files {
            let ext = f.pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            let stem = f.deletingPathExtension().lastPathComponent
            if rafExt.contains(ext) { raf[stem] = f }
            else if heifExt.contains(ext) { hif[stem] = f }
            else if otherExt.contains(ext) { jpg[stem] = f }
        }

        let stems = Set(raf.keys).union(hif.keys).union(jpg.keys)
        return stems.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { PhotoPair(stem: $0, folderName: folder.lastPathComponent,
                             raf: raf[$0], hif: hif[$0], jpg: jpg[$0]) }
    }

    /// 扫描根目录：把每个子目录当作一个日期分组；若根目录自身含图也一并纳入
    static func scan(root: URL) -> [FolderGroup] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var groups: [FolderGroup] = []

        // 根目录自身如果是照片目录
        let rootPairs = pairs(in: root)
        if !rootPairs.isEmpty {
            groups.append(FolderGroup(name: root.lastPathComponent, path: root, pairs: rootPairs))
        }

        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: keys).isDirectory) == true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for d in dirs {
            let p = pairs(in: d)
            if !p.isEmpty {
                groups.append(FolderGroup(name: d.lastPathComponent, path: d, pairs: p))
            }
        }
        return groups
    }
}

// MARK: - 元数据

struct MetaRow: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let left: String
    let right: String
    var differs: Bool { left != right }
}

struct MetaSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let rows: [MetaRow]
}

enum MetaReader {

    /// 读取一张图的全部关注字段，返回 [标签: 值]
    static func read(_ url: URL?) -> [String: String] {
        guard let url else { return [:] }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return [:] }

        var out: [String: String] = [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux  = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        func s(_ v: Any?) -> String? {
            switch v {
            case let x as String: return x.isEmpty ? nil : x
            case let x as NSNumber: return x.stringValue
            case let x as [Any]: return x.isEmpty ? nil : x.map { "\($0)" }.joined(separator: ", ")
            default: return nil
            }
        }

        // 文件
        if let sz = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
            out["文件大小"] = ByteCountFormatter.string(fromByteCount: sz, countStyle: .file)
        }
        out["文件格式"] = url.pathExtension.uppercased()

        // 图像
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            out["分辨率"] = "\(w) × \(h)"
        }
        if let d = s(props[kCGImagePropertyDepth]) { out["位深"] = "\(d) bit" }
        if let cs = props[kCGImagePropertyColorModel] { out["色彩模型"] = "\(cs)" }

        // 机身
        if let v = s(tiff[kCGImagePropertyTIFFMake]) { out["厂商"] = v }
        if let v = s(tiff[kCGImagePropertyTIFFModel]) { out["机型"] = v }
        if let v = s(tiff[kCGImagePropertyTIFFSoftware]) { out["固件/软件"] = v }
        if let v = s(aux[kCGImagePropertyExifAuxLensModel]) { out["镜头"] = v }
        else if let v = s(exif[kCGImagePropertyExifLensModel]) { out["镜头"] = v }
        if let v = s(aux[kCGImagePropertyExifAuxLensSerialNumber]) { out["镜头序列号"] = v }
        if let v = s(exif[kCGImagePropertyExifBodySerialNumber]) { out["机身序列号"] = v }

        // 拍摄参数
        if let v = s(exif[kCGImagePropertyExifDateTimeOriginal]) { out["拍摄时间"] = v }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            out["快门"] = t >= 1 ? String(format: "%.1f s", t)
                                 : String(format: "1/%.0f s", 1.0 / t)
        } else if let t = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
            let d = t.doubleValue
            out["快门"] = d >= 1 ? String(format: "%.1f s", d) : String(format: "1/%.0f s", 1.0 / d)
        }
        if let v = s(exif[kCGImagePropertyExifFNumber]), let d = Double(v) {
            out["光圈"] = String(format: "f/%.1f", d)
        }
        if let v = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
           let first = v.first {
            out["ISO"] = "\(first)"
        }
        if let v = s(exif[kCGImagePropertyExifFocalLength]), let d = Double(v) {
            out["焦距"] = String(format: "%.0f mm", d)
        }
        if let v = s(exif[kCGImagePropertyExifFocalLenIn35mmFilm]) { out["等效焦距"] = "\(v) mm" }
        if let v = s(exif[kCGImagePropertyExifExposureBiasValue]), let d = Double(v), d != 0 {
            out["曝光补偿"] = String(format: "%+.1f EV", d)
        }
        if let m = exif[kCGImagePropertyExifMeteringMode] as? Int {
            let names = [0: "未知", 1: "平均", 2: "中央重点", 3: "点测", 4: "多点", 5: "评价", 6: "局部"]
            out["测光模式"] = L.t(names[m] ?? "\(m)")
        }
        if let f = exif[kCGImagePropertyExifFlash] as? Int {
            out["闪光灯"] = L.t((f & 1) == 1 ? "闪光" : "未闪光")
        }
        if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int {
            out["白平衡"] = L.t(wb == 0 ? "自动" : "手动")
        }
        if let ls = exif[kCGImagePropertyExifLightSource] as? Int, ls != 0 {
            let names = [1: "日光", 2: "荧光灯", 3: "钨丝灯", 4: "闪光灯", 9: "晴天", 10: "阴天", 11: "阴影"]
            out["光源"] = L.t(names[ls] ?? "\(ls)")
        }
        if let cs = exif[kCGImagePropertyExifColorSpace] as? Int {
            out["色彩空间"] = cs == 1 ? "sRGB"
                               : (cs == 65535 ? L.t("未校准") : L.f("AdobeRGB/其他(%d)", cs))
        }
        if let v = s(exif[kCGImagePropertyExifLensSpecification]) { out["镜头规格"] = v }

        return out
    }

    /// 生成左右对照表格
    static func sections(left: URL?, right: URL?, leftName: String, rightName: String) -> [MetaSection] {
        let l = read(left)
        let r = read(right)

        func sec(_ title: String, _ labels: [String]) -> MetaSection? {
            let rows = labels.compactMap { k -> MetaRow? in
                let lv = l[k], rv = r[k]
                if lv == nil && rv == nil { return nil }
                return MetaRow(label: L.t(k), left: lv ?? "—", right: rv ?? "—")
            }
            return rows.isEmpty ? nil : MetaSection(title: L.t(title), rows: rows)
        }

        let defs: [(String, [String])] = [
            ("文件", ["文件格式", "文件大小", "分辨率", "位深", "色彩模型", "色彩空间"]),
            ("拍摄参数", ["拍摄时间", "快门", "光圈", "ISO", "焦距", "等效焦距", "曝光补偿", "测光模式", "闪光灯", "白平衡", "光源"]),
            ("器材", ["厂商", "机型", "镜头", "镜头规格", "镜头序列号", "机身序列号", "固件/软件"]),
        ]
        return defs.compactMap { sec($0.0, $0.1) }
    }
}
