import Foundation
import Photos
import AppKit

/// 把照片加入「照片」App 的图库。
///
/// 注意：Info.plist 里**必须**有 `NSPhotoLibraryAddUsageDescription`，
/// 否则一请求权限就会被系统直接终止（不是报错，是崩）。
enum PhotosImport {

    enum Result {
        case added
        case denied
        case failed(String)
    }

    /// 加入图库。用 `.addOnly` 权限，不申请读取整个图库 —— 请求的权限越少越容易通过。
    static func add(_ url: URL, completion: @escaping (Result) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.denied) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                // 关键：默认就是拷贝，这里显式写出来 —— 绝不能把用户的原片移走
                opts.shouldMoveFile = false
                opts.originalFilename = url.lastPathComponent
                req.addResource(with: .photo, fileURL: url, options: opts)
            } completionHandler: { ok, err in
                DispatchQueue.main.async {
                    if ok { completion(.added) }
                    else { completion(.failed(err?.localizedDescription ?? "未知错误")) }
                }
            }
        }
    }
}
