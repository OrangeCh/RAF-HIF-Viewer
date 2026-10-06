import Foundation
import AppKit

/// 一个被移入废纸篓的文件（记录了它在废纸篓里的位置，以便撤销）
struct TrashedFile: Identifiable {
    let id = UUID()
    let original: URL
    let inTrash: URL
}

/// 一次删除操作的完整记录
struct TrashRecord {
    let files: [TrashedFile]
    let pairID: String
    let pairStem: String
    let groupName: String
    let date: Date
}

enum TrashError: LocalizedError {
    case outsideRoot(URL)
    case unsupportedType(URL)
    case notDeletable(URL)
    case underlying(URL, Error)

    var errorDescription: String? {
        switch self {
        case .outsideRoot(let u):
            return L.f("拒绝删除当前图库之外的文件：%@", u.lastPathComponent)
        case .unsupportedType(let u):
            return L.f("不支持删除该类型：%@", u.pathExtension)
        case .notDeletable(let u):
            return L.f("文件不可删除（可能是只读卷或权限不足）：%@", u.lastPathComponent)
        case .underlying(let u, let e):
            return L.f("移动 %@ 失败：%@", u.lastPathComponent, e.localizedDescription)
        }
    }
}

/// 把照片移入系统废纸篓。
///
/// 三重安全边界：
/// 1. 只允许删除位于当前图库根目录之下的文件；
/// 2. 只允许删除已知的图片扩展名；
/// 3. 一对文件要么全部成功，要么全部回滚，绝不留下"只删了一半"的配对。
enum TrashManager {

    static let allowedExtensions: Set<String> = [
        "raf", "hif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff",
    ]

    /// 移入废纸篓。任一步失败则回滚此前已移动的文件，并抛出错误。
    static func trash(_ urls: [URL], inside root: URL) throws -> [TrashedFile] {
        let fm = FileManager.default

        // 先把所有前置条件都校验一遍，避免走到一半才发现某个文件不合法
        let rootPath = root.standardizedFileURL.path
        for url in urls {
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(rootPath + "/") else { throw TrashError.outsideRoot(url) }
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
                throw TrashError.unsupportedType(url)
            }
            guard fm.fileExists(atPath: p) else { continue }
            guard fm.isDeletableFile(atPath: p) else { throw TrashError.notDeletable(url) }
        }

        var done: [TrashedFile] = []
        do {
            for url in urls {
                guard fm.fileExists(atPath: url.path) else { continue }
                var resulting: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &resulting)
                guard let trashURL = resulting as URL? else {
                    throw TrashError.underlying(url, CocoaError(.fileWriteUnknown))
                }
                done.append(TrashedFile(original: url, inTrash: trashURL))
            }
            return done
        } catch {
            // 回滚：把已经移走的放回原处，保证配对完整
            for f in done.reversed() {
                try? fm.moveItem(at: f.inTrash, to: f.original)
            }
            if let te = error as? TrashError { throw te }
            throw TrashError.underlying(urls.first ?? root, error)
        }
    }

    /// 从废纸篓恢复。返回恢复失败的文件列表（空表示全部成功）。
    @discardableResult
    static func restore(_ files: [TrashedFile]) -> [URL] {
        let fm = FileManager.default
        var failed: [URL] = []
        for f in files {
            do {
                // 原位置若已被别的文件占用，则不动它，报为失败
                guard !fm.fileExists(atPath: f.original.path) else {
                    failed.append(f.original); continue
                }
                guard fm.fileExists(atPath: f.inTrash.path) else {
                    failed.append(f.original); continue
                }
                try fm.createDirectory(at: f.original.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: f.inTrash, to: f.original)
            } catch {
                failed.append(f.original)
            }
        }
        return failed
    }
}
