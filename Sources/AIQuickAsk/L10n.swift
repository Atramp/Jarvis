import Foundation
import Combine

// MARK: - 语言

/// 用户在设置页选择的语言（持久化在 `Config.appLanguage`）。
///
/// 与 `ResolvedLanguage` 分开是有必要的：`system` 是一个**未决态**，
/// 它本身没有译文，必须在运行时才能解析成具体语言。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    /// 下拉选项的显示名。刻意**不整体本地化**：语言名一律用该语言自身书写，
    /// 英文读者找 "English" 比找「英语」容易（中文读者亦然）。只有「跟随系统」这一项随界面语言变化。
    var displayName: String {
        switch self {
        case .system: return L10n.t(.languageFollowSystem)
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    /// 从持久化字符串还原；未知/缺失一律回落「跟随系统」。
    static func from(_ raw: String?) -> AppLanguage {
        guard let raw, let value = AppLanguage(rawValue: raw) else { return .system }
        return value
    }
}

/// 实际生效的语言 —— 目前只有两套译文。
enum ResolvedLanguage: String {
    case zhHans = "zh-Hans"
    case en = "en"

    /// 系统语言偏好 → 本应用译文。
    ///
    /// 规则（刻意简单，因为只有两套译文）：
    /// - 逐个扫描 `preferred` 而不是只看第一条 —— 装了 [fr, en] 的机器应当拿到英文；
    /// - 任何 `zh*` 都归到简体：目前没有繁体译文表，而繁体读者读简体的成本远低于读英文；
    /// - 都不是（纯日语/德语等系统）→ 回落简体中文，与 Info.plist 的
    ///   `CFBundleDevelopmentRegion` 以及产品主用户群保持一致。
    ///
    /// 抽成纯函数（`preferred` 可注入）以便无头断言。
    static func resolve(_ choice: AppLanguage, preferred: [String] = Locale.preferredLanguages) -> ResolvedLanguage {
        switch choice {
        case .zhHans: return .zhHans
        case .en: return .en
        case .system:
            for tag in preferred {
                let lower = tag.lowercased()
                if lower.hasPrefix("zh") { return .zhHans }
                if lower.hasPrefix("en") { return .en }
            }
            return .zhHans
        }
    }
}

// MARK: - 本地化

/// 界面文案的单一事实来源。
///
/// **为什么不用 `.lproj/Localizable.strings`**：本工程用 `swiftc` 直编 + 手工组装 .app。
/// 裸二进制（`make run`，或把可执行文件单独拷走）运行时 `Bundle.main` 里没有资源目录，
/// `NSLocalizedString` 会悄悄退化成直接显示 key。Swift 表在「.app 内运行」与
/// 「裸二进制运行」两种方式下行为完全一致；语言切换也不需要重载 Bundle 或重启进程。
///
/// 用法：`L10n.t(.sendButton)`；带参用 `L10n.t(.errorHTTP, code)`，
/// 模板里的占位符是标准 `%d` / `%@`。带计数且英文需要单复数时用 `L10n.count(.xxxOne, .xxxOther, n)`。
final class L10n: ObservableObject {
    static let shared = L10n()

    /// 用户选择（落盘在 `Config.appLanguage`）。
    @Published private(set) var choice: AppLanguage
    /// 解析后的实际语言。视图只要持有本对象，语言一变就会重绘 —— 无需重启。
    @Published private(set) var resolved: ResolvedLanguage

    private init() {
        let saved = AppLanguage.from(Config.appLanguage)
        choice = saved
        resolved = ResolvedLanguage.resolve(saved)
        // 用户在「系统设置」里改了语言时重新解析（只对 choice == .system 有意义）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemLocaleChanged),
            name: NSLocale.currentLocaleDidChangeNotification,
            object: nil
        )
    }

    @objc private func systemLocaleChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.apply(self.choice)
        }
    }

    /// 设置页切换语言：落盘 + 立即生效。
    func setChoice(_ newValue: AppLanguage) {
        apply(newValue)
    }

    private func apply(_ newValue: AppLanguage) {
        Config.appLanguage = newValue.rawValue
        choice = newValue
        let next = ResolvedLanguage.resolve(newValue)
        if next != resolved { resolved = next }
    }

    // MARK: - 查询

    /// 取当前语言的文案。
    /// 缺键时返回 `<键名>`（**故意显眼**）—— 静默回落另一种语言会把「漏译」藏起来。
    static func t(_ key: Key) -> String {
        guard let entry = table[key] else { return "<" + key.rawValue + ">" }
        return shared.resolved == .en ? entry.en : entry.zh
    }

    /// 取当前语言的模板并按 C 方式填充参数。
    /// 注意模板必须用半角 `%d` / `%@`；中文模板里的全角括号是**普通字符**，不参与插值，
    /// 因此不会踩到「全角括号被计入 Swift 插值嵌套」那个坑（那是 `\(…)` 才会有的问题）。
    static func t(_ key: Key, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// 带计数的模板：英文按 `n == 1` 选单数模板，其余情况（含中文）一律用复数模板。
    static func count(_ one: Key, _ other: Key, _ n: Int) -> String {
        let key = (shared.resolved == .en && n == 1) ? one : other
        return String(format: t(key), n)
    }

    /// 当前语言对应的 `Locale`，供日期格式化使用。
    static var locale: Locale {
        shared.resolved == .en ? Locale(identifier: "en_US") : Locale(identifier: "zh_CN")
    }

    /// 「9月15日 星期二」/「Tue, Sep 15」——状态提示条与确认卡标题的日期格式。
    static var dayDateFormat: String {
        shared.resolved == .en ? "EEE, MMM d" : "M月d日 EEEE"
    }
}

// MARK: - 键

extension L10n {
    /// 文案键。
    ///
    /// 用 enum 而非裸字符串：调用处拼错编译不过；配合 `allCases` 还能在自检里
    /// 穷举校验「两张表是否覆盖全部键、有无空串、占位符数量是否一致」。
    enum Key: String, CaseIterable {
        // 应用与菜单
        case appName
        case menuOpenPanel
        case menuBrowser
        case menuSettings
        case menuLaunchAtLogin
        case menuQuit
        case settingsWindowTitle

        // 通用按钮
        case buttonCancel
        case buttonAdd
        case buttonUndo
        case buttonSend
        case buttonStop
        case buttonRestoreDefault

        // 输入栏
        case inputPlaceholder
        case sendHelp
        case searchOnHelp
        case searchOffHelp
        case thinkingDisabledHelp
        case thinkingOffHelp
        case thinkingOnHelp
        case todoShortcutOnHelp
        case todoShortcutOffHelp
        case clearHelp
        case closeHelp

        // 内嵌浏览器
        case browserBackHelp
        case browserForwardHelp
        case browserOpenExternalHelp
        case browserCloseHelp
        case browserLoadFailed
        case browserConnectFailed
        case browserRetry

        // 消息与来源
        case waitingSearching
        case waitingThinking
        case waitingGenerating
        case placeholderStopped
        case placeholderNoContent
        case placeholderReasoningOnly
        case saveAsTodo
        case saveAsTodoHelp
        case sourcesTitle
        case sourcesCountOne
        case sourcesCountOther
        case sourcesExpandHelp
        case sourcesCollapseHelp

        // 待办确认卡
        case todoCardTitle
        case todoTitlePlaceholder
        case todoDueDateToggle
        case todoHasTimeToggle
        case todoRepeatLabel
        case todoPriorityLabel
        case todoStatusDismissHelp
        case todoDefaultListName
        case reminderOffsetAtTime
        case reminderOffset5
        case reminderOffset15
        case reminderOffset30
        case reminderOffset60
        case reminderOffset1440

        // 待办状态与错误
        case todoPrefixBodyMissing
        case todoErrorTitleEmpty
        case todoAdded
        case todoUndone
        case todoUndoFailed
        case todoNeedPermission
        case todoNotAuthorized
        case todoCreateFailed
        case todoNotesSourcePrefix
        case todoRepeatDaily
        case todoRepeatWeekly
        case todoRepeatMonthly
        case todoRepeatYearly
        case todoRepeatNone
        case todoPriorityHigh
        case todoPriorityMedium
        case todoPriorityLow
        case todoPriorityNone
        case todoErrorEmptyTitle
        case todoErrorNoWritableList

        // 设置页
        case settingsSectionModel
        case settingsSectionSystemPrompt
        case settingsSectionThinking
        case settingsSectionSearch
        case settingsSectionTodo
        case settingsSectionGeneral
        case settingsLaunchAtLogin
        case settingsShortcutHotkey
        case settingsShortcutEnter
        case settingsShortcutAccessibility
        case settingsTavilyHelp
        case languageLabel
        case languageFollowSystem
        case languageHelp

        // 设置页 · 系统提示词
        case systemPromptToggle
        case systemPromptPresetLabel
        case systemPromptCustomPreset
        case systemPromptCharCountOne
        case systemPromptCharCountOther
        case systemPromptHelp

        // 设置页 · 思考模式
        case thinkingToggle
        case thinkingEffortLabel
        case thinkingMaxTokensAuto
        case thinkingMaxTokensFixed
        case thinkingTemperatureLabel
        case thinkingTemperatureActiveHelp
        case thinkingTemperatureInactiveHelp
        case thinkingSectionHelp
        case thinkingNonDeepSeekWarning

        // 设置页 · 提醒事项
        case todoAuthLabel
        case todoAuthNoList
        case todoAuthorizedListCountOne
        case todoAuthorizedListCountOther
        case todoRequestAccess
        case todoFirstTimePrompt
        case todoOpenSystemSettings
        case todoOpenSystemSettingsHelp
        case todoPrefixToggle
        case todoPrefixLabel
        case todoDefaultListLabel
        case todoFollowSystemDefault
        case todoFollowSystemDefaultNamed
        case todoShowButtonToggle
        case todoUsageHelp
        case todoSigningHelp

        // 授权状态
        case authNotDetermined
        case authDenied
        case authRestricted
        case authAuthorized

        // LLM / 搜索错误
        case errorMissingAPIKey
        case errorInvalidBaseURL
        case errorNoResponse
        case errorEmptyBody
        case errorHTTP
        case errorParseFailed
        case searchErrorMissingKey
        case searchErrorInvalidURL
        case searchErrorHTTP
        case searchErrorEmpty
        case searchErrorParseFailed
    }
}

// MARK: - 文案表

extension L10n {
    /// 键 → 双语文案。两种语言写在同一个元组里，新增键时**不可能只填一种语言**。
    /// 覆盖率、空值、占位符一致性由 `tools/main.swift` 的自检穷举断言保证。
    static let table: [Key: (zh: String, en: String)] = [
        // 应用与菜单
        .appName: ("AI 快捷问答", "AI Quick Ask"),
        .menuOpenPanel: ("打开问答窗口", "Open Quick Ask"),
        .menuBrowser: ("浏览器", "Browser"),
        .menuSettings: ("设置…", "Settings…"),
        .menuLaunchAtLogin: ("登录时启动", "Launch at Login"),
        .menuQuit: ("退出", "Quit"),
        .settingsWindowTitle: ("设置", "Settings"),

        // 通用按钮
        .buttonCancel: ("取消", "Cancel"),
        .buttonAdd: ("添加", "Add"),
        .buttonUndo: ("撤销", "Undo"),
        .buttonSend: ("发送", "Send"),
        .buttonStop: ("停止", "Stop"),
        .buttonRestoreDefault: ("恢复默认", "Restore Default"),

        // 输入栏
        .inputPlaceholder: ("问点什么…", "Ask anything…"),
        .sendHelp: ("发送给 AI（Enter）｜⌘Enter 用 Google 搜索", "Send to AI (Enter) | Google search (⌘Enter)"),
        .searchOnHelp: ("联网搜索：已开启（发送时强制搜索，点击关闭，⌘S）", "Web search: on (forced on send; click to turn off, ⌘S)"),
        .searchOffHelp: ("联网搜索：已关闭（点击开启，⌘S）", "Web search: off (click to turn on, ⌘S)"),
        .thinkingDisabledHelp: ("思考模式仅对 DeepSeek 端点生效（当前 Base URL 非 DeepSeek，该开关已跳过，也不会发送 thinking 字段）", "Thinking mode only applies to DeepSeek endpoints (the current Base URL is not DeepSeek, so this switch is skipped and no thinking field is sent)"),
        .thinkingOffHelp: ("思考模式：已关闭，首字更快（点击开启，⌘T）", "Thinking mode: off — faster first token (click to enable, ⌘T)"),
        .thinkingOnHelp: ("思考模式：已开启（强度 %@，点击关闭，⌘T）", "Thinking mode: on (effort %@, click to disable, ⌘T)"),
        .todoShortcutOnHelp: ("添加到系统「提醒事项」：点击填入 %@ 前缀，也可在输入框里直接敲它", "Add to Reminders: click to insert the %@ prefix, or just type it in the box"),
        .todoShortcutOffHelp: ("待办前缀已在设置里关闭", "The todo prefix is disabled in Settings"),
        .clearHelp: ("清空对话", "Clear conversation"),
        .closeHelp: ("关闭（⌘W）", "Close (⌘W)"),

        // 内嵌浏览器
        .browserBackHelp: ("后退（⌘[）", "Back (⌘[)"),
        .browserForwardHelp: ("前进（⌘]）", "Forward (⌘])"),
        .browserOpenExternalHelp: ("用默认浏览器打开当前页", "Open current page in the default browser"),
        .browserCloseHelp: ("收起网页，回到对话（Esc）", "Close the page and return to chat (Esc)"),
        .browserLoadFailed: ("页面加载失败：%@", "Failed to load the page: %@"),
        .browserConnectFailed: ("无法连接到该网址：%@", "Cannot connect to this address: %@"),
        .browserRetry: ("重试", "Retry"),

        // 消息与来源
        .waitingSearching: ("正在联网搜索…", "Searching the web…"),
        .waitingThinking: ("思考中…", "Thinking…"),
        .waitingGenerating: ("生成中…", "Generating…"),
        .placeholderStopped: ("（已停止）", "(stopped)"),
        .placeholderNoContent: ("（无返回内容）", "(no content returned)"),
        .placeholderReasoningOnly: ("（模型只输出了思考过程，未给出回答）", "(the model only produced reasoning and no answer)"),
        .saveAsTodo: ("存为待办", "Save as Reminder"),
        .saveAsTodoHelp: ("把这条回答创建为系统「提醒事项」，备注里会带上原问题", "Create a Reminder from this answer; the original question is kept in the notes"),
        .sourcesTitle: ("参考来源", "Sources"),
        .sourcesCountOne: ("%d 条", "%d source"),
        .sourcesCountOther: ("%d 条", "%d sources"),
        .sourcesExpandHelp: ("展开参考来源", "Expand sources"),
        .sourcesCollapseHelp: ("收起参考来源", "Collapse sources"),

        // 待办确认卡
        .todoCardTitle: ("添加到提醒事项", "Add to Reminders"),
        .todoTitlePlaceholder: ("标题", "Title"),
        .todoDueDateToggle: ("截止日期", "Due date"),
        .todoHasTimeToggle: ("具体时刻", "Set time"),
        .todoRepeatLabel: ("重复", "Repeat"),
        .todoPriorityLabel: ("优先级", "Priority"),
        .todoStatusDismissHelp: ("关闭提示", "Dismiss"),
        .todoDefaultListName: ("提醒事项", "Reminders"),
        .reminderOffsetAtTime: ("到点提醒", "At due time"),
        .reminderOffset5: ("提前 5 分钟", "5 min before"),
        .reminderOffset15: ("提前 15 分钟", "15 min before"),
        .reminderOffset30: ("提前 30 分钟", "30 min before"),
        .reminderOffset60: ("提前 1 小时", "1 hour before"),
        .reminderOffset1440: ("提前 1 天", "1 day before"),

        // 待办状态与错误
        .todoPrefixBodyMissing: ("在 %@ 后面写上要做的事，回车即可创建提醒", "Write what you need to do after %@ and press Enter to create a reminder"),
        .todoErrorTitleEmpty: ("标题不能为空", "The title cannot be empty"),
        .todoAdded: ("已添加 · %@", "Added · %@"),
        .todoUndone: ("已撤销", "Undone"),
        .todoUndoFailed: ("撤销失败（该提醒可能已被手动删除）", "Undo failed (the reminder may have been deleted manually)"),
        .todoNeedPermission: ("需要「提醒事项」权限才能创建。请到「系统设置 → 隐私与安全性 → 提醒事项」中允许本应用", "Reminders permission is required. Allow this app in System Settings → Privacy & Security → Reminders"),
        .todoNotAuthorized: ("尚未获得「提醒事项」权限，请到系统设置里开启", "Reminders permission has not been granted; please enable it in System Settings"),
        .todoCreateFailed: ("创建失败：%@", "Failed to create: %@"),
        .todoNotesSourcePrefix: ("来源：", "Source: "),
        .todoRepeatDaily: ("每天", "Daily"),
        .todoRepeatWeekly: ("每周", "Weekly"),
        .todoRepeatMonthly: ("每月", "Monthly"),
        .todoRepeatYearly: ("每年", "Yearly"),
        .todoRepeatNone: ("不重复", "Does not repeat"),
        .todoPriorityHigh: ("高", "High"),
        .todoPriorityMedium: ("中", "Medium"),
        .todoPriorityLow: ("低", "Low"),
        .todoPriorityNone: ("无", "None"),
        .todoErrorEmptyTitle: ("标题为空，无法创建", "The title is empty; cannot create the reminder"),
        .todoErrorNoWritableList: ("没有可写入的提醒事项清单", "No writable Reminders list is available"),

        // 设置页
        .settingsSectionModel: ("模型接入（OpenAI 兼容接口）", "Model (OpenAI-compatible API)"),
        .settingsSectionSystemPrompt: ("系统提示词（System Prompt）", "System Prompt"),
        .settingsSectionThinking: ("思考模式（Thinking）", "Thinking Mode"),
        .settingsSectionSearch: ("联网搜索", "Web Search"),
        .settingsSectionTodo: ("提醒事项（待办）", "Reminders (Todos)"),
        .settingsSectionGeneral: ("通用", "General"),
        .settingsLaunchAtLogin: ("开机自启动", "Launch at Login"),
        .settingsShortcutHotkey: ("快捷键：双击右侧 ⌘ Command（触发弹出问答窗口）", "Shortcut: double-tap the right ⌘ Command to open the quick-ask panel"),
        .settingsShortcutEnter: ("Enter：发送给 AI；⌘ + Enter：用 Google 搜索输入内容（打开浏览器，不调用 AI）", "Enter: send to AI; ⌘ + Enter: Google-search the input (opens a browser, no AI call)"),
        .settingsShortcutAccessibility: ("首次使用需在「系统设置 → 隐私与安全性 → 辅助功能」中允许本应用，否则快捷键不生效", "On first use, allow this app in System Settings → Privacy & Security → Accessibility, otherwise the shortcut will not work"),
        .settingsTavilyHelp: ("前往 tavily.com 注册获取 Key（tvly- 开头）；联网搜索开关在问答窗口内（默认关闭，仅当前对话有效，⌘S 切换）", "Register at tavily.com to get a key (starts with tvly-); the search switch lives in the quick-ask panel (off by default, per-conversation only, ⌘S)"),
        .languageLabel: ("语言", "Language"),
        .languageFollowSystem: ("跟随系统", "Follow System"),
        .languageHelp: ("切换后立即生效，无需重启。模型用什么语言作答由「系统提示词」决定，不受此处影响。", "Takes effect immediately, no restart needed. The language the model answers in is controlled by the System Prompt, not by this setting."),

        // 设置页 · 系统提示词
        .systemPromptToggle: ("启用系统提示词", "Enable System Prompt"),
        .systemPromptPresetLabel: ("预设模板", "Preset"),
        .systemPromptCustomPreset: ("自定义", "Custom"),
        .systemPromptCharCountOne: ("%d 字", "%d character"),
        .systemPromptCharCountOther: ("%d 字", "%d characters"),
        .systemPromptHelp: ("以 system 角色置于 messages 首位，每次提问都重新注入；清空内容或关闭开关则该轮不发送 system 消息。修改仅对新提问生效，不影响已有对话。", "Sent as the first system message on every request. If the content is empty or the switch is off, no system message is sent for that turn. Changes apply to new questions only."),

        // 设置页 · 思考模式
        .thinkingToggle: ("启用思考模式", "Enable Thinking Mode"),
        .thinkingEffortLabel: ("思考强度", "Reasoning Effort"),
        .thinkingMaxTokensAuto: ("留 0 = 不发送该字段，完全跟随服务端：思考模式默认 64K，强度 max 时 128K。", "0 means the field is not sent at all, so the server default applies: 64K in thinking mode, 128K at max effort."),
        .thinkingMaxTokensFixed: ("已显式限制为 %d token（思考过程同样计入该额度，设太小会导致回答被截断）。", "Explicitly capped at %d tokens (reasoning counts toward this budget; too small a value truncates the answer)."),
        .thinkingTemperatureLabel: ("采样温度", "Temperature"),
        .thinkingTemperatureActiveHelp: ("非思考模式下生效，随请求发送。值越低回答越集中确定，越高越发散。", "Applies outside thinking mode and is sent with the request. Lower values are more focused and deterministic, higher values more divergent."),
        .thinkingTemperatureInactiveHelp: ("当前处于思考模式，该参数不生效（官方说明），本工具不发送以免造成误解。", "Thinking mode is on, where this parameter has no effect (per the official docs), so it is not sent to avoid a false impression."),
        .thinkingSectionHelp: ("开启后模型先输出思维链（reasoning_content，界面渲染为可折叠的「思考过程」面板）再作答，难题质量更高、首字更慢。问答窗口内可用 ⌘T 对单个问题临时切换。", "When on, the model emits a chain of thought first (reasoning_content, rendered as a collapsible panel) and then answers: better on hard problems, slower to first token. Press ⌘T in the panel to override it for a single question."),
        .thinkingNonDeepSeekWarning: ("当前 Base URL 不是 DeepSeek 端点，thinking / reasoning_effort 字段不会被发送，以上开关切回 DeepSeek 后才生效。", "The current Base URL is not a DeepSeek endpoint, so thinking / reasoning_effort are not sent; these switches only apply once you point back at DeepSeek."),

        // 设置页 · 提醒事项
        .todoAuthLabel: ("授权状态", "Status"),
        .todoAuthNoList: ("已授权，但未读到任何清单", "Authorized, but no list was found"),
        .todoAuthorizedListCountOne: ("已授权，读到 %d 个清单", "Authorized, %d list found"),
        .todoAuthorizedListCountOther: ("已授权，读到 %d 个清单", "Authorized, %d lists found"),
        .todoRequestAccess: ("请求授权", "Grant Access"),
        .todoFirstTimePrompt: ("首次使用会弹出系统授权框", "A system permission dialog appears the first time"),
        .todoOpenSystemSettings: ("打开系统设置", "Open System Settings"),
        .todoOpenSystemSettingsHelp: ("跳转到「系统设置 → 隐私与安全性 → 提醒事项」", "Jump to System Settings → Privacy & Security → Reminders"),
        .todoPrefixToggle: ("启用前缀快速添加", "Enable Prefix Shortcut"),
        .todoPrefixLabel: ("前缀词", "Prefix"),
        .todoDefaultListLabel: ("默认清单", "Default List"),
        .todoFollowSystemDefault: ("跟随系统默认", "System default"),
        .todoFollowSystemDefaultNamed: ("跟随系统默认（%@）", "System default (%@)"),
        .todoShowButtonToggle: ("回答下方显示「存为待办」", "Show “Save as Reminder” under answers"),
        .todoUsageHelp: ("用法：在输入框以「%@ 」开头写一句话回车即可创建，例如「明天下午三点提醒我给张工回电话」；也可点输入栏的清单图标填入前缀。创建前会弹出确认卡，可改标题、截止、重复与优先级。回答下方的「存为待办」则把该条回答存成提醒，备注里带上原问题。", "Usage: start a line with “%@ ” and press Enter to create a reminder, e.g. “remind me to call Zhang tomorrow at 3pm”. You can also click the checklist icon in the input bar to insert the prefix. A confirmation card appears first, where you can edit the title, due date, repeat rule and priority. “Save as Reminder” under an answer turns that answer into a reminder with the original question in its notes."),
        .todoSigningHelp: ("重新编译后若权限莫名失效，是缺少稳定代码签名所致；建一张自签名证书即可，详见 README《代码签名与隐私权限》。", "If permissions mysteriously stop working after a rebuild, it is caused by the lack of a stable code signature; creating a self-signed certificate fixes it. See “Code signing and privacy permissions” in the README."),

        // 授权状态
        .authNotDetermined: ("未授权", "Not authorized"),
        .authDenied: ("已拒绝", "Denied"),
        .authRestricted: ("受系统策略限制", "Restricted by policy"),
        .authAuthorized: ("已授权", "Authorized"),

        // LLM / 搜索错误
        .errorMissingAPIKey: ("请先点菜单栏「设置」填写 API Key", "Open Settings from the menu bar and enter an API Key first"),
        .errorInvalidBaseURL: ("base_url 无效，无法构造请求地址", "Invalid base_url: cannot build the request URL"),
        .errorNoResponse: ("请求无响应", "The request got no response"),
        .errorEmptyBody: ("请求无返回内容", "The request returned no content"),
        .errorHTTP: ("请求失败（HTTP %d）", "Request failed (HTTP %d)"),
        .errorParseFailed: ("响应解析失败", "Failed to parse the response"),
        .searchErrorMissingKey: ("未配置 Tavily API Key", "No Tavily API Key configured"),
        .searchErrorInvalidURL: ("搜索地址无效", "Invalid search URL"),
        .searchErrorHTTP: ("搜索失败（HTTP %d）", "Search failed (HTTP %d)"),
        .searchErrorEmpty: ("搜索无返回内容", "The search returned no content"),
        .searchErrorParseFailed: ("搜索响应解析失败", "Failed to parse the search response")
    ]
}
