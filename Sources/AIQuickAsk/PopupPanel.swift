import AppKit
import SwiftUI
import Combine

/// 窗口拖动手柄：铺在顶部输入栏的背景层。
/// 空白处按下即调用 window.performDrag 拖动窗口；
/// 输入框 / 按钮等交互控件位于前景，正常接收点击与文本操作，互不干扰。
/// （不能用 isMovableByWindowBackground：它会劫持整个窗口的按下拖动手势，
///   导致消息区文字无法选取复制。）
final class WindowDragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// SwiftUI 侧的拖动手柄（NSViewRepresentable 包装）。
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragHandleView { WindowDragHandleView() }
    func updateNSView(_ nsView: WindowDragHandleView, context: Context) {}
}

/// 无边框浮动面板（类 Spotlight），承载 ContentView，按状态在「输入态/输出态」之间自动伸缩。
final class PopupPanel: NSPanel {
    static let width: CGFloat = 968
    static let collapsedHeight: CGFloat = 92
    static let expandedHeight: CGFloat = 691
    /// 内嵌网页展开时的面板高度（webview 需要足够浏览区域；超屏时自动收敛）。
    static let browserHeight: CGFloat = 864

    var onClose: (() -> Void)?

    /// 无边框面板默认不能成为 key window，这里强制允许，否则输入框无法接收键盘输入。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private let viewModel: ChatViewModel
    /// 承载内容的 hosting view。
    /// 注意：必须用 NSHostingView 默认实现，不要强制 mouseDownCanMoveWindow = true——
    /// 强制 true 会把对文本的按下拖动全部变成移动窗口，导致文字无法选取复制。
    /// 默认实现下：空白背景（isMovableByWindowBackground）仍可拖动，文本区域正常选取。
    private let host: NSHostingView<ContentView>
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel

        let content = ContentView(viewModel: viewModel) {
            // Esc 关闭 → 交由 AppDelegate 处理
            NotificationCenter.default.post(name: .panelCloseRequested, object: nil)
        }
        host = NSHostingView(rootView: content)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.collapsedHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // 无边框窗口 isOpaque=false 时，系统阴影会贴合实际内容（玻璃圆角）的 alpha 轮廓
        hasShadow = true
        // 不置顶：作为普通窗口层级，切换/点击其他应用时会被正常盖住，双击右 Command 再唤回
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
        // 不开启 isMovableByWindowBackground：它会把文本选取手势当成窗口拖动。
        // 改由顶部输入栏背景层的 WindowDragHandle 负责拖动窗口（见 WindowDragHandleView）。

        // 确保承载 SwiftUI 的 NSHostingView 本身透明，否则会挡住后面的玻璃模糊
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.autoresizingMask = [.width, .height]

        // macOS 26 液态玻璃：用 AppKit 原生 NSGlassEffectView 作为窗口背景，SwiftUI 内容嵌入其中
        let glass = NSGlassEffectView()
        glass.cornerRadius = 28
        glass.style = .regular
        glass.clipsToBounds = true
        glass.contentView = host

        contentView = glass

        // 观察状态变化，自动在「输入态/对话态/网页态」之间伸缩（顶部固定、向下展开）。
        // combineLatest 最多接受四个发布者，更多只能嵌套 —— 待办相关的三个状态
        // （确认卡、提示条、忙标记）与内嵌网页开关都必须纳入，否则点开网页时窗口不会跟着长高。
        viewModel.$isStreaming
            .combineLatest(viewModel.$messages)
            .combineLatest(viewModel.$errorMessage)
            .combineLatest(viewModel.$todoComposerVisible)
            .combineLatest(viewModel.$todoStatus)
            .combineLatest(viewModel.$isParsingTodo)
            .combineLatest(viewModel.$isCreatingTodo)
            .combineLatest(viewModel.$browserActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSize() }
            .store(in: &cancellables)
    }

    // MARK: - 显示 / 隐藏

    func show() {
        positionForShow()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.requestFocus()
        }
    }

    func hide() {
        orderOut(nil)
    }

    /// 已打开（visible）时把面板调整到顶层并聚焦输入框，不重新定位、不关闭。
    /// 用于面板被其他窗口盖住后，双击右 Command 把它拉回最前。
    func bringToFront() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.requestFocus()
        }
    }

    // MARK: - 尺寸

    private func refreshSize() {
        let shouldExpand = viewModel.isStreaming
            || !viewModel.messages.isEmpty
            || viewModel.errorMessage != nil
            || viewModel.todoComposerVisible
            || viewModel.todoStatus != nil
            || viewModel.isTodoBusy
        // 内嵌网页态优先级最高（覆盖消息列表，需要更高的浏览区域）；
        // 目标高度不超过屏幕可见高度 - 160（顶部定位固定，防止底部出屏）。
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 160
        let base = viewModel.browserActive
            ? Self.browserHeight
            : (shouldExpand ? Self.expandedHeight : Self.collapsedHeight)
        let target = min(base, maxH)
        guard abs(target - frame.height) > 1 else { return }

        let top = frame.maxY
        var newFrame = frame
        newFrame.size.height = target
        newFrame.origin.y = top - target
        setFrame(newFrame, display: true, animate: true)
    }

    private func positionForShow() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        // 面板顶部固定在屏幕顶部下方约 120pt，类似 Spotlight
        let top = visible.maxY - 120
        setFrameOrigin(NSPoint(x: x, y: top - frame.height))
    }
}

extension Notification.Name {
    static let panelCloseRequested = Notification.Name("panelCloseRequested")
}
