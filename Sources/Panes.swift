import SwiftUI
import AppKit
import CoreGraphics

/// 渲染画布。用 CALayer 承载 CGImage，缩放平移交给 GPU，缩放到 100% 依然清晰。
final class CanvasNSView: NSView {
    private let layerA = CALayer()
    private let layerB = CALayer()

    var imageA: CGImage? { didSet { layerA.contents = imageA; needsLayout = true } }
    var imageB: CGImage? { didSet { layerB.contents = imageB; needsLayout = true } }

    /// B 图不透明度，用于闪烁/叠加
    var blend: CGFloat = 0 {
        didSet { CATransaction.begin(); CATransaction.setDisableActions(true)
                 layerB.opacity = Float(blend); CATransaction.commit() }
    }
    var showA: Bool = true {
        didSet { CATransaction.begin(); CATransaction.setDisableActions(true)
                 layerA.isHidden = !showA; CATransaction.commit() }
    }
    var showB: Bool = false {
        didSet { CATransaction.begin(); CATransaction.setDisableActions(true)
                 layerB.isHidden = !showB; CATransaction.commit() }
    }

    /// 1 = 适应窗口
    var zoom: CGFloat = 1 { didSet { needsLayout = true } }
    var pan: CGSize = .zero { didSet { needsLayout = true } }

    /// Ctrl + 滚轮缩放的回调：(缩放倍率, 光标在视图内的位置)。
    ///
    /// 只传倍率和锚点，**不在这里算新 zoom** —— 视图的 zoom 是 SwiftUI 传下来的副本，
    /// 事件密集时会滞后；拿它当基准会让倍率被"吃掉"，缩放到一半就卡住。
    /// 真正的缩放值由 model 这个唯一权威来算。
    var onCtrlScrollZoom: ((CGFloat, CGPoint) -> Void)?

    /// 不按 Ctrl 时用滚轮翻页：(+1 下一张 / -1 上一张)
    var onScrollStep: ((Int) -> Void)?

    /// 滚轮累计量。触控板一次滑动会产生很多小事件，必须累加到阈值才翻一张。
    private var scrollAccum: CGFloat = 0
    /// 传统滚轮：两次翻页之间的最小间隔（仅用于合并同一格的重复事件）
    private var lastStepTime: CFAbsoluteTime = 0
    /// 上一次收到滚动事件的时间，用于判断手势边界
    private var lastScrollTime: CFAbsoluteTime = 0

    /// 缩放手势作用于整个画布。Ctrl + 滚轮改由我们自己处理（以光标为锚点），
    /// 其余滚动手势交回系统。
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            handlePageScroll(event)
            return
        }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }

        // 每单位滚动量对应的倍率，并限制单次事件的幅度，避免一次跳太多
        let raw = pow(1.012, delta)
        let factor = min(max(raw, 0.80), 1.25)
        onCtrlScrollZoom?(factor, convert(event.locationInWindow, from: nil))
    }

    /// 普通滚轮翻页。
    ///
    /// 三类输入的语义差别很大，分开处理才稳定（这些数字是用探针实测出来的）：
    /// - **鼠标滚轮**：`hasPreciseScrollingDeltas == false`，一格一个事件 → 直接翻一张。
    ///   若也去累加，会变成"滚三格才动一下"。
    /// - **触控板**：`true`，一次滑动会拆成几十个小事件 → 累加到阈值才翻一张，
    ///   并且必须忽略滑动结束后的**惯性事件**，否则一次滑动能连翻好几张。
    /// - **合成/部分设备**：`momentumPhase` 与 `phase` 恒为 0，拿不到手势边界，
    ///   因此额外用"事件间隔"来判断是不是一次新手势，否则累加值会跨手势残留。
    private func handlePageScroll(_ event: NSEvent) {
        guard onScrollStep != nil else { return }
        guard event.momentumPhase == [] else { return }      // 惯性阶段不计
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastScrollTime > 0.25 { scrollAccum = 0 }   // 隔得久了，当作新手势
        lastScrollTime = now

        if !event.hasPreciseScrollingDeltas {
            // 传统滚轮：一格即一次翻页。
            // 间隔取得很短，只用来合并同一格里重复发出的事件；
            // 太长会把用户快速拨动的格子也吃掉，用起来就显得"迟钝"。
            guard now - lastStepTime > 0.02 else { return }
            lastStepTime = now
            onScrollStep?(dy < 0 ? 1 : -1)                   // 向下滚 → 下一张（同 PPT）
            return
        }

        // 平滑滚动设备（触控板 / 带平滑滚动的鼠标）：方向一变就重新计数，
        // 避免来回蹭时凑出意外的一步
        if (scrollAccum > 0 && dy < 0) || (scrollAccum < 0 && dy > 0) { scrollAccum = 0 }
        scrollAccum += dy

        // 一次事件顶多翻一张，超出部分留在累计里；阈值按设置取
        let threshold = ScrollSettings.shared.stepThreshold
        if scrollAccum <= -threshold {
            scrollAccum += threshold          // 减去而不是清零，大增量不会被吞掉
            onScrollStep?(1)
        } else if scrollAccum >= threshold {
            scrollAccum -= threshold
            onScrollStep?(-1)
        }
    }

    /// 计算「以 anchor 为锚点」缩放后的新平移量：让光标下的那个图像点在缩放前后停在原处。
    ///
    /// 抽成纯函数是为了能直接测试 —— 这段几何很容易写错，而肉眼很难判断锚点准不准。
    /// 坐标系：视图坐标，原点左下（AppKit 默认，本视图未翻转）。
    static func anchoredPan(currentZoom: CGFloat, newZoom: CGFloat, currentPan: CGSize,
                            anchor: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGSize {
        let iw = imageSize.width, ih = imageSize.height
        guard iw > 0, ih > 0, viewSize.width > 0, viewSize.height > 0 else { return currentPan }
        let fit = min(viewSize.width / iw, viewSize.height / ih)
        let ds = fit * currentZoom          // 缩放前：每图像像素占几个点
        let ds2 = fit * newZoom

        // 当前图层左上角在视图坐标里的位置
        let lx = (viewSize.width - iw * ds) / 2 + currentPan.width
        let ly = (viewSize.height - ih * ds) / 2 - currentPan.height

        // 锚点对应的图像坐标
        let ix = (anchor.x - lx) / ds
        let iy = (anchor.y - ly) / ds

        // 缩放后让同一个图像点仍然落在 anchor 上
        let lx2 = anchor.x - ix * ds2
        let ly2 = anchor.y - iy * ds2
        return CGSize(width: lx2 - (viewSize.width - iw * ds2) / 2,
                      height: (viewSize.height - ih * ds2) / 2 - ly2)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = CGColor(gray: 0.10, alpha: 1)
        for l in [layerA, layerB] {
            l.contentsGravity = .resize
            l.magnificationFilter = .linear
            l.minificationFilter = .trilinear
            l.isHidden = true
            layer?.addSublayer(l)
        }
        layerA.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 以当前实际存在的图确定参考尺寸
    private var referenceImage: CGImage? { imageA ?? imageB }

    override func layout() {
        super.layout()
        guard let img = referenceImage, bounds.width > 1, bounds.height > 1 else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layerA.frame = .zero; layerB.frame = .zero
            CATransaction.commit()
            return
        }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let vw = bounds.width, vh = bounds.height
        let fit = min(vw / iw, vh / ih)
        let ds = fit * zoom
        let dw = iw * ds, dh = ih * ds
        let x = (vw - dw) / 2 + pan.width
        // 视图未翻转（原点左下），拖拽向下为 pan.height > 0，因此 y 取负
        let y = (vh - dh) / 2 - pan.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let f = CGRect(x: x, y: y, width: dw, height: dh)
        layerA.frame = f
        layerB.frame = f
        CATransaction.commit()
    }
}

/// SwiftUI 包装
struct CanvasPane: NSViewRepresentable {
    var imageA: CGImage?
    var imageB: CGImage?
    var blend: CGFloat = 0
    var showA: Bool = true
    var showB: Bool = false
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// Ctrl + 滚轮缩放：(倍率, 锚点)
    var onCtrlScrollZoom: ((CGFloat, CGPoint) -> Void)? = nil
    /// 普通滚轮翻页：(+1 下一张 / -1 上一张)
    var onScrollStep: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> CanvasNSView { CanvasNSView(frame: .zero) }

    func updateNSView(_ v: CanvasNSView, context: Context) {
        v.onCtrlScrollZoom = onCtrlScrollZoom
        v.onScrollStep = onScrollStep
        if v.imageA !== imageA { v.imageA = imageA }
        if v.imageB !== imageB { v.imageB = imageB }
        v.blend = blend
        v.showA = showA
        v.showB = showB
        v.zoom = zoom
        v.pan = pan
    }
}

/// 画面标题条
struct PaneLabel: View {
    let title: String
    let subtitle: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
    }
}
