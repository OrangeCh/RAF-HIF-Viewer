import SwiftUI
import AppKit
import CoreGraphics

/// 单图模式下显示哪一侧
enum SoloSide: String, CaseIterable, Identifiable {
    case raf = "RAF"
    case hif = "HIF"
    var id: String { rawValue }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case compare = "对照"
    case blink   = "闪烁"
    case solo    = "单图"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .compare: return "rectangle.split.2x1"
        case .blink:   return "square.on.square.dashed"
        case .solo:    return "rectangle.expand.vertical"
        }
    }
}

/// 布局尺寸的存放处。故意不做成 @Published：
/// 在 GeometryReader 里回写可观察状态会引发 AppKit 约束更新死循环。
final class LayoutBox {
    var paneSize: CGSize = .zero
    /// 屏幕 backing scale。解码精度必须按**物理像素**算，
    /// 否则在 Retina 上只会解到显示所需的一半，画面被硬放大而发虚。
    var scale: CGFloat = 2
    /// 画布实际占用的物理像素
    var pixelSize: CGSize {
        CGSize(width: paneSize.width * scale, height: paneSize.height * scale)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var groups: [FolderGroup] = []
    @Published var selectedGroup: String?
    @Published var selectedPairID: String?
    @Published var mode: ViewMode = .solo          // 默认单图
    @Published var decodeMode: DecodeMode = .rawDecode
    @Published var soloSide: SoloSide = .hif        // 单图默认显示 HIF

    @Published var zoom: CGFloat = 1           // 1 = 适应窗口
    @Published var pan: CGSize = .zero
    @Published var blend: CGFloat = 0           // 0 = RAF, 1 = HIF
    @Published var autoBlink = false
    @Published var blinkPhase = false
    @Published var showDiff = false

    @Published var imageA: CGImage?
    @Published var imageB: CGImage?
    @Published var diffImage: CGImage?
    @Published var loading = false
    @Published var inspectorOn = true
    @Published var decodeGeneration = 0
    /// 原图像素尺寸。显示比例相对它计算，与解码精度解耦。
    @Published var nativeSize: CGSize?

    @Published var metaSections: [MetaSection] = []
    @Published var status: String = ""

    // 删除相关
    @Published var trashHistory: [TrashRecord] = []     // 多级撤销栈，后进先出
    @Published var toast: String?
    @Published var alertMessage: String?
    @Published var confirmBeforeTrash = false
    /// 待确认删除的那一张。右键菜单可以对列表里任意一张发起删除，
    /// 不能只认"当前选中"的那张，否则容易删错。
    @Published var pendingTrashPair: PhotoPair?

    /// 撤销栈上限。每条记录只是几个 URL，本身很轻，设大一点足够连续挑片用。
    private let trashHistoryLimit = 500

    var canUndoTrash: Bool { !trashHistory.isEmpty }
    var trashDepth: Int { trashHistory.count }

    /// 同步给菜单栏，使「撤销」在没得撤销时置灰
    private func syncUndoBridge() {
        UndoBridge.shared.canUndo = canUndoTrash
        UndoBridge.shared.depth = trashDepth
    }

    let layout = LayoutBox()
    private var toastTask: Task<Void, Never>?

    private var blinkTask: Task<Void, Never>?
    private var zoomDebounce: Task<Void, Never>?
    private var loadToken = UUID()
    private var loadedBucket = 0

    // MARK: 派生

    var currentGroup: FolderGroup? { groups.first { $0.name == selectedGroup } }
    var currentPairs: [PhotoPair] { currentGroup?.pairs ?? [] }
    var currentPair: PhotoPair? {
        guard let id = selectedPairID else { return nil }
        return currentPairs.first { $0.id == id }
    }
    var currentIndex: Int? {
        guard let id = selectedPairID else { return nil }
        return currentPairs.firstIndex { $0.id == id }
    }

    /// 适应窗口时，1 个**原图**像素占几个点。
    /// 必须用原图尺寸而不是解码后的尺寸 —— 解码尺寸随缩放变化，
    /// 拿它算会让同一个缩放级别读出不同的比例，也会让「100% 像素」按错的比例走。
    func fitScale() -> CGFloat {
        let ps = layout.paneSize
        guard ps.width > 1, ps.height > 1 else { return 1 }
        let n = nativeSize ?? imageA.map { CGSize(width: $0.width, height: $0.height) }
                             ?? imageB.map { CGSize(width: $0.width, height: $0.height) }
        guard let n, n.width > 0, n.height > 0 else { return 1 }
        return min(ps.width / n.width, ps.height / n.height)
    }

    /// 实际像素显示比例，1.0 = 100%（1 个原图像素 = 1 个屏幕点）
    var pixelScale: CGFloat { fitScale() * zoom }

    /// 缩放上下限按**实际像素比例**定，而不是相对适应窗口的倍数 ——
    /// 否则原图越大、画布越小，能放大的上限就越低。下限至少允许缩到适应窗口。
    func clampZoom(_ z: CGFloat) -> CGFloat {
        let fs = max(fitScale(), 0.00001)
        let lo = min(1.0, 0.02 / fs)              // 实际 2%
        let hi = min(600.0, max(1.0, 16 / fs))    // 实际 1600%
        return min(max(z, lo), hi)
    }

    /// 当前缩放需要的解码精度
    var currentBucket: Int {
        let ps = layout.pixelSize          // 用物理像素，不是点
        let need = Double(max(ps.width, ps.height)) * Double(max(zoom, 1))
        return ImageStore.bucket(Int(min(max(need, 1024), 8192)))
    }

    // MARK: 操作

    /// 启动时该打开哪个目录：优先上次用过的，其次默认位置。
    ///
    /// 记住上次的目录对多机使用很关键 —— 否则换一台 Mac 每次启动都要重新选。
    static func startupFolder() -> URL? {
        let fm = FileManager.default
        if let p = UserDefaults.standard.string(forKey: lastRootKey), fm.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        // 没有历史记录时退回「图片」文件夹。不写死具体路径 ——
        // 那既是开发者个人的目录，换个用户也毫无意义。
        let pictures = fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return fm.fileExists(atPath: pictures.path) ? pictures : nil
    }

    private static let lastRootKey = "lastRootPath"

    func openRoot(_ url: URL) {
        rootURL = url
        UserDefaults.standard.set(url.path, forKey: Self.lastRootKey)
        groups = LibraryScanner.scan(root: url)
        selectedGroup = groups.first?.name
        selectedPairID = currentPairs.first?.id
        resetView()
        reloadMeta()
        decodeGeneration += 1
        status = L.f("%d 个文件夹 · %d 张照片", groups.count,
                     groups.reduce(0) { $0 + $1.pairs.count })
    }

    func selectGroup(_ name: String) {
        guard name != selectedGroup else { return }
        selectedGroup = name
        selectedPairID = currentPairs.first?.id
        resetView()
        reloadMeta()
        decodeGeneration += 1
    }

    func selectPair(_ id: String) {
        guard id != selectedPairID else { return }
        selectedPairID = id
        pan = .zero
        loadedBucket = 0
        reloadMeta()
        decodeGeneration += 1
    }

    func step(_ delta: Int) {
        let pairs = currentPairs
        guard !pairs.isEmpty else { return }
        let i = currentIndex ?? 0
        let n = min(max(i + delta, 0), pairs.count - 1)
        if n != i { selectPair(pairs[n].id) }
    }

    func resetView() {
        zoom = 1; pan = .zero; blend = 0; showDiff = false
        autoBlink = false; blinkTask?.cancel(); blinkPhase = false
    }

    func setZoom(_ z: CGFloat) {
        zoom = clampZoom(z)
        if zoom <= 1.0001 { pan = .zero }
        clampPan()
        scheduleResolutionUpgrade()
    }

    func zoomTo100() { setZoom(1 / max(fitScale(), 0.00001)) }

    /// Ctrl + 滚轮缩放。
    /// 基准取自 model 自己持有的 zoom（唯一权威），不会因为事件密集而滞后。
    /// 平移量按光标锚点重算，使光标下的图像点保持不动。
    func applyScrollZoom(factor: CGFloat, anchor: CGPoint) {
        let newZoom = clampZoom(zoom * factor)
        guard abs(newZoom - zoom) > 0.0001 else { return }
        if let img = imageA ?? imageB {
            pan = CanvasNSView.anchoredPan(
                currentZoom: zoom, newZoom: newZoom, currentPan: pan,
                anchor: anchor, viewSize: layout.paneSize,
                imageSize: CGSize(width: img.width, height: img.height))
        }
        zoom = newZoom
        clampPan()
        scheduleResolutionUpgrade()
    }

    /// 缩放停止后再决定是否提高解码精度，避免拖动过程中反复解码
    func scheduleResolutionUpgrade() {
        zoomDebounce?.cancel()
        zoomDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard let self, !Task.isCancelled else { return }
            let want = self.currentBucket
            if want > self.loadedBucket {
                self.loadedBucket = want
                self.decodeGeneration += 1
            }
        }
    }

    func clampPan() {
        guard zoom > 1 else { pan = .zero; return }
        let ps = layout.paneSize
        guard ps.width > 1, ps.height > 1 else { return }
        // 图层在 zoom 倍下占据的尺寸就是 画布尺寸 × zoom，与解码精度无关
        let mx = max(0, ps.width  * (zoom - 1) / 2 + 40)
        let my = max(0, ps.height * (zoom - 1) / 2 + 40)
        pan = CGSize(width: min(max(pan.width, -mx), mx),
                     height: min(max(pan.height, -my), my))
    }

    func reloadMeta() {
        guard let p = currentPair else { metaSections = []; return }
        metaSections = MetaReader.sections(left: p.raf ?? p.jpg, right: p.hif,
                                           leftName: "RAF", rightName: "HIF")
    }

    func toggleBlink() {
        autoBlink.toggle()
        blinkTask?.cancel()
        guard autoBlink else { blinkPhase = false; blend = 0; return }
        blinkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 460_000_000)
                guard let self, !Task.isCancelled else { return }
                self.blinkPhase.toggle()
                self.blend = self.blinkPhase ? 1 : 0
            }
        }
    }

    func loadImages() async {
        guard let p = currentPair else {
            imageA = nil; imageB = nil; diffImage = nil; return
        }
        let token = UUID()
        loadToken = token
        loading = true
        let bucket = currentBucket
        loadedBucket = bucket
        let dm = decodeMode
        if let u = p.raf ?? p.hif { nativeSize = ImageStore.nativeSize(of: u) }

        // 只在需要时才解码。单图模式下没必要把另一侧也解出来 ——
        // RAF 动辄 85 MB，白解一遍会让翻页慢一倍。
        let leftURL: URL?
        let rightURL: URL?
        switch mode {
        case .solo:
            if soloSide == .raf {
                leftURL = p.raf ?? p.jpg; rightURL = nil
            } else {
                leftURL = nil; rightURL = p.hif
            }
        case .compare, .blink:
            leftURL = p.raf ?? p.jpg
            rightURL = p.hif
        }

        async let aTask: CGImage? = leftURL == nil ? nil
            : ImageStore.shared.loadAsync(leftURL!, maxPixel: bucket, mode: dm)
        async let bTask: CGImage? = rightURL == nil ? nil
            : ImageStore.shared.loadAsync(rightURL!, maxPixel: bucket, mode: dm)
        let (ra, rb) = await (aTask, bTask)

        guard loadToken == token else { return }
        imageA = ra
        imageB = rb
        loading = false
        diffImage = nil
        if showDiff { await loadDiffIfNeeded() }
    }

    func loadDiffIfNeeded() async {
        guard showDiff, diffImage == nil, let a = imageA, let b = imageB else { return }
        let d = ImageStore.shared.difference(a, b)
        guard showDiff else { return }
        diffImage = d
    }

    // MARK: 删除到废纸篓

    var canTrash: Bool { currentPair != nil && rootURL != nil }

    /// ⌫ 键入口：按设置决定是否先弹确认
    /// 右键「拷贝图片」要拷的那一份。
    ///
    /// 单图模式下拷**当前显示的那一侧** —— 否则你看着 RAF 却拷到 HIF，
    /// 而两者九成以上像素不同，会很意外。其它模式优先 HIF（相机直出、体积小、通用）。
    func copySourceURL(for pair: PhotoPair) -> URL? {
        if mode == .solo {
            return soloSide == .raf ? (pair.raf ?? pair.jpg ?? pair.hif)
                                    : (pair.hif ?? pair.raf ?? pair.jpg)
        }
        return pair.hif ?? pair.raf ?? pair.jpg
    }

    func requestTrash() { if let p = currentPair { requestTrash(p) } }

    func requestTrash(_ pair: PhotoPair) {
        guard rootURL != nil else { return }
        if confirmBeforeTrash {
            pendingTrashPair = pair
        } else {
            performTrash(pair)
        }
    }

    func performTrash() { if let p = currentPair { performTrash(p) } }

    func performTrash(_ pair: PhotoPair) {
        guard let root = rootURL else { return }
        // 一张照片的所有文件（正常是 RAF + HIF）一起处理
        let urls = [pair.raf, pair.hif, pair.jpg].compactMap { $0 }
        guard !urls.isEmpty else { return }

        do {
            let files = try TrashManager.trash(urls, inside: root)
            trashHistory.append(TrashRecord(files: files, pairID: pair.id, pairStem: pair.stem,
                                            groupName: pair.folderName, date: Date()))
            if trashHistory.count > trashHistoryLimit {
                trashHistory.removeFirst(trashHistory.count - trashHistoryLimit)
            }
            syncUndoBridge()

            pendingTrashPair = nil
            let names = urls.map(\.lastPathComponent).joined(separator: " + ")
            show(toast: L.f("已移入废纸篓：%@", names))
            advance(afterTrashing: pair.id)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 撤销最近一次删除。栈里还有更早的记录时，可继续连按 ⌘Z 逐级回退。
    func undoTrash() {
        guard let rec = trashHistory.popLast() else { return }
        let failed = TrashManager.restore(rec.files)
        syncUndoBridge()

        if failed.isEmpty {
            let left = trashHistory.count
            show(toast: L.f("已恢复 %@（%d 个文件）", rec.pairStem, rec.files.count)
                      + (left > 0 ? L.f("，还可撤销 %d 步", left) : ""))
        } else {
            // 恢复失败的（例如废纸篓已被清空）不再留在栈里，否则会反复失败
            alertMessage = L.t("以下文件恢复失败（可能已被清空废纸篓）：") + "\n"
                + failed.map { "• \($0.lastPathComponent)" }.joined(separator: "\n")
        }
        reloadGroup(named: rec.groupName, selecting: rec.pairID)
    }

    /// 删除后：从内存列表移除该配对，并自动前进到下一张（方便连续挑片）
    private func advance(afterTrashing id: String) {
        guard let gi = groups.firstIndex(where: { $0.pairs.contains { $0.id == id } }),
              let pi = groups[gi].pairs.firstIndex(where: { $0.id == id }) else { return }
        let g = groups[gi]
        var remaining = g.pairs
        remaining.remove(at: pi)

        if remaining.isEmpty {
            groups.remove(at: gi)
            let next = groups.indices.contains(gi) ? groups[gi] : groups.last
            selectedGroup = next?.name
            selectedPairID = next?.pairs.first?.id
        } else {
            groups[gi] = FolderGroup(name: g.name, path: g.path, pairs: remaining)
            selectedPairID = remaining[min(pi, remaining.count - 1)].id
        }
        pan = .zero
        reloadMeta()
        decodeGeneration += 1
    }

    /// 重新读取某个日期文件夹（撤销后用它恢复列表）
    func reloadGroup(named name: String, selecting pid: String?) {
        guard let root = rootURL else { return }
        let path = URL(fileURLWithPath: root.path).appendingPathComponent(name)
        let pairs = LibraryScanner.pairs(in: path)

        if let gi = groups.firstIndex(where: { $0.name == name }) {
            if pairs.isEmpty {
                groups.remove(at: gi)
            } else {
                groups[gi] = FolderGroup(name: name, path: path, pairs: pairs)
            }
        } else if !pairs.isEmpty {
            groups.append(FolderGroup(name: name, path: path, pairs: pairs))
            groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        if let pid, groups.contains(where: { $0.pairs.contains { $0.id == pid } }) {
            selectedGroup = name
            selectedPairID = pid
        } else if selectedGroup == name {
            selectedPairID = groups.first { $0.name == name }?.pairs.first?.id
        }
        pan = .zero
        reloadMeta()
        decodeGeneration += 1
        refreshStatus()
    }

    func refreshStatus() {
        status = L.f("%d 个文件夹 · %d 张照片", groups.count,
                     groups.reduce(0) { $0 + $1.pairs.count })
    }

    func show(toast msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toast = nil
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("选择包含照片或日期子文件夹的目录")
        if panel.runModal() == .OK, let u = panel.url { openRoot(u) }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        HSplitView {
            SidebarView(model: model)
                .frame(minWidth: 126, idealWidth: 146, maxWidth: 200)
            ThumbnailGridView(model: model)
                .frame(minWidth: 164, idealWidth: 186, maxWidth: 260)
            DetailView(model: model)
                .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
            if model.inspectorOn {
                InspectorView(model: model)
                    .frame(minWidth: 236, idealWidth: 288, maxWidth: 420)
            }
        }
        .frame(minWidth: 1020, minHeight: 700)
        .task {
            if model.rootURL == nil, let start = AppModel.startupFolder() {
                model.openRoot(start)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFolderRequested)) { _ in
            model.chooseFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .undoTrashRequested)) { _ in
            model.undoTrash()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trashRequested)) { _ in
            model.requestTrash()
        }
    }
}

// MARK: - 侧边栏

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "photo.stack").foregroundStyle(.secondary)
                Text(model.rootURL?.lastPathComponent ?? L.t("未选择目录"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { model.chooseFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless).help("选择照片根目录")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.ultraThinMaterial)

            List(selection: Binding(
                get: { model.selectedGroup },
                set: { if let v = $0 { model.selectGroup(v) } }
            )) {
                ForEach(model.groups) { g in
                    // 单列紧凑行：日期在左，张数右对齐，占一行高度
                    HStack(spacing: 6) {
                        Text(g.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(g.pairs.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                    .tag(g.name)
                    .help(L.f("%d 张", g.pairs.count))
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)
        }
    }

    private func chooseFolder() {
        model.chooseFolder()
    }
}

// MARK: - 缩略图

struct ThumbnailGridView: View {
    @ObservedObject var model: AppModel
    /// 当前鼠标悬停在哪一行。放在列表层而不是每行自己存，
    /// 是为了让"选中"那行能在悬停别行时把高亮淡出。
    @State private var hoveredRowID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet").foregroundStyle(.secondary)
                Text(model.selectedGroup ?? "—").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(L.f("%d 张", model.currentPairs.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.ultraThinMaterial)

            if model.currentPairs.isEmpty {
                ContentUnavailableView("没有照片", systemImage: "photo.on.rectangle.angled",
                                       description: Text("在左侧选择一个日期文件夹"))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(model.currentPairs) { p in
                                ThumbRow(model: model,
                                         pair: p,
                                         selected: p.id == model.selectedPairID,
                                         mode: model.decodeMode,
                                         hovering: hoveredRowID == p.id,
                                         dimSelected: hoveredRowID != nil && hoveredRowID != p.id)
                                    .id(p.id)
                                    .onHover { h in
                                        if h {
                                            hoveredRowID = p.id
                                        } else if hoveredRowID == p.id {
                                            hoveredRowID = nil
                                        }
                                    }
                                    .onTapGesture { model.selectPair(p.id) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: model.selectedPairID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

/// 缩略图栏的一行（单列列表）
struct ThumbRow: View {
    @ObservedObject var model: AppModel
    let pair: PhotoPair
    let selected: Bool
    let mode: DecodeMode

    /// 鼠标是否停在这一行上。
    ///
    /// 为什么需要它：SwiftUI 没有右键手势，`.contextMenu` 也不提供"即将打开"的回调，
    /// 于是菜单浮在哪儿、究竟要删哪张，光看界面判断不出来 —— 而"当前选中"那行的蓝色
    /// 高亮往往和菜单指向的行不是同一行，反而误导。
    /// 用悬停高亮后，右键的那一刻光标下那一行本身就是亮的，指向就明确了。
    let hovering: Bool
    /// 正悬停在别的行上 —— 此时把自己的"选中"高亮淡出，
    /// 免得两行同时看起来像被选中，反而分不清右键要作用在哪一行。
    let dimSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            ThumbView(url: pair.leftURL, size: 58, mode: mode)
            VStack(alignment: .leading, spacing: 1) {
                Text(pair.stem)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Text(pair.tag)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            // 悬停时露出一个垃圾桶图标：明确提示这一行可以右键删除
            if hovering {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected
                  ? Color.accentColor.opacity(dimSelected ? 0.10 : 0.30)
                  : (hovering ? Color.accentColor.opacity(0.16) : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(hovering ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        // 右键菜单作用于**这一行对应的那张**，而不是"当前选中的那张"
        .contextMenu { PhotoContextMenu(model: model, pair: pair) }
    }
}

/// 缩略图列表与第三栏共用的右键菜单。
/// 抽成组件是为了两处菜单项永远一致，不会改了一边忘了另一边。
struct PhotoContextMenu: View {
    @ObservedObject var model: AppModel
    let pair: PhotoPair

    var body: some View {
        Button(L.t("拷贝图片")) {
            guard let url = model.copySourceURL(for: pair) else { return }
            model.show(toast: L.t("正在拷贝图片…"))
            PhotoActions.copyImage(url) { ok in
                model.show(toast: ok ? L.t("已拷贝图片到剪贴板") : L.t("拷贝图片失败"))
            }
        }
        Button(L.t("拷贝文件名")) { PhotoActions.copyName(pair) }
        Button(L.t("在访达中显示")) { PhotoActions.revealInFinder(pair) }
        Divider()
        Button(L.t("添加到相册")) {
            guard let url = model.copySourceURL(for: pair) else { return }
            model.show(toast: L.t("正在添加到相册…"))
            PhotosImport.add(url) { result in
                switch result {
                case .added:
                    model.show(toast: L.t("已添加到相册"))
                case .denied:
                    model.show(toast: L.t("没有照片图库的写入权限"))
                case .failed(let msg):
                    model.show(toast: L.f("添加失败：%@", msg))
                }
            }
        }
        Divider()
        Button(L.t("移入废纸篓"), role: .destructive) { model.requestTrash(pair) }
            .disabled([pair.raf, pair.hif, pair.jpg].allSatisfy { $0 == nil })
    }
}

enum PhotoActions {
    /// 拷贝图片到剪贴板。
    ///
    /// 写 PNG 而不是把文件本身放上去 —— 前者可以直接粘进聊天窗口，通用得多。
    /// 编码放到后台：即使限制到长边 4096，也有一千多万像素，同步做会卡住界面。
    static func copyImage(_ url: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(
                            src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let data = pngData(from: img, maxPixel: 4096) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(data, forType: .png)
                completion(true)
            }
        }
    }

    /// 编码成 PNG。长边超过 maxPixel 时先等比缩小 ——
    /// 全尺寸 7728×5152 有 4000 万像素，编码慢、粘贴目标多半还要再压一遍，不划算。
    private static func pngData(from img: CGImage, maxPixel: Int) -> Data? {
        var target = img
        let longest = max(img.width, img.height)
        if longest > maxPixel {
            let scale = Double(maxPixel) / Double(longest)
            let w = Int((Double(img.width) * scale).rounded())
            let h = Int((Double(img.height) * scale).rounded())
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: 0,
                                   space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { target = scaled }
            }
        }
        return NSBitmapImageRep(cgImage: target).representation(using: .png, properties: [:])
    }

    /// 在访达里选中该照片的 RAF（没有则用 HIF / JPG）
    static func revealInFinder(_ pair: PhotoPair) {
        guard let url = pair.raf ?? pair.hif ?? pair.jpg else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyName(_ pair: PhotoPair) {
        let names = [pair.raf, pair.hif, pair.jpg].compactMap { $0?.lastPathComponent }
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - 详情

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.currentPair == nil {
                ContentUnavailableView("未选择照片", systemImage: "photo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Group {
                    switch model.mode {
                    case .compare: ComparePane(model: model)
                    case .blink:   BlinkPane(model: model)
                    case .solo:    SoloPane(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 第三栏查看大图时同样可以右键删除。
                // 画布虽是 NSView，但 SwiftUI 的 contextMenu 能穿透过来（已实测）。
                .contextMenu {
                    if let p = model.currentPair { PhotoContextMenu(model: model, pair: p) }
                }
            }
            Divider()
            statusBar
        }
        .overlay(alignment: .bottom) { toastView }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .task(id: "\(model.selectedPairID ?? "-")|\(model.decodeMode.rawValue)|\(model.decodeGeneration)|\(model.mode.rawValue)|\(model.soloSide.rawValue)") {
            await model.loadImages()
        }
        .task(id: "diff-\(model.showDiff)-\(model.imageA == nil)-\(model.imageB == nil)") {
            await model.loadDiffIfNeeded()
        }
        // 需要可聚焦才能收键盘事件（翻页 / 缩放 / 删除），
        // 但默认会在整个详情栏外面画一圈蓝色焦点环 —— 看图时非常碍眼。
        // focusEffectDisabled 保留键盘处理，只是不画那圈框。
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow)  { model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model.step(1);  return .handled }
        .onKeyPress(.upArrow)    { model.setZoom(model.zoom * 1.25); return .handled }
        .onKeyPress(.downArrow)  { model.setZoom(model.zoom / 1.25); return .handled }
        .onKeyPress(.space)      { model.setZoom(1); return .handled }
        .onKeyPress(.delete)        { model.requestTrash(); return .handled }
        .onKeyPress(.deleteForward) { model.requestTrash(); return .handled }
        .confirmationDialog("把这张照片移入废纸篓？",
                            isPresented: Binding(
                                get: { model.pendingTrashPair != nil },
                                set: { if !$0 { model.pendingTrashPair = nil } }),
                            titleVisibility: .visible) {
            Button("移入废纸篓", role: .destructive) {
                if let p = model.pendingTrashPair { model.performTrash(p) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(trashConfirmMessage)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var trashConfirmMessage: String {
        guard let p = model.pendingTrashPair ?? model.currentPair else { return "" }
        let files = [p.raf, p.hif, p.jpg].compactMap { $0?.lastPathComponent }
        return files.joined(separator: "\n") + "\n\n" + L.t("文件会进入废纸篓，可随时恢复。")
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = model.toast {
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 11))
                Text(t).font(.system(size: 11))
                if model.canUndoTrash {
                    Button(model.trashDepth > 1 ? L.f("撤销（还有 %d 步）", model.trashDepth) : L.t("撤销")) {
                        model.undoTrash()
                    }
                    .buttonStyle(.link).font(.system(size: 11, weight: .semibold))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .padding(.bottom, 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: 工具栏
    //
    // 两个选择器改成下拉菜单以节省横向空间；右侧控制组用 ViewThatFits 做三级降级，
    // 保证窗口再窄也不会被裁掉（之前是固定宽度，窄了就被切）。

    private var header: some View {
        HStack(spacing: 8) {
            modeMenu
            decodeMenu
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                fullControls
                compactControls
                minimalControls
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var modeMenu: some View {
        Menu {
            // 用 Toggle 而不是 Picker：Picker 即使是空标题，macOS 也会把它渲染成
            // 一个分组标题行，菜单顶部因此多出一行空白。Toggle 则直接渲染成带勾选的菜单项。
            ForEach(ViewMode.allCases) { m in
                Toggle(isOn: Binding(
                    get: { model.mode == m },
                    set: { if $0 { model.mode = m } }
                )) {
                    Label(L.t(m.rawValue), systemImage: m.symbol)
                }
            }
        } label: {
            Label(L.t(model.mode.rawValue), systemImage: model.mode.symbol)
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L.t("视图模式"))
    }

    private var decodeMenu: some View {
        Menu {
            ForEach(DecodeMode.allCases) { m in
                Toggle(isOn: Binding(
                    get: { model.decodeMode == m },
                    set: { if $0 { model.decodeMode = m } }
                )) {
                    Text(m.label)
                }
            }
            Divider()
            Text(model.decodeMode.hint)
        } label: {
            Label(model.decodeMode.label, systemImage: "camera.filters")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.decodeMode.hint)
    }

    @ViewBuilder private var blinkToggles: some View {
        if model.mode == .blink {
            Toggle(isOn: Binding(get: { model.showDiff },
                                 set: { model.showDiff = $0 })) {
                Label("差异", systemImage: "circle.lefthalf.filled")
            }
            .toggleStyle(.button).controlSize(.small)

            Toggle(isOn: Binding(get: { model.autoBlink },
                                 set: { _ in model.toggleBlink() })) {
                Label("自动", systemImage: "playpause")
            }
            .toggleStyle(.button).controlSize(.small)
        }
    }

    private var zoomReadout: some View {
        Text(L.f("像素 %.0f%%", model.pixelScale * 100))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary).frame(width: 86, alignment: .trailing)
    }

    @ViewBuilder private var zoomButtons: some View {
        Button { model.setZoom(1) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
            .help("适应窗口")
        Button { model.zoomTo100() } label: { Image(systemName: "1.magnifyingglass") }
            .help("100% 像素")
        Button { model.setZoom(model.zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
        Button { model.setZoom(model.zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
    }

    @ViewBuilder private var undoButton: some View {
        if model.canUndoTrash {
            Button { model.undoTrash() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.uturn.backward")
                    if model.trashDepth > 1 {
                        Text("\(model.trashDepth)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                    }
                }
            }
            .help(model.trashDepth > 1
                    ? L.f("撤销移入废纸篓 (⌘Z)，还有 %d 步", model.trashDepth)
                    : L.t("撤销移入废纸篓 (⌘Z)"))
        }
    }

    private var trashButton: some View {
        Button(role: .destructive) { model.requestTrash() } label: {
            Image(systemName: "trash")
        }
        .disabled(!model.canTrash)
        .help("把这张的 RAF 和 HIF 一起移入废纸篓 (⌫)")
    }

    private var confirmToggle: some View {
        Toggle(isOn: $model.confirmBeforeTrash) {
            Image(systemName: model.confirmBeforeTrash ? "checkmark.shield.fill" : "checkmark.shield")
        }
        .toggleStyle(.button).controlSize(.small)
        .help("删除前先弹确认框")
    }

    private var inspectorButton: some View {
        Button { model.inspectorOn.toggle() } label: { Image(systemName: "sidebar.right") }
            .help("显示/隐藏参数面板")
    }

    private var fullControls: some View {
        HStack(spacing: 8) {
            blinkToggles
            zoomReadout
            zoomButtons
            Divider().frame(height: 14)
            undoButton
            trashButton
            confirmToggle
            inspectorButton
        }
    }

    private var compactControls: some View {
        HStack(spacing: 8) {
            zoomButtons
            Divider().frame(height: 14)
            trashButton
            inspectorButton
        }
    }

    private var minimalControls: some View {
        HStack(spacing: 8) {
            trashButton
            inspectorButton
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let p = model.currentPair {
                Text(p.stem).font(.system(size: 10, weight: .semibold, design: .monospaced))
                Text(p.tag).font(.system(size: 10)).foregroundStyle(.secondary)
                if let i = model.currentIndex {
                    Text("\(i + 1) / \(model.currentPairs.count)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(model.decodeMode.hint)
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: 三种视图

struct ComparePane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            single(title: "RAF", subtitle: model.currentPair?.raf?.lastPathComponent ?? L.t("缺失"),
                   image: model.imageA, missing: model.currentPair?.raf == nil, tint: .orange)
            Divider()
            single(title: "HIF", subtitle: model.currentPair?.hif?.lastPathComponent ?? L.t("缺失"),
                   image: model.imageB, missing: model.currentPair?.hif == nil, tint: .cyan)
        }
    }

    private func single(title: String, subtitle: String, image: CGImage?,
                        missing: Bool, tint: Color) -> some View {
        VStack(spacing: 0) {
            PaneLabel(title: title, subtitle: subtitle, tint: tint)
            ZStack {
                CanvasPane(imageA: image, imageB: nil, showA: true, showB: false,
                           zoom: model.zoom, pan: model.pan,
                           onCtrlScrollZoom: { f, a in model.applyScrollZoom(factor: f, anchor: a) },
                           onScrollStep: { d in model.step(d) })
                if missing {
                    Text("该侧没有此格式文件")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .modifier(InteractiveCanvas(model: model))
        }
    }
}

struct BlinkPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PaneLabel(title: model.showDiff ? L.t("差异") : L.t("叠加"),
                      subtitle: model.showDiff ? L.t("|RAF − HIF|，对比度增强")
                                               : L.t("拖动滑杆或开启自动闪烁，在 RAF 与 HIF 间切换"),
                      tint: model.showDiff ? .purple : .pink)
            ZStack {
                if model.showDiff {
                    CanvasPane(imageA: model.diffImage, imageB: nil,
                               showA: true, showB: false,
                               zoom: model.zoom, pan: model.pan,
                               onCtrlScrollZoom: { f, a in model.applyScrollZoom(factor: f, anchor: a) },
                           onScrollStep: { d in model.step(d) })
                    if model.diffImage == nil { ProgressView().controlSize(.small) }
                } else {
                    CanvasPane(imageA: model.imageA, imageB: model.imageB,
                               blend: model.blend, showA: true, showB: true,
                               zoom: model.zoom, pan: model.pan,
                               onCtrlScrollZoom: { f, a in model.applyScrollZoom(factor: f, anchor: a) },
                           onScrollStep: { d in model.step(d) })
                }
            }
            .modifier(InteractiveCanvas(model: model))

            if !model.showDiff {
                HStack(spacing: 10) {
                    Text("RAF").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                    Slider(value: $model.blend, in: 0...1)
                    Text("HIF").font(.system(size: 11, weight: .bold)).foregroundStyle(.cyan)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(.ultraThinMaterial)
            }
        }
    }
}

struct SoloPane: View {
    @ObservedObject var model: AppModel

    private var currentURL: URL? {
        model.soloSide == .raf ? (model.currentPair?.raf ?? model.currentPair?.jpg)
                               : model.currentPair?.hif
    }
    private var currentImage: CGImage? {
        model.soloSide == .raf ? model.imageA : model.imageB
    }
    private var isMissing: Bool { currentURL == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 放在 model 里而不是 @State：切换视图模式时不会被重置
                Picker("", selection: $model.soloSide) {
                    ForEach(SoloSide.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                .help(L.t("显示哪一侧"))
                Text(currentURL?.lastPathComponent ?? L.t("缺失"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial)

            ZStack {
                CanvasPane(imageA: currentImage,
                           imageB: nil, showA: true, showB: false,
                           zoom: model.zoom, pan: model.pan,
                           onCtrlScrollZoom: { f, a in model.applyScrollZoom(factor: f, anchor: a) },
                           onScrollStep: { d in model.step(d) })
                if isMissing {
                    Text("该侧没有此格式文件")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .modifier(InteractiveCanvas(model: model))
        }
    }
}

/// 统一的尺寸上报 + 缩放 / 平移手势
struct InteractiveCanvas: ViewModifier {
    @ObservedObject var model: AppModel

    @Environment(\.displayScale) private var displayScale
    @State private var lastPan: CGSize = .zero
    @State private var lastZoom: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear {
                        model.layout.paneSize = g.size
                        model.layout.scale = displayScale
                    }
                    .onChange(of: g.size) { _, s in
                        model.layout.paneSize = s
                        model.scheduleResolutionUpgrade()   // 去抖后按新尺寸重新解码
                    }
                    .onChange(of: displayScale) { _, sc in
                        model.layout.scale = sc
                        model.scheduleResolutionUpgrade()
                    }
            })
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        guard model.zoom > 1 else { return }
                        model.pan = CGSize(width: v.translation.width + lastPan.width,
                                           height: v.translation.height + lastPan.height)
                        model.clampPan()
                    }
                    .onEnded { _ in lastPan = model.pan }
            )
            .gesture(
                MagnifyGesture()
                    .onChanged { v in model.setZoom(lastZoom * v.magnification) }
                    .onEnded { _ in lastZoom = model.zoom }
            )
            .onTapGesture(count: 2) {
                model.setZoom(model.zoom > 1.02 ? 1 : 4)
                lastZoom = model.zoom
                if model.zoom <= 1.02 { model.pan = .zero; lastPan = .zero }
            }
    }
}
