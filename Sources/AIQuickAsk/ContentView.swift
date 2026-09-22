import SwiftUI
import AppKit

// MARK: - Glass 视觉元素

// MARK: - 主视图

/// 面板主视图：液玻璃容器。顶部输入胶囊，下方多轮对话消息流或内嵌网页；
/// 加载中（等模型回复 / 网页加载）由窗口边缘流光统一指示。
struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    var onClose: () -> Void

    @FocusState private var inputFocused: Bool
    @ObservedObject private var browser = BrowserState.shared
    /// 只挂不读：让本视图（及其整棵子树）在语言切换时重绘。
    /// 文案取值的 `L10n.t(...)` 是静态调用，SwiftUI 无法自行建立依赖，
    /// 必须靠持有这个 `ObservableObject` 才能收到 objectWillChange。
    @ObservedObject private var l10n = L10n.shared
    private let bottomID = "message-list-bottom"

    private var showsList: Bool {
        !viewModel.messages.isEmpty || viewModel.errorMessage != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputBar
            todoStatusBar
            todoComposer
            if viewModel.browserActive {
                browserSection
            } else if showsList {
                Divider()
                    .overlay(Color.white.opacity(0.25))
                messageList
            }
        }
        .frame(width: PopupPanel.width)
        .overlay(edgeGlow)
        .onExitCommand(perform: exitCommand)
        .onAppear { inputFocused = true }
        .onChange(of: viewModel.focusRequest) { inputFocused = true }
        .background(googleSearchShortcut)
    }

    // MARK: - 边缘流光（全局 loading 指示）

    /// 任意加载中：等大模型回复（思考/生成）、内嵌网页加载。
    private var isAnyLoading: Bool {
        viewModel.isStreaming || (viewModel.browserActive && browser.isLoading)
    }

    /// 窗口边缘的流光效果（对齐设计稿 flow-line.svg）：
    /// 主体 2pt 细线 + 半球水滴头 3pt（圆帽）+ 线性收细至 0.1pt 发丝尾；
    /// 光晕贴线 50% → 外缘 0%（两层宽度模拟垂直衰减），头部仅比水滴头大 1pt、
    /// 向后过渡到两侧各 5pt，尾部按设计稿在最后 35% 收敛消失。
    /// 色带沿彗星长度分布：头粉 → 尾黄（七段色谱插值）。
    /// 实现注记（2026-09-21 抓屏二分定位）：NSGlassEffectView 的 vibrancy 环境里
    /// 渐变掺任何透明色都会渲染异常 —— 故分段 trim + 逐段纯色（色谱插值）+ Shape 级
    /// opacity。40 段 × 3 层 @30fps，只在加载期间存在，空闲时零开销。
    private var edgeGlow: some View {
        ZStack {
            if isAnyLoading {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    comet(phase: (t / Self.cometPeriod).truncatingRemainder(dividingBy: 1))
                }
                .padding(3)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isAnyLoading)
        .allowsHitTesting(false)
    }

    private var ringShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 25, style: .continuous)
    }

    /// 彗星占周长比例（头在 phase + length 端，沿路径方向领先）。
    /// 2026-09-22：0.42 → 0.546（+30%）。取值恒 < 1，彗星不会与自身重叠，
    /// 跨接缝时 segmentsCovering 的 (a,1)+(0,b-1) / 平移两条分支均已覆盖。
    private static let cometLength = 0.546
    /// 彗星顺时针绕周长一圈的周期（秒）。
    /// 2026-09-22：3.0 → 3.0/0.7 ≈ 4.286，角速度 ×0.7（转速降低 30%）。
    private static let cometPeriod: Double = 3.0 / 0.7
    /// 彗星分段数：段内纯色插值，段间衔接成视觉连续渐变。
    /// 2026-09-21 修复「线上串珠」：内部接缝必须用 .butt 平帽 —— .round 帽越过段端点
    /// 与相邻段重叠，半透明光晕在重叠区 alpha 翻倍，尾部只剩 40 个接缝亮点超过
    /// vibrancy 可见阈值，看起来就是等距圆点。仅头部第一段保留 .round 补水滴头。
    private static let cometSegments = 40

    /// 设计稿色谱（头 → 尾）：#ff4d94 → #e14dff → #9d6bff → #4d9fff → #35e0e8 → #63f0b8 → #ffd166。
    private static let cometPalette: [(Double, (Double, Double, Double))] = [
        (0.00, (1.00, 0.30, 0.58)),
        (0.17, (0.88, 0.30, 1.00)),
        (0.34, (0.62, 0.42, 1.00)),
        (0.51, (0.30, 0.62, 1.00)),
        (0.68, (0.21, 0.88, 0.91)),
        (0.85, (0.39, 0.94, 0.72)),
        (1.00, (1.00, 0.82, 0.40)),
    ]

    /// 色谱插值（u ∈ 0~1，0=彗头 1=彗尾）。
    private static func paletteColor(at u: Double) -> Color {
        let clamped = min(max(u, 0), 1)
        for i in 0..<cometPalette.count - 1 {
            let (p0, c0) = cometPalette[i]
            let (p1, c1) = cometPalette[i + 1]
            if clamped <= p1 {
                let f = (clamped - p0) / (p1 - p0)
                return Color(
                    red: c0.0 + (c1.0 - c0.0) * f,
                    green: c0.1 + (c1.1 - c0.1) * f,
                    blue: c0.2 + (c1.2 - c0.2) * f
                )
            }
        }
        if let last = cometPalette.last { return Color(red: last.1.0, green: last.1.1, blue: last.1.2) }
        return .blue
    }

    /// 主体线宽：水滴头 3pt（圆帽补出半球）→ 2pt 线身 → 线性收细至 0.1pt 发丝尾。
    private static func bodyWidth(at u: Double) -> CGFloat {
        if u < 0.06 { return 3.0 - (u / 0.06) }          // 3 → 2
        let v = (u - 0.06) / 0.94
        return 2.0 - 1.9 * v                              // 2 → 0.1
    }

    /// 光晕总宽：头部仅比水滴头大 1pt（5pt）→ 前 15% 过渡到 10pt（两侧各 5pt）。
    private static func glowWidth(at u: Double) -> CGFloat {
        u < 0.15 ? 5.0 + (u / 0.15) * 5.0 : 10.0
    }

    /// 光晕沿彗星长度的衰减（对齐设计稿 tailFade：65% 前全亮，尾端收敛到 0）。
    private static func glowTailFade(at u: Double) -> Double {
        u < 0.65 ? 1.0 : max(0, 1 - (u - 0.65) / 0.35)
    }

    /// 彗星本体：头在 phase + length 端（沿路径方向领先），从头部往尾部铺段。
    /// 每段三层：主线（近不透明）+ 光晕内层 + 光晕外层，模拟贴线 50% → 外缘 0% 的垂直衰减。
    private func comet(phase: Double) -> some View {
        let length = Self.cometLength
        let count = Self.cometSegments
        let headPos = phase + length
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                let u0 = Double(i) / Double(count)               // 靠头端 0
                let u1 = Double(i + 1) / Double(count)           // 靠尾端 1
                let uMid = (u0 + u1) / 2
                let width = Self.bodyWidth(at: uMid)
                let color = Self.paletteColor(at: uMid)
                let glowW = Self.glowWidth(at: uMid)
                let fade = Self.glowTailFade(at: uMid)
                let cap: CGLineCap = i == 0 ? .round : .butt
                // 段的路径坐标（从头往尾递减），保证 trim from<to
                let s1 = headPos - u0 * length
                let s0 = headPos - u1 * length
                ForEach(Array(segmentsCovering(s0, s1).enumerated()), id: \.offset) { _, seg in
                    ringShape.trim(from: seg.0, to: seg.1)
                        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: cap))
                        .opacity(0.96)
                    ringShape.trim(from: seg.0, to: seg.1)
                        .stroke(color, style: StrokeStyle(lineWidth: glowW * 0.55, lineCap: cap))
                        .opacity(0.45 * fade)
                    ringShape.trim(from: seg.0, to: seg.1)
                        .stroke(color, style: StrokeStyle(lineWidth: glowW, lineCap: cap))
                        .opacity(0.22 * fade)
                }
            }
        }
    }

    /// [a, b]（周长比例）映射到 0/1 接缝两侧。三种情况：
    /// - b ≤ 1：不跨缝，原样；
    /// - a ≥ 1（彗头深过接缝，整段在缝后）：整体平移 [a-1, b-1]。
    ///   2026-09-21 修复右边缘亮斑+断档：旧逻辑只判 b > 1 就拆 (a,1)+(0,b-1)，
    ///   a > 1 时 (a,1) 是 from>to 的非法 trim，且 (0,b-1) 多画 [0,a-1]、
    ///   十几段光晕在缝前叠 alpha 成过亮条带，中段颜色错位成断档。
    /// - 其余（a < 1 < b）：拆 (a,1) + (0,b-1)。
    private func segmentsCovering(_ a: Double, _ b: Double) -> [(Double, Double)] {
        if b <= 1 { return [(a, b)] }
        if a >= 1 { return [(a - 1, b - 1)] }
        return [(a, 1.0), (0.0, b - 1.0)]
    }

    /// Esc：看网页时先收起网页回到对话，再按一次才关闭面板。
    private func exitCommand() {
        if viewModel.browserActive {
            viewModel.closeBrowser()
        } else {
            onClose()
        }
    }

    /// ⌘+Enter：Google 搜索当前输入（不调用 AI），在主面板内嵌网页打开（面板保持展开）。
    /// 隐藏按钮仅承载快捷键，带 ⌘ 修饰的回车作为 key equivalent 会优先于输入框的普通回车（onSubmit）被捕获。
    private var googleSearchShortcut: some View {
        Button {
            viewModel.searchOnWeb()
        } label: {
            EmptyView()
        }
        .keyboardShortcut("\r", modifiers: [.command])
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .disabled(viewModel.isStreaming)
    }

    // MARK: - 内嵌浏览器

    /// 内嵌网页区：工具栏（前进/后退/safari 外跳/收起）+ webview。
    /// 无地址栏、无进度条 —— 加载状态由窗口边缘流光统一指示。
    private var browserSection: some View {
        VStack(spacing: 0) {
            browserToolbar
            BrowserEmbedView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 14) {
            browserToolButton("chevron.left", enabled: browser.canGoBack, help: L10n.t(.browserBackHelp)) {
                EmbeddedBrowserController.shared.goBack()
            }
            .keyboardShortcut("[", modifiers: [.command])

            browserToolButton("chevron.right", enabled: browser.canGoForward, help: L10n.t(.browserForwardHelp)) {
                EmbeddedBrowserController.shared.goForward()
            }
            .keyboardShortcut("]", modifiers: [.command])

            Spacer()

            browserToolButton("safari", enabled: true, help: L10n.t(.browserOpenExternalHelp)) {
                EmbeddedBrowserController.shared.openInDefaultBrowser()
            }

            browserToolButton("xmark.circle.fill", enabled: true, help: L10n.t(.browserCloseHelp)) {
                viewModel.closeBrowser()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Color.primary.opacity(0.04))
    }

    private func browserToolButton(_ symbol: String, enabled: Bool, help: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .onHover { inside in
            if enabled { inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }

    // MARK: - 输入胶囊

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)

            searchToggle

            thinkingToggle

            todoShortcutButton

            TextField(L10n.t(.inputPlaceholder), text: $viewModel.input)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onSubmit { viewModel.submit() }
                .focused($inputFocused)
                .disabled(viewModel.isStreaming)

            if !viewModel.messages.isEmpty && !viewModel.isStreaming {
                clearButton
            }

            if viewModel.isStreaming {
                Button(L10n.t(.buttonStop)) { viewModel.cancel() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else {
                Button(L10n.t(.buttonSend)) { viewModel.submit() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .help(L10n.t(.sendHelp))
            }

            closeButton
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.7)
                )
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // 顶部栏空白处拖动窗口（手柄在背景层，输入框/按钮等前景控件不受影响）
        .background(WindowDragHandle())
    }

    /// 联网搜索开关（会话级，默认关闭）：开启时强制联网搜索，关闭时纯 LLM；仅影响当前对话，不写系统设置。
    /// 注意：关闭态用 network.slash —— SF Symbols 里不存在 globe.slash（渲染成空白，按钮会"消失"）。
    private var searchToggle: some View {
        Button {
            viewModel.searchEnabled.toggle()
        } label: {
            Image(systemName: viewModel.searchEnabled ? "globe" : "network.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(viewModel.searchEnabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command]) // ⌘S 切换联网搜索
        .help(viewModel.searchEnabled ? L10n.t(.searchOnHelp) : L10n.t(.searchOffHelp))
    }

    /// 思考模式开关（会话级，默认取设置页配置）。
    /// 开启时发送 `thinking.type=enabled` 与 `reasoning_effort`（DeepSeek 端点）；关闭走非思考模式，首字更快。
    /// 仅影响当前对话，不写系统设置；非 DeepSeek 端点下 `thinking` 字段不会被发送，故开关置灰。
    private var thinkingToggle: some View {
        let applicable = Config.isDeepSeekEndpoint
        return Button {
            viewModel.thinkingEnabled.toggle()
        } label: {
            Image(systemName: viewModel.thinkingEnabled ? "brain.fill" : "brain")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(viewModel.thinkingEnabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("t", modifiers: [.command]) // ⌘T 切换思考模式
        .disabled(!applicable)
        .opacity(applicable ? 1 : 0.4)
        .help(thinkingHelp(applicable: applicable))
    }

    /// 思考模式开关的悬浮说明。非 DeepSeek 端点时明确告知开关不生效，避免出现"点了没反应"的静默失效。
    ///
    /// 注意：这里一律走 `L10n.t(键, 参数)` 的格式化通路，**不用 Swift 字符串插值** ——
    /// Swift 词法分析会把全角 `（`/`）` 与插值括号计入同一层嵌套，一旦出现「全角 `（` 在前、
    /// 插值内的文本含全角 `）`」的组合，全角 `）` 会提前闭合插值，报 "unterminated string literal"。
    private func thinkingHelp(applicable: Bool) -> String {
        guard applicable else { return L10n.t(.thinkingDisabledHelp) }
        guard viewModel.thinkingEnabled else { return L10n.t(.thinkingOffHelp) }
        return L10n.t(.thinkingOnHelp, Config.reasoningEffortName)
    }

    /// 「存为待办」的入口按钮：一键把前缀塞进输入框，省得记记号。
    /// 与联网搜索 / 思考模式那两个开关不同，它不带任何状态 —— 只做一次文本插入。
    private var todoShortcutButton: some View {
        let enabled = Config.todoPrefixEnabled
        return Button {
            let prefix = Config.todoPrefix + " "
            guard !viewModel.input.hasPrefix(prefix) else { return }
            viewModel.input = prefix + viewModel.input
        } label: {
            Image(systemName: "checklist")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || viewModel.isStreaming)
        .help(enabled
              ? L10n.t(.todoShortcutOnHelp, Config.todoPrefix)
              : L10n.t(.todoShortcutOffHelp))
    }

    // MARK: - 待办：结果提示条

    /// 创建结果提示条（成功可撤销 / 失败给原因）。挂在消息列表之外，始终可见。
    @ViewBuilder
    private var todoStatusBar: some View {
        if let status = viewModel.todoStatus {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(status.isError ? Color.orange : Color.accentColor)
                Text(status.text)
                    .font(.system(size: 12))
                    .foregroundStyle(status.isError ? Color.primary : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if status.undoID != nil {
                    Button(L10n.t(.buttonUndo)) { viewModel.undoTodo() }
                        .buttonStyle(.glass)
                        .controlSize(.mini)
                }
                Button {
                    viewModel.dismissTodoStatus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.t(.todoStatusDismissHelp))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - 待办：确认卡

    /// 下游清单的可选项。
    /// 必须把「已选中但不在列表里」的值补进来 —— 否则 Picker 的 selection 指向一个不存在的
    /// tag，界面会静默显示成空白，看起来像坏了。
    private var reminderListOptions: [String] {
        var names = RemindersStore.shared.listNames
        let current = viewModel.todoListName
        if !current.isEmpty && !names.contains(current) { names.insert(current, at: 0) }
        return names.isEmpty ? [L10n.t(.todoDefaultListName)] : names
    }

    /// 提前提醒的可选档位。`nil` 在数据层与 0 等价，这里统一以 0 呈现。
    /// 档位名走本地化，但**数值一律是分钟**，不随语言变化。
    private var reminderOffsetOptions: [(name: String, value: Int)] {
        [
            (L10n.t(.reminderOffsetAtTime), 0),
            (L10n.t(.reminderOffset5), 5),
            (L10n.t(.reminderOffset15), 15),
            (L10n.t(.reminderOffset30), 30),
            (L10n.t(.reminderOffset60), 60),
            (L10n.t(.reminderOffset1440), 1440)
        ]
    }

    /// 待办确认卡：模型抽取结果的落点，也是用户纠错的地方。
    /// 所有字段都经 Binding 落到 `viewModel.todoDraft`（视图层不能用 @State）。
    @ViewBuilder
    private var todoComposer: some View {
        if viewModel.todoComposerVisible {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(L10n.t(.todoCardTitle))
                        .font(.system(size: 13, weight: .medium))
                    if viewModel.isCreatingTodo {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Picker("", selection: $viewModel.todoListName) {
                        ForEach(reminderListOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                TextField(L10n.t(.todoTitlePlaceholder), text: $viewModel.todoDraft.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))

                HStack(spacing: 14) {
                    Toggle(L10n.t(.todoDueDateToggle), isOn: Binding(
                        get: { viewModel.todoHasDueDate },
                        set: { viewModel.todoHasDueDate = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                    if viewModel.todoHasDueDate {
                        DatePicker("", selection: Binding(
                            get: { viewModel.todoDueDateValue },
                            set: { viewModel.todoDueDateValue = $0 }
                        ), displayedComponents: .date)
                        .labelsHidden()

                        Toggle(L10n.t(.todoHasTimeToggle), isOn: Binding(
                            get: { viewModel.todoHasTime },
                            set: { viewModel.todoHasTime = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))

                        if viewModel.todoHasTime {
                            DatePicker("", selection: Binding(
                                get: { viewModel.todoDueTimeValue },
                                set: { viewModel.todoDueTimeValue = $0 }
                            ), displayedComponents: .hourAndMinute)
                            .labelsHidden()

                            Picker("", selection: Binding(
                                get: { viewModel.todoDraft.reminderOffsetMinutes ?? 0 },
                                set: { viewModel.todoDraft.reminderOffsetMinutes = $0 }
                            )) {
                                ForEach(reminderOffsetOptions, id: \.value) { option in
                                    Text(option.name).tag(option.value)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Text(L10n.t(.todoRepeatLabel))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.todoDraft.repeatRule) {
                            ForEach(TodoRepeat.options, id: \.self) { value in
                                Text(TodoRepeat.displayName(value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    HStack(spacing: 6) {
                        Text(L10n.t(.todoPriorityLabel))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.todoDraft.priority) {
                            ForEach(TodoPriority.options, id: \.self) { value in
                                Text(TodoPriority.displayName(value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                    }
                    Spacer()
                    Button(L10n.t(.buttonCancel)) { viewModel.cancelTodo() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Button(L10n.t(.buttonAdd)) { viewModel.confirmTodo() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .disabled(viewModel.isCreatingTodo
                                  || viewModel.todoDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.7)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var clearButton: some View {
        Button { viewModel.clearConversation() } label: {
            Image(systemName: "trash")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(L10n.t(.clearHelp))
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("w", modifiers: [.command])
        .help(L10n.t(.closeHelp))
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.messages) { msg in
                        MessageRow(
                            message: msg,
                            isSearching: viewModel.isSearching,
                            isThinking: viewModel.thinkingEnabled,
                            onToggleSources: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    viewModel.toggleSourcesExpanded(id: msg.id)
                                }
                            },
                            onOpenSource: { urlString in
                                if let url = URL(string: urlString) {
                                    viewModel.openInBrowser(url: url)
                                }
                            },
                            onSaveAsTodo: { viewModel.saveAnswerAsTodo(messageID: msg.id) }
                        )
                    }
                    if let err = viewModel.errorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 跟随滚动：仅当用户当前位于底部附近时才跟随新内容；
            // 用户主动上翻（浏览历史）则停止拽底，直到发出新问题（shouldForceNextScroll）。
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 24
            } action: { _, atBottom in
                viewModel.isAtBottom = atBottom
            }
            .onChange(of: viewModel.scrollVersion) {
                if viewModel.messages.isEmpty { viewModel.isAtBottom = true; return }
                guard viewModel.shouldForceNextScroll || viewModel.isAtBottom else { return }
                viewModel.shouldForceNextScroll = false
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - 单条消息

/// 用户消息（右对齐气泡）与助手消息（左对齐纯文本）的展示。
/// 推理过程（reasoning_content）已不在界面展示：思考模式只影响 API 行为，
/// 回答只呈现最终正文（2026-09-21 产品决定）。
private struct MessageRow: View {
    let message: ChatMessage
    let isSearching: Bool
    /// 本轮是否启用思考模式：关闭时等待文案用「生成中…」，因为确实不会有思考过程推送。
    let isThinking: Bool
    /// 切换「参考来源」列表的展开状态（由 ContentView 回传消息 id）。
    let onToggleSources: () -> Void
    /// 打开某条参考来源（由 ContentView 回传 → 主面板内嵌网页）。
    let onOpenSource: (String) -> Void
    /// 把这条回答存为待办（由 ContentView 回传消息 id）。
    let onSaveAsTodo: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantRow
        }
    }

    /// 等待首字期间的占位文案：联网搜索 > 思考模式 > 普通生成，三者互斥。
    private var waitingText: String {
        if isSearching { return L10n.t(.waitingSearching) }
        return isThinking ? L10n.t(.waitingThinking) : L10n.t(.waitingGenerating)
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.content)
                .font(.system(size: 14))
                .lineSpacing(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(.primary)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.7)
                        )
                )
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantRow: some View {
        Group {
            if message.isStreaming && message.content.isEmpty && message.reasoning.isEmpty {
                // 还没有任何输出（等待首字）：加载动效由窗口边缘流光承担，这里只留一行状态文字
                Text(waitingText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !message.content.isEmpty {
                        if message.isStreaming {
                            // 流式期间用纯文本渲染（性能：避免每个 delta 触发全文 Markdown 重解析 + AttributedString 全量重建），
                            // 回答结束后一次性切换为 Markdown 排版。
                            Text(message.content)
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        } else {
                            MarkdownView(text: message.content)
                        }
                    }
                    if message.isStreaming && !message.content.isEmpty {
                        Text("▍")
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 4)
                    }
                    if !message.sources.isEmpty && !message.isStreaming {
                        SourceList(
                            sources: message.sources,
                            isExpanded: message.isSourcesExpanded,
                            onToggle: onToggleSources,
                            onOpen: onOpenSource
                        )
                    }
                    if showsSaveAsTodo {
                        saveAsTodoButton
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「存为待办」按钮的显示条件：回答已结束、不是「已停止／无返回内容」这类占位、
    /// 确实有正文，且用户没在设置里关掉它。
    /// 注意必须排除 `isPlaceholder` —— 把「（已停止）」存成待办毫无意义。
    private var showsSaveAsTodo: Bool {
        Config.todoShowAnswerButton
            && !message.isStreaming
            && !message.isPlaceholder
            && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var saveAsTodoButton: some View {
        Button(action: onSaveAsTodo) {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                Text(L10n.t(.saveAsTodo))
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help(L10n.t(.saveAsTodoHelp))
    }
}

// MARK: - 参考来源

/// 回答末尾的联网搜索来源列表（可点击打开）。
/// 默认折叠为一行标题，点击标题才展开条目 ——
/// 来源条目通常 3~5 条且标题很长，常驻展示会把回答正文挤得很散。
private struct SourceList: View {
    let sources: [SourceItem]
    let isExpanded: Bool
    let onToggle: () -> Void
    /// 打开某条来源（由 ContentView 回传 URL 字符串 → 主面板内嵌网页）。
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(L10n.t(.sourcesTitle))
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n.count(.sourcesCountOne, .sourcesCountOther, sources.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? L10n.t(.sourcesCollapseHelp) : L10n.t(.sourcesExpandHelp))
            .onHover { inside in
                inside ? NSCursor.pointingHand.push() : NSCursor.pop()
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { idx, item in
                        Button {
                            onOpen(item.url)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(idx + 1).")
                                    .foregroundStyle(.tertiary)
                                Text(item.title)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundStyle(Color.accentColor)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.title + "\n" + item.url)
                        .onHover { inside in
                            inside ? NSCursor.pointingHand.push() : NSCursor.pop()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }
        }
        .padding(.top, 10)
    }
}
