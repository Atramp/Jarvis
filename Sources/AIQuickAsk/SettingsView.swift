import SwiftUI

/// 设置：模型接入 + 系统提示词 + 思考模式 + 联网搜索 + 通用（开机自启动）+ 快捷键/权限说明。
struct SettingsView: View {
    @AppStorage(Config.Keys.baseURL) private var baseURL = Config.defaultBaseURL
    @AppStorage(Config.Keys.apiKey) private var apiKey = ""
    @AppStorage(Config.Keys.model) private var model = Config.defaultModel
    @AppStorage(Config.Keys.tavilyApiKey) private var tavilyApiKey = ""
    @AppStorage(Config.Keys.systemPromptEnabled) private var systemPromptEnabled = true
    @AppStorage(Config.Keys.thinkingEnabled) private var thinkingEnabled = Config.defaultThinkingEnabled
    @AppStorage(Config.Keys.reasoningEffort) private var reasoningEffort = Config.defaultReasoningEffort
    @AppStorage(Config.Keys.maxTokensOverride) private var maxTokensOverride = Config.defaultMaxTokensOverride
    @AppStorage(Config.Keys.temperature) private var temperature = Config.defaultTemperature
    @AppStorage(Config.Keys.todoPrefixEnabled) private var todoPrefixEnabled = Config.defaultTodoPrefixEnabled
    @AppStorage(Config.Keys.todoPrefix) private var todoPrefix = Config.defaultTodoPrefix
    @AppStorage(Config.Keys.todoDefaultList) private var todoDefaultList = ""
    @AppStorage(Config.Keys.todoShowAnswerButton) private var todoShowAnswerButton = Config.defaultTodoShowAnswerButton

    /// 授权状态与清单列表需要实时刷新，因此直接观察单例。
    /// （用 `@ObservedObject` 而非 `@StateObject`：单例的生命周期本来就由 App 持有。）
    @ObservedObject private var reminders = RemindersStore.shared

    /// 只挂不读：让设置页在语言切换时整体重绘（`L10n.t(...)` 是静态调用，
    /// SwiftUI 无法自行建立依赖，必须持有这个 ObservableObject）。
    @ObservedObject private var l10n = L10n.shared

    /// 下拉里「自定义」那一项的 tag。取值必须**不可能与任何预设 id 相同**。
    private static let customPresetTag = "__custom__"

    /// 避免 @State（swiftc 直编不加载 SwiftUIMacros 宏插件），改用自定义 Binding。
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { LoginItemManager.isEnabled },
            set: { LoginItemManager.setEnabled($0) }
        )
    }

    /// `max_tokens` 覆盖值的落盘 Binding。
    /// 必须走这里而不是直接绑 @AppStorage：@AppStorage 直写 UserDefaults，会绕过 `Config` 的区间收敛。
    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { maxTokensOverride },
            set: { maxTokensOverride = max(0, min($0, Config.maxTokensCeiling)) }
        )
    }

    /// 系统提示词的读写通路。
    ///
    /// **刻意不用 `@AppStorage`**：用户从未编辑过时要跟随界面语言回落到该语言的默认人设，
    /// 而 `@AppStorage` 的默认值只在属性包装器初始化时求值一次 —— 设置页是 NSHostingView 的
    /// 根视图、只创建一次，切语言不会重算，于是输入框会一直停在旧语言的默认人设上。
    /// 走 `Config.systemPrompt`（内部做「未设置 → 取当前语言默认值」）即可实时跟随。
    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { Config.systemPrompt },
            set: { Config.systemPrompt = $0 }
        )
    }

    /// 界面语言的落盘 Binding。写入后 `L10n.shared` 推送变更 → 整个设置页立即重绘。
    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { L10n.shared.choice },
            set: { L10n.shared.setChoice($0) }
        )
    }

    /// 预设下拉：selection 用**稳定的预设 id**而不是名称。
    /// 名称随界面语言变化，拿它当 tag 会导致切换语言后 selection 指向不存在的项、下拉框显示空白。
    /// 反查走 `Config.presetID(for:)`（跨语言匹配内容），故切语言后仍能正确回显。
    /// 选择「自定义」为无操作（保留用户手写内容），避免误清空。
    private var presetBinding: Binding<String> {
        Binding(
            get: { Config.presetID(for: systemPromptBinding.wrappedValue) ?? Self.customPresetTag },
            set: { id in
                guard id != Self.customPresetTag,
                      let content = Prompts.personaContent(id: id, language: L10n.shared.resolved) else { return }
                systemPromptBinding.wrappedValue = content
            }
        )
    }

    /// 前缀词的落盘 Binding。
    ///
    /// 必须走这里而不是直接绑 `@AppStorage`：**空前缀会命中每一句话**，
    /// 把普通提问全部劫持成待办录入。因此空白输入一律回落到默认值。
    private var todoPrefixBinding: Binding<String> {
        Binding(
            get: { todoPrefix },
            set: { raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                todoPrefix = trimmed.isEmpty ? Config.defaultTodoPrefix : trimmed
            }
        )
    }

    /// 默认清单下拉的可选项。把「已选中但当前读不到」的值补进来，
    /// 否则（如授权被撤销后）selection 会指向不存在的 tag，界面显示成空白。
    private var todoListOptions: [String] {
        var names = reminders.listNames
        let current = todoDefaultList
        if !current.isEmpty && !names.contains(current) { names.insert(current, at: 0) }
        return names
    }

    /// 「跟随系统默认」那一项的文案（无清单名时不带括号后缀）。
    /// 用格式化模板而非字符串拼接 —— 全角括号写在 Swift 插值外侧会触发词法分析的嵌套计数问题
    /// （详见 MEMORY.md《Swift 语法坑》）。系统默认清单名本身不翻译：那是用户自己的清单名。
    private var followSystemLabel: String {
        guard let name = reminders.systemDefaultListName else {
            return L10n.t(.todoFollowSystemDefault)
        }
        return L10n.t(.todoFollowSystemDefaultNamed, name)
    }

    var body: some View {
        Form {
            Section(L10n.t(.settingsSectionModel)) {
                TextField("Base URL", text: $baseURL)
                SecureField("API Key", text: $apiKey)
                TextField("Model", text: $model)
            }
            systemPromptSection
            thinkingSection
            Section(L10n.t(.settingsSectionSearch)) {
                SecureField("Tavily API Key", text: $tavilyApiKey)
                Label(L10n.t(.settingsTavilyHelp), systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            todoSection
            Section(L10n.t(.settingsSectionGeneral)) {
                Picker(L10n.t(.languageLabel), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Label(L10n.t(.languageHelp), systemImage: "character.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle(L10n.t(.settingsLaunchAtLogin), isOn: launchAtLogin)
            }
            Section {
                Label(L10n.t(.settingsShortcutHotkey), systemImage: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Label(L10n.t(.settingsShortcutEnter), systemImage: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Label(L10n.t(.settingsShortcutAccessibility), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.top, 8)
        // 用户可能刚在「系统设置」里放开权限再回到这里 —— 不刷新就看不到状态变化。
        .onAppear { reminders.refreshStatus() }
    }

    // MARK: - 提醒事项（待办）

    /// 「提醒事项」配置区：授权状态 + 前缀触发 + 目标清单 + 回答按钮 + 签名注意事项。
    private var todoSection: some View {
        Section(L10n.t(.settingsSectionTodo)) {
            HStack {
                Text(L10n.t(.todoAuthLabel))
                Spacer()
                Text(reminders.authState.displayName)
                    .foregroundStyle(reminders.authState.isAuthorized ? Color.secondary : Color.orange)
            }

            HStack(spacing: 10) {
                if reminders.authState.isAuthorized {
                    Text(reminders.listNames.isEmpty
                         ? L10n.t(.todoAuthNoList)
                         : L10n.count(.todoAuthorizedListCountOne, .todoAuthorizedListCountOther,
                                      reminders.listNames.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button(L10n.t(.todoRequestAccess)) { reminders.requestAccess { _ in } }
                    Text(L10n.t(.todoFirstTimePrompt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.t(.todoOpenSystemSettings)) { RemindersStore.openPrivacySettings() }
                    .help(L10n.t(.todoOpenSystemSettingsHelp))
                    // 英文文案（"Open System Settings"）比中文长近一倍，不给固定尺寸会被
                    // 中间那段说明文字挤成 "Open System S…"（2026-09-22 快照取证发现）。
                    .fixedSize()
            }

            Toggle(L10n.t(.todoPrefixToggle), isOn: $todoPrefixEnabled)

            HStack {
                Text(L10n.t(.todoPrefixLabel))
                Spacer()
                TextField("", text: todoPrefixBinding)
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
                    .disabled(!todoPrefixEnabled)
            }

            Picker(L10n.t(.todoDefaultListLabel), selection: $todoDefaultList) {
                Text(followSystemLabel).tag("")
                ForEach(todoListOptions, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .disabled(!reminders.authState.isAuthorized)

            Toggle(L10n.t(.todoShowButtonToggle), isOn: $todoShowAnswerButton)

            Label(L10n.t(.todoUsageHelp, todoPrefix), systemImage: "checklist")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Label(L10n.t(.todoSigningHelp), systemImage: "signature")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 系统提示词

    /// 系统提示词配置区：开关 + 预设 + 多行编辑 + 恢复默认。
    /// 语义：内容以 system 角色置于 messages 首位，对每一次请求（含联网搜索）生效；
    /// 清空内容或关闭开关则不发送 system 消息。
    private var systemPromptSection: some View {
        Section(L10n.t(.settingsSectionSystemPrompt)) {
            Toggle(L10n.t(.systemPromptToggle), isOn: $systemPromptEnabled)

            Picker(L10n.t(.systemPromptPresetLabel), selection: presetBinding) {
                ForEach(Config.systemPromptPresets) { preset in
                    Text(preset.name).tag(preset.id)
                }
                Text(Config.customPresetName).tag(Self.customPresetTag)
            }
            .disabled(!systemPromptEnabled)

            TextEditor(text: systemPromptBinding)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 80)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .opacity(systemPromptEnabled ? 1.0 : 0.5)
                .disabled(!systemPromptEnabled)

            HStack {
                Button(L10n.t(.buttonRestoreDefault)) { systemPromptBinding.wrappedValue = Config.defaultSystemPrompt }
                    .disabled(systemPromptBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                              == Config.defaultSystemPrompt)
                Spacer()
                Text(L10n.count(.systemPromptCharCountOne, .systemPromptCharCountOther,
                                systemPromptBinding.wrappedValue.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Label(L10n.t(.systemPromptHelp), systemImage: "text.quote")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 思考模式

    /// 当前采样温度是否真的会随请求发送。
    /// 官方文档明确：思考模式下 `temperature` 不生效，故本工具在该模式下**不发送**；非 DeepSeek 端点
    /// 也不会启用思考模式，因此这时温度依然生效。
    private var temperatureApplies: Bool {
        !(thinkingEnabled && Config.isDeepSeekEndpoint)
    }

    /// 当前选中强度档位的说明文案。
    private var effortDetail: String {
        Config.reasoningEffortOptions.first(where: { $0.id == reasoningEffort })?.detail ?? ""
    }

    /// 思考模式与采样参数配置区。
    /// 字段语义严格对齐 DeepSeek 官方文档，逐条依据见 `Config` 与 `LLMClient.makeRequestBody` 的注释。
    private var thinkingSection: some View {
        Section(L10n.t(.settingsSectionThinking)) {
            Toggle(L10n.t(.thinkingToggle), isOn: $thinkingEnabled)
                .disabled(!Config.isDeepSeekEndpoint)

            Picker(L10n.t(.thinkingEffortLabel), selection: $reasoningEffort) {
                ForEach(Config.reasoningEffortOptions) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .disabled(!thinkingEnabled || !Config.isDeepSeekEndpoint)

            Text(effortDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("max_tokens")
                Spacer()
                TextField("", value: maxTokensBinding, format: .number)
                    .frame(width: 96)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: maxTokensBinding, in: 0...Config.maxTokensCeiling, step: 4096)
                    .labelsHidden()
            }

            Text(maxTokensOverride == 0
                 ? L10n.t(.thinkingMaxTokensAuto)
                 : L10n.t(.thinkingMaxTokensFixed, maxTokensOverride))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.t(.thinkingTemperatureLabel))
                    Spacer()
                    Text(String(format: "%.1f", temperature))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $temperature, in: 0...2, step: 0.1)
            }
            .disabled(!temperatureApplies)
            .opacity(temperatureApplies ? 1 : 0.5)

            Text(temperatureApplies
                 ? L10n.t(.thinkingTemperatureActiveHelp)
                 : L10n.t(.thinkingTemperatureInactiveHelp))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Label(L10n.t(.thinkingSectionHelp), systemImage: "brain")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !Config.isDeepSeekEndpoint {
                Label(L10n.t(.thinkingNonDeepSeekWarning), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }
}
