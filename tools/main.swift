import Foundation
import EventKit

// AI Quick Ask — 无头自检
//
// 覆盖「不依赖网络」的纯逻辑：前缀匹配、TodoDraft ↔ EventKit 字段映射、
// TodoParser 的 JSON 解码与兜底、LLMClient 的请求体组装。
//
// 用法见 tools/selftest.sh：把本文件与 Sources 一起 swiftc 编译成独立可执行文件。
// 加 AQA_LIVE=1 可额外跑一遍真实 API 抽取（需要 AQA_KEY 环境变量）。
//
// 三个踩过的坑，改动本文件时务必保留对应防护：
// 1. 源文件列表必须显式逐个列出（zsh 不做单词拆分）；且必须包含 RemindersStore.swift
//    —— ChatViewModel 依赖其中的 RemindersError。
// 2. 编译命令不能接管道（`| head` 会吞掉非零退出码，静默复跑旧二进制报假通过）。
// 3. 断言里的消息不要用全角括号包插值 —— Swift 会把全角 `）` 计入插值嵌套层级，
//    报出误导性的 "cannot find ')' to match opening '(' in string interpolation"。

var passed = 0
var failed = 0

func check(_ ok: Bool, _ label: String) {
    if ok {
        passed += 1
    } else {
        failed += 1
        print("  ❌ " + label)
    }
}

func checkEq<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        print("  ❌ " + label)
        print("       期望 = " + String(describing: expected))
        print("       实际 = " + String(describing: actual))
    }
}

func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi
    return Calendar.current.date(from: c)!
}

func section(_ title: String) {
    print("\n▶ " + title)
}

// MARK: - 1. 前缀匹配

section("前缀匹配 Config.todoPrefixMatch")

Config.todoPrefixEnabled = true
Config.todoPrefix = "#todo"

checkEq(Config.todoPrefixMatch("#todo 买牛奶"), "买牛奶", "带空格命中并剥离")
checkEq(Config.todoPrefixMatch("#todo买牛奶"), "买牛奶", "无空格也命中 —— 中文没有词间空格")
checkEq(Config.todoPrefixMatch("  #todo   给张工回电话  "), "给张工回电话", "前后空白被裁掉")
checkEq(Config.todoPrefixMatch("#TODO 买牛奶"), "买牛奶", "大小写不敏感")
checkEq(Config.todoPrefixMatch("#todo"), "", "只有前缀返回空串 —— 意图明确但内容缺失")
checkEq(Config.todoPrefixMatch("#todo   "), "", "前缀加空白也返回空串")
check(Config.todoPrefixMatch("#todoist 买牛奶") == nil, "#todoist 不得命中 —— 前缀后紧跟 ASCII 字母")
check(Config.todoPrefixMatch("#todo1 买牛奶") == nil, "前缀后紧跟 ASCII 数字也不得命中")
check(Config.todoPrefixMatch("买牛奶 #todo") == nil, "前缀不在开头不命中")
check(Config.todoPrefixMatch("普通提问") == nil, "普通提问不命中")
check(Config.todoPrefixMatch("") == nil, "空输入不命中")
check(Config.todoPrefixMatch("#todos") == nil, "#todos 不得命中")
checkEq(Config.todoPrefixMatch("#todo 明天下午三点给张工回电话"), "明天下午三点给张工回电话", "完整需求句")
checkEq(Config.todoPrefixMatch("#todo 记一下：A（含全角括号）"), "记一下：A（含全角括号）", "正文含全角括号不被误处理")
checkEq(Config.todoPrefixMatch("#todo @张工 回电话"), "@张工 回电话", "前缀后紧跟 @ 符号应命中")

Config.todoPrefix = ""
checkEq(Config.todoPrefix, "#todo", "空前缀回落默认值 —— 否则会命中每一句话")

Config.todoPrefix = "#待办"
checkEq(Config.todoPrefixMatch("#待办 买牛奶"), "买牛奶", "自定义非 ASCII 前缀可用")
checkEq(Config.todoPrefixMatch("#todo 买牛奶"), nil, "换前缀后旧前缀不再命中")

Config.todoPrefix = "#todo"
Config.todoPrefixEnabled = false
check(Config.todoPrefixMatch("#todo 买牛奶") == nil, "总开关关闭后一律不命中")
Config.todoPrefixEnabled = true

// MARK: - 2. TodoDraft ↔ EventKit 字段映射

section("TodoDraft 字段映射")

var timed = TodoDraft()
timed.title = "给张工回电话"
timed.dueDate = day(2026, 9, 15)
timed.dueHour = 15
timed.dueMinute = 0

check(timed.hasTime, "有日期有时刻 → hasTime")
checkEq(timed.dueInstant, day(2026, 9, 15, 15, 0), "dueInstant 由日期 + 时刻拼成")

let timedComps = timed.dueDateComponents!
checkEq(timedComps.hour, 15, "有时刻时组件带 hour")
checkEq(timedComps.minute, 0, "有时刻时组件带 minute")

checkEq(timed.alarmDate, day(2026, 9, 15, 15, 0), "无提前量时闹钟即到点")

timed.reminderOffsetMinutes = 30
checkEq(timed.alarmDate, day(2026, 9, 15, 14, 30), "提前 30 分钟 → 闹钟前移 30 分钟")

timed.repeatRule = "weekly"
checkEq(timed.recurrenceRule?.frequency, .weekly, "每周 → EKRecurrenceFrequency.weekly")
timed.repeatRule = "none"
check(timed.recurrenceRule == nil, "不重复 → nil")

// 全天语义：这是最容易写错的一处
var allDay = TodoDraft()
allDay.title = "交周报"
allDay.dueDate = day(2026, 9, 18)

check(!allDay.hasTime, "只有日期 → hasTime 为 false")
check(allDay.dueInstant == nil, "只有日期 → 无 dueInstant")
check(allDay.alarmDate == nil, "只有日期 → 不设闹钟，交给系统默认提醒时间")

let allDayComps = allDay.dueDateComponents!
checkEq(allDayComps.hour, nil, "全天提醒的组件不得带 hour —— 硬塞 00:00 会把提醒挪到午夜")
checkEq(allDayComps.minute, nil, "全天提醒的组件不得带 minute")
checkEq(allDayComps.day, 18, "日期部分仍然正确")

var noDue = TodoDraft()
noDue.title = "随手记"
check(noDue.dueDateComponents == nil, "不设截止 → 组件为 nil")
check(noDue.alarmDate == nil, "不设截止 → 无闹钟")

section("TodoDraft 优先级与备注")

checkEq(TodoPriority.ekValue("high"), 1, "high → 1")
checkEq(TodoPriority.ekValue("medium"), 5, "medium → 5")
checkEq(TodoPriority.ekValue("low"), 9, "low → 9")
checkEq(TodoPriority.ekValue("none"), 0, "none → 0")
checkEq(TodoPriority.ekValue("垃圾值"), 0, "未知值回落 0")
checkEq(TodoRepeat.displayName("yearly"), "每年", "重复规则回显")

var noted = TodoDraft()
noted.notes = "带上合同"
noted.source = "#todo 给张工回电话"
checkEq(noted.notesWithSource(), "带上合同\n\n来源：#todo 给张工回电话", "备注与来源用空行分隔")
noted.notes = ""
checkEq(noted.notesWithSource(), "来源：#todo 给张工回电话", "无备注时只写来源")
noted.notes = "带上合同"
noted.source = ""
checkEq(noted.notesWithSource(), "带上合同", "无来源时不追加尾部")

checkEq(timed.summary.hasSuffix("· 给张工回电话"), true, "摘要以「· 标题」结尾")
check(timed.summary.contains("15:00"), "摘要含格式化后的时刻")
checkEq(allDay.summary.contains(":"), false, "全天提醒的摘要不含时刻")

// MARK: - 3. TodoParser.decode（JSON 解码 + 兜底不变量）

section("TodoParser.decode")

let now = day(2026, 9, 14, 17, 45)

let plain = """
{"title":"给张工回电话","due_date":"2026-09-15","due_time":"15:00","reminder_offset_minutes":30,"repeat":"none","priority":"high","notes":"带上合同"}
"""
let plainDraft = TodoParser.decode(plain, now: now)
checkEq(plainDraft?.title, "给张工回电话", "标题解析")
checkEq(plainDraft?.dueHour, 15, "时刻解析")
checkEq(plainDraft?.reminderOffsetMinutes, 30, "提前量解析")
checkEq(plainDraft?.priority, "high", "优先级解析")
checkEq(plainDraft?.notes, "带上合同", "备注解析")
checkEq(plainDraft?.dueDate, day(2026, 9, 15), "日期被归一到当天零点")

let fenced = """
好的，这是结果：
```json
{"title":"交周报","due_date":null,"due_time":null,"reminder_offset_minutes":null,"repeat":"weekly","priority":"none","notes":""}
```
"""
checkEq(TodoParser.decode(fenced, now: now)?.title, "交周报", "容忍 Markdown 代码块围栏")
checkEq(TodoParser.decode(fenced, now: now)?.repeatRule, "weekly", "围栏内字段照常解析")

let noisy = "分析如下 {" + "\"title\":\"买牛奶\"" + "} 以上。"
checkEq(TodoParser.decode(noisy, now: now)?.title, "买牛奶", "容忍 JSON 前后夹杂说明文字")

check(TodoParser.decode("完全不是 JSON", now: now) == nil, "非 JSON 返回 nil")
check(TodoParser.decode("{}", now: now) == nil, "缺 title 返回 nil")
check(TodoParser.decode("{\"title\":\"   \"}", now: now) == nil, "title 全空白返回 nil")
check(TodoParser.extractJSONObject(from: "没有花括号") == nil, "无花括号 → nil")

checkEq(TodoParser.decode("{\"title\":\"x\",\"repeat\":\"每小时\"}", now: now)?.repeatRule, "none", "非法 repeat 回落 none")
checkEq(TodoParser.decode("{\"title\":\"x\",\"priority\":\"紧急\"}", now: now)?.priority, "none", "非法 priority 回落 none")
checkEq(TodoParser.decode("{\"title\":\"x\",\"reminder_offset_minutes\":-60}", now: now)?.reminderOffsetMinutes, 0, "负数提前量被夹到 0")
checkEq(TodoParser.decode("{\"title\":\"x\",\"reminder_offset_minutes\":1440.0}", now: now)?.reminderOffsetMinutes, 1440, "Double 形式的数字也能接")
checkEq(TodoParser.decode("{\"title\":\"x\",\"due_time\":\"25:00\"}", now: now)?.dueHour, nil, "非法时刻被忽略")
check(TodoParser.decode("{\"title\":\"x\",\"due_date\":\"2026/09/15\"}", now: now)?.dueDate != nil, "容忍 yyyy/MM/dd 日期格式")

section("兜底不变量：绝不产出已经错过的提醒")

// 场景 1：模型自己把日期填成今天，而时刻已过（基准 09-14 17:45，说「三点开会」）
let missed = TodoParser.decode(
    "{\"title\":\"开会\",\"due_date\":\"2026-09-14\",\"due_time\":\"15:00\"}", now: now)
checkEq(missed?.dueDate, day(2026, 9, 15), "今天的时刻已过 → 自动顺延一天")
check((missed?.dueInstant ?? Date.distantPast) > now, "顺延后必须落在未来")

// 场景 2：只有时刻没日期 —— 推断路径补今天后同样要顺延
let timeOnly = TodoParser.decode("{\"title\":\"开会\",\"due_time\":\"15:00\"}", now: now)
checkEq(timeOnly?.dueDate, day(2026, 9, 15), "仅时刻且已过 → 先补今天再顺延")

// 场景 3：时刻尚未到，不得顺延
let laterToday = TodoParser.decode("{\"title\":\"开会\",\"due_time\":\"20:00\"}", now: now)
checkEq(laterToday?.dueDate, day(2026, 9, 14), "今天的时刻还没到 → 保持今天")

// 场景 4：明确指定的未来日期不受影响
let future = TodoParser.decode(
    "{\"title\":\"评审\",\"due_date\":\"2026-09-20\",\"due_time\":\"09:00\"}", now: now)
checkEq(future?.dueDate, day(2026, 9, 20), "未来日期不被顺延")

// 场景 5：往期日期不顺延 —— 用户显式要往期就尊重
let past = TodoParser.decode(
    "{\"title\":\"补记\",\"due_date\":\"2026-09-10\",\"due_time\":\"09:00\"}", now: now)
checkEq(past?.dueDate, day(2026, 9, 10), "往期日期不顺延 —— 只处理今天这一种情况")

// 场景 6：全天提醒（无时刻）不受顺延逻辑影响
let allDayToday = TodoParser.decode("{\"title\":\"交周报\",\"due_date\":\"2026-09-14\"}", now: now)
checkEq(allDayToday?.dueDate, day(2026, 9, 14), "无时刻的全天提醒不参与顺延")

section("TodoParser.fallback 与标题截断")

let fb = TodoParser.fallback("#todo 记得明天买牛奶")
checkEq(fb.title, "#todo 记得明天买牛奶", "兜底保留原文当标题")
check(fb.dueDate == nil, "兜底不猜日期")
check(fb.dueHour == nil, "兜底不猜时刻")
checkEq(fb.source, "#todo 记得明天买牛奶", "兜底记录来源")

let long = String(repeating: "测", count: 60)
checkEq(TodoParser.fallback(long).title.count, 41, "兜底标题截断到 40 字 + 省略号")
check(TodoParser.fallback(long).title.hasSuffix("…"), "截断后带省略号")

let longJSON = "{\"title\":\"" + String(repeating: "测", count: 200) + "\"}"
checkEq(TodoParser.decode(longJSON, now: now)?.title.count, 121, "模型返回的超长标题截断到 120 字 + 省略号")

// MARK: - 4. LLMClient.makeRequestBody

section("请求体组装 makeRequestBody")

func body(_ thinking: Bool, deepSeek: Bool, maxTokens: Int = 0, stream: Bool = true) -> [String: Any] {
    return LLMClient.makeRequestBody(
        messages: [["role": "user", "content": "hi"]],
        model: "deepseek-flash",
        thinkingEnabled: thinking,
        reasoningEffort: "high",
        maxTokensOverride: maxTokens,
        temperature: 0.2,
        isDeepSeek: deepSeek,
        stream: stream)
}

let tOn = body(true, deepSeek: true)
checkEq(tOn["thinking"] as? [String: String], ["type": "enabled"], "DeepSeek + 思考开 → thinking.enabled")
checkEq(tOn["reasoning_effort"] as? String, "high", "思考生效时发送 reasoning_effort")
check(tOn["temperature"] == nil, "思考模式下不得发送 temperature —— 官方明确不生效")
check(tOn["max_tokens"] == nil, "未显式配置时不发送 max_tokens")
check(tOn["top_p"] == nil, "top_p 一律不发送")
check(tOn["presence_penalty"] == nil, "presence_penalty 一律不发送")
check(tOn["frequency_penalty"] == nil, "frequency_penalty 一律不发送")
checkEq(tOn["stream"] as? Bool, true, "stream 默认 true")
checkEq(tOn["response_format"] as? [String: String], ["type": "text"], "response_format 固定 text")

let tOff = body(false, deepSeek: true)
checkEq(tOff["thinking"] as? [String: String], ["type": "disabled"], "DeepSeek + 思考关 → thinking.disabled")
checkEq(tOff["temperature"] as? Double, 0.2, "非思考模式才发送 temperature")
check(tOff["reasoning_effort"] == nil, "非思考模式不发 reasoning_effort")

let thirdParty = body(true, deepSeek: false)
check(thirdParty["thinking"] == nil, "第三方端点不发 thinking —— 未知字段可能被 400 拒绝")
check(thirdParty["reasoning_effort"] == nil, "第三方端点不发 reasoning_effort")
checkEq(thirdParty["temperature"] as? Double, 0.2, "第三方端点按非思考模式处理，发送 temperature")

let capped = body(true, deepSeek: true, maxTokens: 8000)
checkEq(capped["max_tokens"] as? Int, 8000, "显式配置时才发送 max_tokens")

let nonStream = body(false, deepSeek: true, stream: false)
checkEq(nonStream["stream"] as? Bool, false, "待办抽取走非流式，stream 可置 false")

// MARK: - 4. 参考来源默认折叠

section("参考来源默认折叠 ChatMessage.isSourcesExpanded")

let collapsedMsg = ChatMessage(role: .assistant, content: "回答")
check(collapsedMsg.isSourcesExpanded == false, "新消息默认折叠 —— 否则来源列表会常驻挤占正文版面")

let presetExpanded = ChatMessage(role: .assistant, content: "回答", isSourcesExpanded: true)
check(presetExpanded.isSourcesExpanded, "可显式构造为展开态 —— 保留给历史回放与测试")

let sourceVM = ChatViewModel()
sourceVM.messages = [
    ChatMessage(role: .assistant, content: "A", sources: [SourceItem(title: "t1", url: "https://a")]),
    ChatMessage(role: .assistant, content: "B", sources: [SourceItem(title: "t2", url: "https://b")])
]
sourceVM.toggleSourcesExpanded(id: sourceVM.messages[0].id)
checkEq(sourceVM.messages[0].isSourcesExpanded, true, "点击标题后该条展开")
checkEq(sourceVM.messages[1].isSourcesExpanded, false, "只翻转目标消息，不连带展开其它回答")
sourceVM.toggleSourcesExpanded(id: sourceVM.messages[0].id)
checkEq(sourceVM.messages[0].isSourcesExpanded, false, "再次点击可收起")
sourceVM.toggleSourcesExpanded(id: UUID())
checkEq(sourceVM.messages[0].isSourcesExpanded, false, "id 不存在时静默忽略，不崩溃不改状态")

// MARK: - 5. 本地化（i18n）

section("本地化 L10n")

// 本段会通过 L10n.setChoice 真的写 UserDefaults（那是 Config.appLanguage 的落盘通路），
// 所以先存后还原 —— 绝不能让跑一次自检就把用户的界面语言改掉。
let savedLanguageChoice = L10n.shared.choice

// 表 ↔ 枚举 的双向覆盖。
var orphanKeys = Set(L10n.table.keys)
for key in L10n.Key.allCases { orphanKeys.remove(key) }
check(orphanKeys.isEmpty,
      "表中不得有 Key 枚举之外的孤儿键：" + orphanKeys.map { $0.rawValue }.sorted().joined(separator: ","))
checkEq(L10n.table.count, L10n.Key.allCases.count,
        "每个 Key 都必须有条目 —— 漏掉会在界面上直接显示成 <key>")

var emptyEntries: [String] = []
for (key, entry) in L10n.table
where entry.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    || entry.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    emptyEntries.append(key.rawValue)
}
check(emptyEntries.isEmpty, "两种语言都不许是空串：" + emptyEntries.sorted().joined(separator: ","))

// 占位符一致性。英文模板漏了 %d/%@ 时 String(format:) 不报错、静默丢参数，
// 只会渲染成一句缺了数字的话 —— 必须在这里挡住。
let placeholderRegex = try! NSRegularExpression(pattern: "%[@dfs]")
func placeholders(_ text: String) -> [String] {
    let range = NSRange(text.startIndex..., in: text)
    return placeholderRegex.matches(in: text, options: [], range: range).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
    }
}
var arityMismatch: [String] = []
for (key, entry) in L10n.table where placeholders(entry.zh) != placeholders(entry.en) {
    arityMismatch.append(key.rawValue)
}
check(arityMismatch.isEmpty, "中英模板的占位符必须逐个一致：" + arityMismatch.sorted().joined(separator: ","))

// 语言判定（纯函数，偏好列表可注入）。
checkEq(ResolvedLanguage.resolve(.zhHans, preferred: ["en-US"]), .zhHans, "显式选中文时忽略系统偏好")
checkEq(ResolvedLanguage.resolve(.en, preferred: ["zh-Hans-CN"]), .en, "显式选英文时忽略系统偏好")
checkEq(ResolvedLanguage.resolve(.system, preferred: ["zh-Hans-CN", "en-US"]), .zhHans, "跟随系统：中文系统 → 中文")
checkEq(ResolvedLanguage.resolve(.system, preferred: ["en-US"]), .en, "跟随系统：英文系统 → 英文")
checkEq(ResolvedLanguage.resolve(.system, preferred: ["fr-FR", "en-GB"]), .en,
        "跟随系统：跳过不支持的语言继续往后找，而不是直接落默认值")
checkEq(ResolvedLanguage.resolve(.system, preferred: ["zh-Hant-TW"]), .zhHans,
        "繁体无译文表 → 回落简体，而不是英文")
checkEq(ResolvedLanguage.resolve(.system, preferred: ["ja-JP"]), .zhHans, "既非中英 → 回落产品主语言")
checkEq(ResolvedLanguage.resolve(.system, preferred: []), .zhHans, "偏好列表为空 → 回落简体")
checkEq(AppLanguage.from("en"), .en, "持久化值可还原")
checkEq(AppLanguage.from("klingon"), .system, "非法持久化值回落「跟随系统」")
checkEq(AppLanguage.from(nil), .system, "缺失持久化值回落「跟随系统」")

// 带参格式化实测。Int 在 64 位下的 C 变参提升是经典坑（%d 只读低 32 位），
// 这里把填充结果逐个锁死，改动格式化实现时会立刻暴露。
L10n.shared.setChoice(.zhHans)
checkEq(L10n.t(.errorHTTP, 404), "请求失败（HTTP 404）", "中文 %d 模板填充正常")
checkEq(L10n.t(.todoAdded, "9月15日 · 回电话"), "已添加 · 9月15日 · 回电话", "中文 %@ 模板填充正常")
checkEq(L10n.count(.sourcesCountOne, .sourcesCountOther, 3), "3 条", "中文计数模板填充正常")
checkEq(L10n.t(.systemPromptCustomPreset), "自定义", "中文语言下取到中文文案")

// 切语言立即生效（无需重启进程）。
L10n.shared.setChoice(.en)
checkEq(L10n.shared.resolved, .en, "setChoice 立即改变生效语言")
checkEq(L10n.t(.errorHTTP, 404), "Request failed (HTTP 404)", "英文 %d 模板填充正常")
checkEq(L10n.count(.sourcesCountOne, .sourcesCountOther, 1), "1 source", "英文计数为 1 时用单数模板")
checkEq(L10n.count(.sourcesCountOne, .sourcesCountOther, 3), "3 sources", "英文计数非 1 时用复数模板")
checkEq(L10n.t(.sendHelp).hasPrefix("Send"), true, "英文语言下取到英文文案")

// 渲染结果里不得出现缺键哨兵 `<key>`。
var missingRenders: [String] = []
for key in L10n.Key.allCases where L10n.t(key).hasPrefix("<") && L10n.t(key).hasSuffix(">") {
    missingRenders.append(key.rawValue)
}
check(missingRenders.isEmpty, "不得有渲染成 <key> 的缺键：" + missingRenders.joined(separator: ","))

// 漏译防线：英文表里不该出现任何中文字符。
// 比「逐个 key 目视检查」可靠得多 —— 复制中文条目后忘改是最常见的漏译形态，
// 而它在界面上表现得很自然（英文 UI 里冒出一句中文），没人会去点开每个界面看。
func containsCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
}
var cjkLeaks: [String] = []
for (key, entry) in L10n.table where containsCJK(entry.en) {
    cjkLeaks.append(key.rawValue)
}
if containsCJK(L10n.t(.errorHTTP, 404)) { cjkLeaks.append("errorHTTP(填充后)") }
check(cjkLeaks.isEmpty, "英文表里不得残留中文：" + cjkLeaks.sorted().joined(separator: ","))

// 人设预设：双语齐备、id 稳定、跨语言反查。
checkEq(Prompts.personaDefinitions.count, 6, "内置人设仍为 6 套")
checkEq(Config.presetID(for: Prompts.defaultSystemPrompt(.zhHans)), "general", "中文默认人设归属「通用问答」")
checkEq(Config.presetID(for: Prompts.defaultSystemPrompt(.en)), "general", "英文默认人设归属同一条 id")
check(Prompts.defaultSystemPrompt(.zhHans) != Prompts.defaultSystemPrompt(.en), "中英默认人设内容必须不同")
var personaMissing: [String] = []
for definition in Prompts.personaDefinitions
where definition.content(.zhHans).isEmpty || definition.content(.en).isEmpty
    || definition.name(.zhHans).isEmpty || definition.name(.en).isEmpty {
    personaMissing.append(definition.id)
}
check(personaMissing.isEmpty, "每套人设都必须有中英名称与内容：" + personaMissing.joined(separator: ","))

// 关键回归：切到英文后，中文预设内容必须仍能反查出 id。
// 只查当前语言的话，这里会全部错显成「自定义」。
let zhPersonaContent = Prompts.defaultSystemPrompt(.zhHans)
L10n.shared.setChoice(.en)
checkEq(Config.presetID(for: zhPersonaContent), "general", "英文界面下仍能反查中文预设内容")
checkEq(Config.presetName(for: zhPersonaContent), "General Q&A", "反查出的预设名用当前语言")
checkEq(Config.presetName(for: "我自己的提示词"), L10n.t(.systemPromptCustomPreset), "自写内容回显「自定义」")
check(Config.systemPromptPresets.allSatisfy { !containsCJK($0.name) },
      "英文界面下预设名不得残留中文")
check(Config.reasoningEffortOptions.allSatisfy { !containsCJK($0.name) && !containsCJK($0.detail) },
      "英文界面下思考强度档位的名称与说明不得残留中文")
check(!Config.systemPromptPresets.contains { containsCJK($0.content) },
      "英文界面下预设内容不得残留中文 —— 那是要直接发给模型的")
L10n.shared.setChoice(.zhHans)
check(Config.systemPromptPresets.contains { $0.name == "通用问答" }, "切回中文后预设名恢复中文")

// 提示词与时间上下文按语言出不同文案。
let fixedNow = day(2026, 9, 22, 15, 30)
let zhDatePrompt = Prompts.datePrompt(precise: false, now: fixedNow, language: .zhHans)
let enDatePrompt = Prompts.datePrompt(precise: false, now: fixedNow, language: .en)
check(zhDatePrompt.hasPrefix("当前时间："), "中文时间上下文用中文前缀")
check(enDatePrompt.hasPrefix("Current time:"), "英文时间上下文用英文前缀")
check(enDatePrompt.contains("Tuesday"), "英文时间上下文里的星期必须是英文")
check(ChatViewModel.buildDatePrompt(precise: false, now: fixedNow) == zhDatePrompt,
      "ChatViewModel.buildDatePrompt 默认转发到当前语言")
check(zhDatePrompt.contains("15:30") == false, "非精确模式不带时分 —— 保住前缀缓存")
check(Prompts.datePrompt(precise: true, now: fixedNow, language: .zhHans).contains("15:30"),
      "精确模式带时分")

// 精确时间关键词：中英词表都查，且英文不得被裸 now 误伤。
check(ChatViewModel.needsPreciseTime("现在几点"), "中文「几点」命中精确时间")
check(ChatViewModel.needsPreciseTime("what time is it"), "英文「what time」命中精确时间")
check(ChatViewModel.needsPreciseTime("right now"), "英文「right now」命中精确时间")
check(!ChatViewModel.needsPreciseTime("I know this one"), "「know」不得被裸 now 误命中")
check(!ChatViewModel.needsPreciseTime("帮我写一个快速排序"), "无关问题不命中")

// 待办抽取提示词：两种语言各成一套，且都要求输出 JSON。
check(Prompts.todoExtractionRules(.zhHans).contains("任务抽取器"), "中文抽取提示词")
check(Prompts.todoExtractionRules(.en).contains("task extractor"), "英文抽取提示词")
check(Prompts.todoCompressRules(.en).contains("JSON"), "英文压缩提示词仍要求 JSON")
check(Prompts.todoCompressUserContent(question: "Q", answer: "A", language: .en).hasPrefix("Question:"),
      "英文压缩问答对的字段名")
check(Prompts.todoCompressUserContent(question: "问", answer: "答", language: .zhHans).hasPrefix("问题："),
      "中文压缩问答对的字段名")

// 思考强度档位的显示名随语言走，但 id（发给 API 的取值）必须恒定。
L10n.shared.setChoice(.en)
checkEq(Config.reasoningEffortIDs, ["low", "high", "max"], "思考强度 id 不随语言变化")
check(Config.reasoningEffortName.hasPrefix("high"), "英文下 high 档显示名仍以 high 开头")
L10n.shared.setChoice(.zhHans)
check(Config.reasoningEffortName.contains("标准"), "中文下 high 档显示为「标准」")

// 数据层枚举的显示名也必须本地化 —— 它们直接出现在确认卡的下拉里。
L10n.shared.setChoice(.en)
checkEq(TodoRepeat.displayName("weekly"), "Weekly", "重复规则显示名随语言")
checkEq(TodoPriority.displayName("high"), "High", "优先级显示名随语言")
check(L10n.t(.todoNotesSourcePrefix).contains("Source"), "备注来源前缀随语言")
L10n.shared.setChoice(.zhHans)
checkEq(TodoRepeat.displayName("weekly"), "每周", "切回中文后重复规则恢复")
checkEq(TodoPriority.displayName("high"), "高", "切回中文后优先级恢复")

// 还原用户原本的语言选择。
L10n.shared.setChoice(savedLanguageChoice)
checkEq(L10n.shared.choice, savedLanguageChoice, "自检结束后语言选择已还原，不会污染用户设置")

// MARK: - 汇总

print("")
print("────────────────────────────────────────")
if failed == 0 {
    print("✅ 全部通过：" + String(passed) + " 项断言")
} else {
    print("❌ 失败 " + String(failed) + " 项 / 共 " + String(passed + failed) + " 项")
}

// MARK: - 6. 可选：真实 API 抽取（AQA_LIVE=1 时启用）

if ProcessInfo.processInfo.environment["AQA_LIVE"] == "1" {
    print("")
    print("▶ 真实 API 抽取（非流式 + 关闭思考）")

    guard let key = ProcessInfo.processInfo.environment["AQA_KEY"], !key.isEmpty else {
        print("  ⚠️  未提供 AQA_KEY，跳过")
        exit(failed == 0 ? 0 : 1)
    }
    Config.apiKey = key

    let cases: [(String, String)] = [
        ("明天下午三点提醒我给张工回电话", "给张工回电话"),
        ("每周一早上九点开周会", "开周会"),
        ("提醒我三天后交周报", "交周报")
    ]

    var cursor = 0
    func runNext() {
        guard cursor < cases.count else {
            exit(failed == 0 ? 0 : 1)
        }
        let todo = cases[cursor]
        cursor += 1
        let started = Date()
        TodoParser.parse(text: todo.0, now: Date()) { draft in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if draft.title.contains(todo.1) {
                passed += 1
                let extra = "  重复=" + draft.repeatRule
                    + " 优先级=" + draft.priority
                    + " 提前=" + String(describing: draft.reminderOffsetMinutes)
                print("  ✅ " + todo.0 + " → " + draft.summary + "  [" + String(ms) + "ms]" + extra)
            } else {
                failed += 1
                print("  ❌ " + todo.0 + " → 标题为「" + draft.title + "」，期望含「" + todo.1 + "」")
            }
            runNext()
        }
    }
    runNext()
    // 回调统一派发到主队列 —— 必须用 CFRunLoopRun 等待，DispatchSemaphore 会死锁。
    CFRunLoopRun()
} else {
    exit(failed == 0 ? 0 : 1)
}
