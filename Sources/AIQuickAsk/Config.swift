import Foundation

/// 系统提示词预设模板（设置页「预设模板」下拉可选）。
struct SystemPromptPreset: Identifiable {
    /// 稳定标识。**不能用名称当 id** —— 名称随界面语言变化，用它当 Picker 的 tag
    /// 会导致切换语言后 selection 指向一个不存在的项，下拉框静默显示成空白。
    let id: String
    /// 当前语言下的显示名。
    let name: String
    /// 当前语言下的提示词正文。
    let content: String
}

/// 思考强度选项（`reasoning_effort`）。
///
/// 官方文档（`guides/thinking_mode`）现行的 OpenAI 格式取值为 `none / low / high / max`，
/// 其中 `none` 等价于关闭思考模式，本工具改用 `thinking.type` 开关表达，故此处只保留三档强度。
/// 兼容映射：`minimal` → `low`；`medium` / `xhigh` → `high`。
struct ReasoningEffortOption: Identifiable {
    /// 传给 API 的原始取值。
    let id: String
    /// 下拉显示名。
    let name: String
    /// 设置页说明文案。
    let detail: String
}

/// 配置读写（基于 UserDefaults），集中管理默认值。
enum Config {
    enum Keys {
        static let baseURL = "baseURL"
        static let apiKey = "apiKey"
        static let model = "model"
        static let tavilyApiKey = "tavilyApiKey"
        static let systemPrompt = "systemPrompt"
        static let systemPromptEnabled = "systemPromptEnabled"
        static let thinkingEnabled = "thinkingEnabled"
        static let reasoningEffort = "reasoningEffort"
        static let maxTokensOverride = "maxTokensOverride"
        static let temperature = "temperature"
        static let todoPrefixEnabled = "todoPrefixEnabled"
        static let todoPrefix = "todoPrefix"
        static let todoDefaultList = "todoDefaultList"
        static let todoShowAnswerButton = "todoShowAnswerButton"
        static let appLanguage = "appLanguage"
    }

    static let defaults = UserDefaults.standard

    // MARK: - API

    /// baseURL 的默认值（单一事实来源：Config / SettingsView / README 三处共用）。
    /// DeepSeek 官方文档示例使用 https://api.deepseek.com（不带 /v1）。
    static let defaultBaseURL = "https://api.deepseek.com"

    /// model 的默认值（单一事实来源：Config / SettingsView / README 三处共用）。
    /// 官方文档现行模型名为 `deepseek-flash`；旧名 `deepseek-chat` 仍可调用但会被路由到 flash。
    static let defaultModel = "deepseek-flash"

    static var baseURL: String {
        get { defaults.string(forKey: Keys.baseURL) ?? defaultBaseURL }
        set { defaults.set(newValue, forKey: Keys.baseURL) }
    }

    static var apiKey: String {
        get { defaults.string(forKey: Keys.apiKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.apiKey) }
    }

    static var model: String {
        get { defaults.string(forKey: Keys.model) ?? defaultModel }
        set { defaults.set(newValue, forKey: Keys.model) }
    }

    // MARK: - 联网搜索

    static var tavilyApiKey: String {
        get { defaults.string(forKey: Keys.tavilyApiKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.tavilyApiKey) }
    }

    // MARK: - 界面语言（i18n）

    /// 用户选择的界面语言，取值见 `AppLanguage`（"system" / "zh-Hans" / "en"）。
    /// 实际生效的语言由 `L10n.shared.resolved` 解析后提供 —— 这里只负责落盘。
    static var appLanguage: String {
        get { defaults.string(forKey: Keys.appLanguage) ?? AppLanguage.system.rawValue }
        set { defaults.set(newValue, forKey: Keys.appLanguage) }
    }

    // MARK: - 系统提示词（System Prompt）

    /// 默认系统提示词（单一事实来源：Config / SettingsView / README 三处共用）。
    /// **随界面语言变化**：用户从未编辑过时，输入框回显的是当前语言的默认人设。
    static var defaultSystemPrompt: String {
        Prompts.defaultSystemPrompt(L10n.shared.resolved)
    }

    /// 文本未命中任何预设时，下拉框回显的占位项名称。
    static var customPresetName: String { L10n.t(.systemPromptCustomPreset) }

    /// 内置预设模板（当前语言）。第一项的内容必须与 `defaultSystemPrompt` 完全相同（用于反查回显）。
    static var systemPromptPresets: [SystemPromptPreset] {
        let language = L10n.shared.resolved
        return Prompts.personaDefinitions.map { definition in
            SystemPromptPreset(
                id: definition.id,
                name: definition.name(language),
                content: definition.content(language)
            )
        }
    }

    /// 用户在设置页填写的系统提示词（从未设置过时回落到默认值）。
    static var systemPrompt: String {
        get { defaults.string(forKey: Keys.systemPrompt) ?? defaultSystemPrompt }
        set { defaults.set(newValue, forKey: Keys.systemPrompt) }
    }

    /// 系统提示词开关。默认开启（与引入配置项之前的行为保持一致）。
    /// 注：`defaults.bool(forKey:)` 在键不存在时返回 false，故需先判空。
    static var systemPromptEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.systemPromptEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.systemPromptEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.systemPromptEnabled) }
    }

    /// 实际注入请求的 system 内容：
    /// 开关关闭、或内容为空白 → 返回 nil（该轮请求不发送 system 消息）。
    static var effectiveSystemPrompt: String? {
        guard systemPromptEnabled else { return nil }
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 反查文本命中的预设 id（用于设置页下拉回显）；未命中返回 nil，表示「自定义」。
    ///
    /// 跨语言查找（见 `Prompts.personaID(forContent:)`）：用户先把界面切成英文、
    /// 输入框里仍是上次选的中文预设内容时，也必须能正确回显成对应项而不是「自定义」。
    static func presetID(for text: String) -> String? {
        Prompts.personaID(forContent: text)
    }

    /// 反查文本命中的预设名（当前语言）；未命中返回「自定义」。
    static func presetName(for text: String) -> String {
        guard let id = presetID(for: text) else { return customPresetName }
        return systemPromptPresets.first(where: { $0.id == id })?.name ?? customPresetName
    }

    // MARK: - 思考模式（Thinking）与采样参数
    //
    // 依据 DeepSeek 官方文档（`guides/thinking_mode` + `api/create-chat-completion` 现行版本）：
    // - `thinking: {"type": "enabled" | "disabled"}`，**默认 enabled**；
    // - `reasoning_effort: "none" | "low" | "high" | "max"`，**默认 high**；`none` 等价于关闭思考；
    // - `max_tokens`：**不发送时**非思考模式默认 8K、思考模式默认 64K（effort=max 时 128K）；
    // - 思考模式下 `temperature` / `frequency_penalty` / `presence_penalty` 均**不生效**
    //   （后两者官方已标注 deprecated）；`top_p` 思考模式下下限被抬到 0.95，非思考模式恒为 1.0 且忽略传入值。

    /// 思考模式默认开启（对齐官方默认值）。
    static let defaultThinkingEnabled = true

    /// 默认思考强度（对齐官方默认值 high）。
    static let defaultReasoningEffort = "high"

    /// `max_tokens` 的默认覆盖值：**0 表示不发送该字段**，完全跟随服务端默认。
    /// 显式写死上限只会自缚手脚 —— 此前硬编码的 16384 就低于服务端思考模式的 64K 默认值。
    static let defaultMaxTokensOverride = 0

    /// `max_tokens` 的官方取值上限（1 ~ 393216）。
    static let maxTokensCeiling = 393216

    /// 采样温度默认值。**仅在非思考模式下会真正发送**，思考模式下该参数不生效故不发送。
    /// 取 0.2 与引入本配置项之前的硬编码行为一致（偏确定性），避免换用非思考模型时行为回退。
    static let defaultTemperature = 0.2

    /// 可选思考强度档位的 id（顺序即下拉顺序）。发给 API 的原始取值，两种语言共用，不可翻译。
    static let reasoningEffortIDs: [String] = ["low", "high", "max"]

    /// 可选思考强度档位（名称与说明取当前语言）。
    static var reasoningEffortOptions: [ReasoningEffortOption] {
        let language = L10n.shared.resolved
        return reasoningEffortIDs.map { id in
            ReasoningEffortOption(
                id: id,
                name: Prompts.effortName(id: id, language: language),
                detail: Prompts.effortDetail(id: id, language: language)
            )
        }
    }

    /// 思考模式开关（设置页默认值；面板内可临时覆盖，见 `ChatViewModel.thinkingEnabled`）。
    static var thinkingEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.thinkingEnabled) == nil { return defaultThinkingEnabled }
            return defaults.bool(forKey: Keys.thinkingEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.thinkingEnabled) }
    }

    /// 思考强度（`reasoning_effort`）。非法/未设置时回落到默认档。
    /// 用 `reasoningEffortIDs` 而非 `reasoningEffortOptions` 校验：后者每次访问都会重建数组。
    static var reasoningEffort: String {
        get {
            let v = defaults.string(forKey: Keys.reasoningEffort) ?? defaultReasoningEffort
            return reasoningEffortIDs.contains(v) ? v : defaultReasoningEffort
        }
        set { defaults.set(newValue, forKey: Keys.reasoningEffort) }
    }

    /// 思考强度对应的展示名（当前语言）。用于设置页下拉与面板 ⌘T 的悬浮说明。
    static var reasoningEffortName: String {
        reasoningEffortOptions.first(where: { $0.id == reasoningEffort })?.name ?? defaultReasoningEffort
    }

    /// `max_tokens` 覆盖值。0 表示不发送、跟随服务端默认；非 0 时收敛到官方合法区间。
    static var maxTokensOverride: Int {
        get { defaults.integer(forKey: Keys.maxTokensOverride) }
        set { defaults.set(max(0, min(newValue, maxTokensCeiling)), forKey: Keys.maxTokensOverride) }
    }

    /// 采样温度（仅非思考模式生效）。收敛到官方合法区间 0 ~ 2。
    static var temperature: Double {
        get {
            if defaults.object(forKey: Keys.temperature) == nil { return defaultTemperature }
            return min(max(defaults.double(forKey: Keys.temperature), 0), 2)
        }
        set { defaults.set(min(max(newValue, 0), 2), forKey: Keys.temperature) }
    }

    // MARK: - 待办（写入系统「提醒事项」）

    /// 前缀总开关默认值。
    static let defaultTodoPrefixEnabled = true

    /// 触发待办录入的前缀词默认值。做成可配置，便于避开与其他工具的记号冲突。
    static let defaultTodoPrefix = "#todo"

    /// 「存为待办」按钮默认开关。
    static let defaultTodoShowAnswerButton = true

    /// 前缀总开关。
    static var todoPrefixEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.todoPrefixEnabled) == nil { return defaultTodoPrefixEnabled }
            return defaults.bool(forKey: Keys.todoPrefixEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.todoPrefixEnabled) }
    }

    /// 前缀词本身。空白或缺失时回落到默认值 —— 空前缀会命中每一句话，后果严重，必须兜住。
    static var todoPrefix: String {
        get {
            let raw = (defaults.string(forKey: Keys.todoPrefix) ?? defaultTodoPrefix)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? defaultTodoPrefix : raw
        }
        set { defaults.set(newValue, forKey: Keys.todoPrefix) }
    }

    /// 目标清单名。**空字符串表示「跟随系统默认清单」**，而不是「名为空的清单」。
    static var todoDefaultList: String {
        get { defaults.string(forKey: Keys.todoDefaultList) ?? "" }
        set { defaults.set(newValue, forKey: Keys.todoDefaultList) }
    }

    /// 是否在每条 AI 回答下方显示「存为待办」按钮。
    static var todoShowAnswerButton: Bool {
        get {
            if defaults.object(forKey: Keys.todoShowAnswerButton) == nil { return defaultTodoShowAnswerButton }
            return defaults.bool(forKey: Keys.todoShowAnswerButton)
        }
        set { defaults.set(newValue, forKey: Keys.todoShowAnswerButton) }
    }

    /// 前缀匹配（大小写不敏感）。
    /// - Returns: `nil` = 未命中前缀；`""` = 命中了前缀但后面没写内容；非空 = 待抽取的正文。
    ///
    /// 三种返回值刻意分开：只打了 `#todo` 就回车属于「意图明确但内容缺失」，
    /// 应当提示「在后面写上要做的事」，而不是把它当成一个问题丢给模型。
    static func todoPrefixMatch(_ input: String) -> String? {
        guard todoPrefixEnabled else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = todoPrefix
        guard trimmed.count >= prefix.count,
              trimmed.lowercased().hasPrefix(prefix.lowercased()) else { return nil }

        let rest = trimmed.dropFirst(prefix.count)
        // 前缀后紧跟 ASCII 字母/数字时，视为更长单词的一部分而不是命中 ——
        // 否则 `#todoist` 会被切成正文 "ist"。中文没有词间空格，所以**不能**要求必须跟空格，
        // 只排除「ASCII 字母数字」这一种情况。
        if let next = rest.first, next.isASCII, next.isLetter || next.isNumber { return nil }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前 baseURL 是否指向 DeepSeek 官方端点。
    ///
    /// 作用：`thinking` / `reasoning_effort` 是 DeepSeek 私有扩展字段，本工具同时支持
    /// 通义千问 / Kimi / OpenAI 等 OpenAI 兼容服务。校验严格的第三方服务商可能对未知字段
    /// 直接返回 400，因此仅在确认是 DeepSeek 域名时才发送这两个字段。
    static var isDeepSeekEndpoint: Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "deepseek.com" || host.hasSuffix(".deepseek.com")
    }
}
