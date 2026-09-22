import Foundation
import AppKit
import Combine

/// 单条对话消息。
struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }

    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    /// 占位文案（「已停止」「无返回内容」）：仅 UI 展示，不进入发给 LLM 的历史上下文。
    var isPlaceholder: Bool
    /// 联网搜索来源（仅 assistant 消息，回答结束后填充）。
    var sources: [SourceItem]
    /// 思考过程（`reasoning_content`，仅 assistant 消息）。只用于界面展示，
    /// 绝不回填进后续请求 —— DeepSeek 要求不要把 reasoning 放回 messages。
    var reasoning: String
    /// 思考过程面板是否展开（仅 assistant 消息，回答结束后用户可手动切换）。
    var isReasoningExpanded: Bool
    /// 参考来源列表是否展开（仅 assistant 消息）。
    /// 默认折叠：来源条目数量多且长，常驻会挤占回答区的可读空间，
    /// 折叠成一行标题后既保留「有来源」的提示，也把版面还给正文。
    var isSourcesExpanded: Bool

    init(id: UUID = UUID(), role: Role, content: String, isStreaming: Bool = false, isPlaceholder: Bool = false, sources: [SourceItem] = [], reasoning: String = "", isReasoningExpanded: Bool = false, isSourcesExpanded: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.isPlaceholder = isPlaceholder
        self.sources = sources
        self.reasoning = reasoning
        self.isReasoningExpanded = isReasoningExpanded
        self.isSourcesExpanded = isSourcesExpanded
    }
}

/// 待办操作的结果提示（成功条 / 失败原因）。承载在输入栏下方的状态条里。
struct TodoStatus: Equatable {
    var text: String
    /// 失败用红色呈现，成功用次要色。
    var isError: Bool = false
    /// 非空表示这次创建可以撤销（值为提醒事项的标识）。
    var undoID: String? = nil
}

/// 问答状态与交互逻辑：支持多轮对话，面板打开期间连续追问，上下文累加。
final class ChatViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false
    /// 是否处于联网搜索阶段（区分“搜索中”与“思考中”占位文案）。
    @Published var isSearching: Bool = false
    /// 联网搜索开关（会话级）：仅作用于当前对话，默认关闭；开启时强制联网搜索，关闭时纯 LLM。
    @Published var searchEnabled: Bool = false
    /// 思考模式开关（会话级覆盖）：默认取设置页配置（`Config.thinkingEnabled`，默认开启）。
    /// 面板内可用 ⌘T 临时切换，用于对某个具体问题关掉思考换取速度；面板关闭时回落到设置页默认值。
    @Published var thinkingEnabled: Bool = Config.thinkingEnabled
    @Published var errorMessage: String?
    @Published var focusRequest: Int = 0
    /// 消息列表内容变化的版本号，用于驱动自动滚动到底部。
    @Published var scrollVersion: Int = 0

    // MARK: - 待办（写入系统「提醒事项」）

    /// 待确认的待办草稿（确认卡上可直接编辑）。
    @Published var todoDraft: TodoDraft = .empty
    /// 确认卡是否可见。
    @Published var todoComposerVisible: Bool = false
    /// 是否正在调模型抽取字段。
    @Published var isParsingTodo: Bool = false
    /// 是否正在写入提醒事项。
    @Published var isCreatingTodo: Bool = false
    /// 结果提示条（成功 / 失败 / 可撤销）。
    @Published var todoStatus: TodoStatus?
    /// 本次写入的目标清单（会话级）。空串表示跟随系统默认清单。
    @Published var todoListName: String = Config.todoDefaultList

    /// 是否有待办相关操作在进行（供面板决定是否展开、按钮是否禁用）。
    var isTodoBusy: Bool { isParsingTodo || isCreatingTodo }

    /// 当前滚动位置是否在消息列表底部附近（跟随滚动用：用户上翻即停止强制拽底）。
    /// 放在 VM 是因为 swiftc 直编不加载 SwiftUIMacros 宏插件，视图层无法用 @State。
    @Published var isAtBottom: Bool = true

    /// 下一次 scrollVersion 变化是否强制滚动到底（新问题发出时置位，配合视图层的 at-bottom 检测）。
    /// 流式期间若用户向上翻看（不在底部），不再强制拽回底部。
    var shouldForceNextScroll = false

    /// 本次请求待写入 assistant 消息的来源（搜索阶段暂存）。
    private var pendingSources: [SourceItem] = []

    // MARK: - 流式 delta 节流（80ms 合并刷新，避免逐分片触发 @Published 全量重渲染）
    // 思考过程与正文共用同一个节流窗口，保证两者按到达顺序写入、不互相插队。

    private var pendingDelta = ""
    private var pendingReasoning = ""
    private var flushScheduled = false
    private var lastFlushAt: TimeInterval = 0
    private static let flushInterval: TimeInterval = 0.08

    /// 提交当前问题（携带完整历史上下文，可选先联网搜索）。
    func submit() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming, !isTodoBusy else { return }

        // 正在看网页时提问：自动收起网页回到对话视图，回答的流式过程才可见
        closeBrowser()

        // 「#todo …」→ 转入待办录入，既不发给模型闲聊，也不进入多轮上下文
        // （待办指令混进对话历史会污染后续追问的语境）。
        if let body = Config.todoPrefixMatch(question) {
            input = ""
            if body.isEmpty {
                todoStatus = TodoStatus(
                    text: L10n.t(.todoPrefixBodyMissing, Config.todoPrefix),
                    isError: true
                )
                return
            }
            beginTodo(from: body)
            return
        }

        messages.append(ChatMessage(role: .user, content: question))
        messages.append(ChatMessage(role: .assistant, content: "", isStreaming: true))
        input = ""
        errorMessage = nil
        isStreaming = true
        isSearching = false
        pendingSources = []
        shouldForceNextScroll = true // 新问题发出：无论如何都先滚到底
        scrollVersion += 1

        // 开关开启 + 配了 Key → 强制联网搜索（用用户原始问题作为搜索词，不经 AI 意图判断）
        if searchEnabled && !Config.tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isSearching = true // 占位切到「正在联网搜索…」
            TavilyClient.shared.search(query: question) { [weak self] r in
                guard let self = self, self.isStreaming else { return }
                switch r {
                case .success(let search):
                    self.startLLM(search)
                case .failure:
                    self.startLLM(nil) // 搜索失败降级为纯 LLM，不打断
                }
            }
            return
        }

        // 开关关闭或未配置 Key → 直接纯 LLM
        startLLM(nil)
    }

    /// 发起 LLM 流式请求（按 DeepSeek 多轮对话文档：自带完整历史 + 头部注入 system）。
    /// - 首位可选 system：用户在设置页配置的助手人设（`Config.effectiveSystemPrompt`，
    ///   开关关闭或内容为空白时为 nil → 不发送）。
    /// - 次位 system：当前时间（总是注入）。模型自身没有时钟，不注入就只能用训练先验猜「今天」，
    ///   「昨天/最近」等相对时间会整体偏到错误的日期上。
    /// - 再下一位可选 system：搜索上下文（仅当本次有搜索时存在，不受人设开关影响）。
    /// - 之后：本轮及之前所有非空 user/assistant 历史（符合文档「无状态」要求）。
    ///
    /// system 消息统一置于 messages 开头：既是 Chat Completions 的角色顺序约定，
    /// 也让多轮请求能完整命中 DeepSeek 上下文硬盘缓存的「system + user」前缀单元。
    private func startLLM(_ search: TavilySearchResult?) {
        isSearching = false
        pendingSources = search?.items ?? []

        let lastUserText = messages.last(where: { $0.role == .user })?.content ?? ""

        var apiMessages: [[String: String]] = []
        if let persona = Config.effectiveSystemPrompt {
            apiMessages.append(["role": "system", "content": persona])
        }
        apiMessages.append([
            "role": "system",
            "content": Self.buildDatePrompt(precise: Self.needsPreciseTime(lastUserText))
        ])
        if let s = search {
            apiMessages.append(["role": "system", "content": Self.buildSearchPrompt(s)])
        }
        apiMessages.append(contentsOf: buildAPIMessages())

        LLMClient.shared.stream(
            messages: apiMessages,
            thinkingEnabled: thinkingEnabled,
            onReasoning: { [weak self] delta in self?.appendReasoning(delta) },
            onDelta: { [weak self] delta in self?.appendDelta(delta) },
            onDone: { [weak self] in self?.finishStreaming() },
            onError: { [weak self] msg in self?.failStreaming(msg) }
        )
    }

    /// 组装「当前时间」system 提示词。实现已迁到 `Prompts`（需按界面语言出不同文案），
    /// 此处保留薄转发是为了不打扰 `TodoParser` 与既有自检的调用点。
    /// - Parameter precise: 是否精确到分钟。只有「问当下具体时刻」的问题才置位——
    ///   时间串每次请求都会重新生成，粒度越细越容易让 DeepSeek 的前缀缓存失效，
    ///   而「昨天/最近/前几天」这类相对时间只需精确到「天」即可正确换算。
    static func buildDatePrompt(precise: Bool, now: Date = Date(),
                                language: ResolvedLanguage = L10n.shared.resolved) -> String {
        Prompts.datePrompt(precise: precise, now: now, language: language)
    }

    /// 判断问题是否在问「当下的具体时刻」。命中才注入到分钟的时间。
    /// 词表与匹配规则见 `Prompts.needsPreciseTime`（中英词表都查 —— 误命中的代价只是缓存，
    /// 漏命中的代价是答错时间）。
    static func needsPreciseTime(_ text: String) -> Bool {
        Prompts.needsPreciseTime(text)
    }

    /// 组装联网搜索的 system 提示词。实现已迁到 `Prompts`（需按界面语言出不同文案）。
    private static func buildSearchPrompt(_ search: TavilySearchResult) -> String {
        Prompts.searchContextPrompt(search)
    }

    /// 中途停止生成（保留已生成部分）。
    func cancel() {
        LLMClient.shared.cancel()
        TavilyClient.shared.cancel()
        pendingDeltaFlush() // 先把节流中的内容（含思考过程）落盘，再收尾
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
            // 主动停止时保留思考内容可见：流式期间面板是「强制展开」，收尾后若不置位会突然折叠
            messages[idx].isReasoningExpanded = true
            if messages[idx].content.isEmpty {
                messages[idx].content = L10n.t(.placeholderStopped)
                messages[idx].isPlaceholder = true
            }
        }
        isStreaming = false
        isSearching = false
        pendingSources = []
        scrollVersion += 1
    }

    /// 关闭面板时清空，下次弹出回到新对话。
    func reset() {
        LLMClient.shared.cancel()
        TavilyClient.shared.cancel()
        input = ""
        messages = []
        errorMessage = nil
        isStreaming = false
        isSearching = false
        searchEnabled = false // 会话级开关：关闭面板恢复默认关闭
        thinkingEnabled = Config.thinkingEnabled // 会话级覆盖：关闭面板回落到设置页默认值
        pendingSources = []
        pendingDelta = "" // 节流中的残留直接丢弃（对话已清空）
        pendingReasoning = ""
        flushScheduled = false
        isAtBottom = true
        // 待办状态一并归零：草稿与提示条属于「这一次面板会话」，关面板即作废；
        // 目标清单回落到设置页默认值（与 searchEnabled / thinkingEnabled 同一套会话级范式）。
        todoDraft = .empty
        todoComposerVisible = false
        isParsingTodo = false
        isCreatingTodo = false
        todoStatus = nil
        todoListName = Config.todoDefaultList
        // 内嵌网页一并收起销毁：关面板 = 整个会话作废，webview 不在后台常驻
        closeBrowser()
        scrollVersion += 1
    }

    /// 面板内手动清空对话历史。
    func clearConversation() {
        guard !isStreaming else { return }
        messages = []
        errorMessage = nil
        isAtBottom = true
        scrollVersion += 1
        // 网页开着时清空对话：一并收起网页，回到干净的输入态
        closeBrowser()
    }

    /// 触发输入框聚焦（面板每次弹出时调用）。
    func requestFocus() {
        focusRequest += 1
    }

    // MARK: - 内嵌浏览器

    /// 内嵌网页是否展开（展开时覆盖消息列表区域；webview 全新创建，关闭即销毁）。
    @Published var browserActive = false

    /// 在主面板内嵌 webview 中打开链接（⌘Enter 搜索 / 参考来源点击 / 菜单栏入口共用）。
    /// webview 可能尚未挂进视图树 —— 控制器先行创建持有，BrowserEmbedView 挂载时取同一实例。
    func openInBrowser(url: URL) {
        EmbeddedBrowserController.shared.load(url)
        browserActive = true
    }

    /// 收起内嵌网页并立即销毁 webview（页面内存随 WebContent 子进程退出释放）。
    func closeBrowser() {
        guard browserActive else { return }
        browserActive = false
        EmbeddedBrowserController.shared.teardown()
    }

    /// ⌘+Enter 触发：用 Google 搜索输入内容（不调用 AI），在主面板内嵌网页打开（面板不收起）。
    /// 返回是否已触发（有输入且空闲时才触发）。
    @discardableResult
    func searchOnWeb() -> Bool {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return false }

        var comps = URLComponents(string: "https://www.google.com/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = comps?.url else { return false }

        input = ""
        openInBrowser(url: url)
        return true
    }

    // MARK: - 待办：录入 / 确认 / 撤销

    /// 从输入框文本发起录入：先确保有写入权限（否则白跑一次模型），再抽取字段并弹出确认卡。
    private func beginTodo(from text: String) {
        todoStatus = nil
        prepareListName()
        withRemindersAccess { [weak self] in
            guard let self else { return }
            self.isParsingTodo = true
            TodoParser.parse(text: text) { [weak self] draft in
                guard let self else { return }
                self.isParsingTodo = false
                self.todoDraft = draft
                self.todoComposerVisible = true
                self.scrollVersion += 1
            }
        }
    }

    /// 把某条 AI 回答压缩成待办草稿。
    /// - Parameter messageID: 目标 assistant 消息。
    func saveAnswerAsTodo(messageID: UUID) {
        guard !isStreaming, !isTodoBusy else { return }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let answer = messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !messages[index].isPlaceholder, !answer.isEmpty else { return }

        // 往上找最近的一条用户消息作为来源问题，写进备注便于回溯「这是哪个问题的结论」
        var question = ""
        var cursor = index
        while cursor > 0 {
            cursor -= 1
            if messages[cursor].role == .user {
                question = messages[cursor].content
                break
            }
        }
        guard !question.isEmpty else { return }

        todoStatus = nil
        prepareListName()
        withRemindersAccess { [weak self] in
            guard let self else { return }
            self.isParsingTodo = true
            TodoParser.compress(question: question, answer: answer) { [weak self] draft in
                guard let self else { return }
                self.isParsingTodo = false
                self.todoDraft = draft
                self.todoComposerVisible = true
                self.scrollVersion += 1
            }
        }
    }

    /// 确认卡上的「添加」。
    func confirmTodo() {
        guard todoComposerVisible, !isCreatingTodo else { return }
        let draft = todoDraft
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            todoStatus = TodoStatus(text: L10n.t(.todoErrorTitleEmpty), isError: true)
            return
        }

        isCreatingTodo = true
        let target = todoListName
        RemindersStore.shared.create(draft, listName: target.isEmpty ? nil : target) { [weak self] result in
            guard let self else { return }
            self.isCreatingTodo = false
            switch result {
            case .success(let identifier):
                self.todoComposerVisible = false
                self.todoDraft = .empty
                self.todoStatus = TodoStatus(text: L10n.t(.todoAdded, draft.summary), undoID: identifier)
                self.scrollVersion += 1
            case .failure(let error):
                self.todoStatus = TodoStatus(text: Self.describe(error), isError: true)
            }
        }
    }

    /// 确认卡上的「取消」。
    func cancelTodo() {
        todoComposerVisible = false
        todoDraft = .empty
        todoStatus = nil
        isParsingTodo = false
        isCreatingTodo = false
    }

    /// 状态条上的「撤销」：删除刚刚创建的提醒事项。
    func undoTodo() {
        guard let identifier = todoStatus?.undoID else { return }
        let removed = RemindersStore.shared.remove(id: identifier)
        todoStatus = TodoStatus(
            text: removed ? L10n.t(.todoUndone) : L10n.t(.todoUndoFailed),
            isError: !removed
        )
    }

    /// 关闭结果提示条。
    func dismissTodoStatus() {
        todoStatus = nil
    }

    // MARK: - 待办：确认卡字段的编辑支撑
    //
    // 视图层禁用 @State（swiftc 直编不加载 SwiftUIMacros 宏插件），确认卡上的开关与选择
    // 一律经由这里的 Binding 落到 `todoDraft`。这些属性本身不必是 @Published ——
    // 它们的读写都会改动 `todoDraft`，由那个 @Published 触发重绘即可。

    /// 「设置截止日期」开关。关闭时连带清掉时刻与提前提醒，避免留下无落点的孤儿字段。
    var todoHasDueDate: Bool {
        get { todoDraft.dueDate != nil }
        set {
            if newValue {
                todoDraft.dueDate = todoDraft.dueDate ?? Calendar.current.startOfDay(for: Date())
            } else {
                todoDraft.dueDate = nil
                todoDraft.dueHour = nil
                todoDraft.dueMinute = nil
                todoDraft.reminderOffsetMinutes = nil
            }
        }
    }

    /// 「指定具体时刻」开关。开启时默认给 9:00，避免时刻默默落在 00:00。
    var todoHasTime: Bool {
        get { todoDraft.dueHour != nil }
        set {
            guard todoDraft.dueDate != nil else { return }
            if newValue {
                if todoDraft.dueHour == nil {
                    todoDraft.dueHour = 9
                    todoDraft.dueMinute = 0
                }
            } else {
                todoDraft.dueHour = nil
                todoDraft.dueMinute = nil
                todoDraft.reminderOffsetMinutes = nil
            }
        }
    }

    /// 截止日期（DatePicker 需要非可选 Date 的落点）。
    var todoDueDateValue: Date {
        get { todoDraft.dueDate ?? Calendar.current.startOfDay(for: Date()) }
        set { todoDraft.dueDate = newValue }
    }

    /// 截止时刻（DatePicker 用）。读取时拼上已选的日期，写入时只取时分。
    var todoDueTimeValue: Date {
        get {
            let day = Calendar.current.startOfDay(for: todoDraft.dueDate ?? Date())
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
            comps.hour = todoDraft.dueHour ?? 9
            comps.minute = todoDraft.dueMinute ?? 0
            return Calendar.current.date(from: comps) ?? day
        }
        set {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            todoDraft.dueHour = comps.hour
            todoDraft.dueMinute = comps.minute
        }
    }

    // MARK: - 待办：内部

    /// 统一处理「写待办必须先有权限」。权限不足时**不发起模型调用**，省一次无谓的往返。
    private func withRemindersAccess(_ work: @escaping () -> Void) {
        RemindersStore.shared.refreshStatus()
        if RemindersStore.shared.authState.isAuthorized {
            work()
            return
        }
        RemindersStore.shared.requestAccess { [weak self] granted in
            guard let self else { return }
            if granted {
                work()
            } else {
                self.todoStatus = TodoStatus(
                    text: L10n.t(.todoNeedPermission),
                    isError: true
                )
            }
        }
    }

    /// 决定本次写入的目标清单：用户配置优先，否则跟随系统默认清单。
    private func prepareListName() {
        let configured = Config.todoDefaultList.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            todoListName = configured
            return
        }
        todoListName = RemindersStore.shared.systemDefaultListName
            ?? RemindersStore.shared.listNames.first
            ?? ""
    }

    private static func describe(_ error: RemindersError) -> String {
        switch error {
        case .notAuthorized:
            return L10n.t(.todoNotAuthorized)
        case .message(let text):
            return L10n.t(.todoCreateFailed, text)
        }
    }

    // MARK: - 私有

    /// 切换某条消息的思考过程面板展开状态（回答结束后用户点击标题触发）。
    func toggleReasoningExpanded(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].isReasoningExpanded.toggle()
    }

    /// 切换某条消息的「参考来源」列表展开状态。
    /// 来源默认折叠（见 `ChatMessage.isSourcesExpanded`），此处只负责翻转，
    /// 展开/收起的过渡动画由调用方包在 `withAnimation` 里统一处理。
    func toggleSourcesExpanded(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].isSourcesExpanded.toggle()
    }

    private func appendDelta(_ delta: String) {
        pendingDelta += delta
        scheduleFlush()
    }

    /// 思考过程增量（`reasoning_content`）：与正文共用节流窗口。
    private func appendReasoning(_ delta: String) {
        pendingReasoning += delta
        scheduleFlush()
    }

    /// 节流调度：距上次落盘已超过窗口就立即写，否则排一次延迟写。
    private func scheduleFlush() {
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastFlushAt >= Self.flushInterval {
            pendingDeltaFlush()
        } else if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
                self?.flushScheduled = false
                self?.pendingDeltaFlush()
            }
        }
    }

    /// 把节流积攒的思考过程与正文一次性写入当前流式消息（并推进滚动版本号）。
    private func pendingDeltaFlush() {
        flushScheduled = false
        guard !pendingReasoning.isEmpty || !pendingDelta.isEmpty else { return }
        let reasoningChunk = pendingReasoning
        let chunk = pendingDelta
        pendingReasoning = ""
        pendingDelta = ""
        lastFlushAt = Date().timeIntervalSinceReferenceDate
        guard let idx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) else { return }
        if !reasoningChunk.isEmpty { messages[idx].reasoning += reasoningChunk }
        if !chunk.isEmpty { messages[idx].content += chunk }
        scrollVersion += 1
    }

    private func finishStreaming() {
        pendingDeltaFlush() // 收尾前先把节流中的内容写入
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
            // 自动折叠思考过程，让焦点回到正式回答（用户仍可点标题重新展开）
            messages[idx].isReasoningExpanded = false
            if messages[idx].content.isEmpty {
                // 区分「模型压根没输出」与「只输出了思考过程但没给答案」。
                // 后者此前在 max_tokens 被思考吃满时高发；现在默认不发送 max_tokens
                // （跟随服务端额度：思考模式 64K、effort=max 时 128K），仅当用户在设置页
                // 自行收窄上限时才可能复现，故保留该提示用于诊断。
                messages[idx].content = messages[idx].reasoning.isEmpty
                    ? L10n.t(.placeholderNoContent)
                    : L10n.t(.placeholderReasoningOnly)
                messages[idx].isPlaceholder = true
            }
            messages[idx].sources = pendingSources
        }
        pendingSources = []
        isStreaming = false
        scrollVersion += 1
    }

    private func failStreaming(_ msg: String) {
        pendingDeltaFlush() // 先落盘再判断，保证「已收到部分内容」的场景不被误删
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            if messages[idx].content.isEmpty {
                messages.remove(at: idx) // 移除空的占位气泡
            } else {
                messages[idx].isStreaming = false
            }
        }
        isStreaming = false
        errorMessage = msg
        scrollVersion += 1
    }

    /// 把本地消息列表转为 OpenAI 兼容的 messages 数组
    /// （跳过正在生成的占位、空内容、以及「已停止/无返回内容」等 UI 占位文案）。
    /// 注意：只回传 `content`，`reasoning`（思考过程）按 DeepSeek 要求**不进入**历史上下文。
    private func buildAPIMessages() -> [[String: String]] {
        var result: [[String: String]] = []
        for m in messages {
            if m.isStreaming || m.isPlaceholder { continue }
            let c = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.isEmpty { continue }
            let role = m.role == .user ? "user" : "assistant"
            result.append(["role": role, "content": c])
        }
        return result
    }
}
