import Foundation

/// 把自然语言抽成 `TodoDraft`。
///
/// 两条入口：
/// - `parse(text:)`：用户在输入框里以 `#todo` 写的一句话；
/// - `compress(question:answer:)`：把某条 AI 回答压缩成一条可执行待办。
///
/// 设计取舍：
/// - 抽取走**非流式**且**关闭思考**：这是确定性结构化任务，不是推理题；关思考能把
///   「加个待办还要等十几秒」的体感延迟压下来。
/// - 相对时间基准**复用 `ChatViewModel.buildDatePrompt`**，不另写一套 —— 那段逻辑已在
///   「联网查昨天事件算错日期」的排障中实测验证过，重复实现只会引入第二处漂移。
/// - 解析失败**一律降级为纯标题草稿**而不是报错：用户敲了 `#todo` 就是要记一件事，
///   因为模型抽不出日期就整条作废，体验上是不可接受的。
enum TodoParser {

    /// 备注正文的截断长度：回答可能上万字，备注塞满没意义也会拖慢写入。
    private static let notesLimit = 1800
    /// 回退标题的截断长度。
    private static let fallbackTitleLimit = 40

    // MARK: - 入口

    /// 从一句话抽取（`#todo` 前缀后的内容）。
    static func parse(text: String, now: Date = Date(),
                      language: ResolvedLanguage = L10n.shared.resolved,
                      completion: @escaping (TodoDraft) -> Void) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            completion(.empty)
            return
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": Prompts.todoExtractionRules(language)],
            ["role": "system", "content": ChatViewModel.buildDatePrompt(precise: true, now: now, language: language)],
            ["role": "user", "content": content]
        ]

        LLMClient.shared.complete(messages: messages, thinkingEnabled: false) { result in
            switch result {
            case .success(let raw):
                if var draft = decode(raw, now: now) {
                    draft.source = content
                    completion(draft)
                } else {
                    completion(fallback(content))
                }
            case .failure:
                completion(fallback(content))
            }
        }
    }

    /// 把「问题 + 回答」压缩成一条待办。
    ///
    /// 只让模型产出**标题** —— 备注里放回答原文由代码直接写入，不让模型转述，
    /// 避免长文在转述中被截断或改写。因此这条提示词明确禁用一切时间字段。
    static func compress(question: String, answer: String, now: Date = Date(),
                         language: ResolvedLanguage = L10n.shared.resolved,
                         completion: @escaping (TodoDraft) -> Void) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            completion(.empty)
            return
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": Prompts.todoCompressRules(language)],
            ["role": "system", "content": ChatViewModel.buildDatePrompt(precise: true, now: now, language: language)],
            ["role": "user", "content": Prompts.todoCompressUserContent(
                question: trimmedQuestion, answer: answer, language: language)]
        ]

        var base = fallback(trimmedQuestion)
        base.notes = Self.clamp(answer, limit: notesLimit)
        base.source = trimmedQuestion

        LLMClient.shared.complete(messages: messages, thinkingEnabled: false) { result in
            var draft = base
            if case .success(let raw) = result, let parsed = decode(raw, now: now), !parsed.title.isEmpty {
                draft.title = parsed.title
            }
            completion(draft)
        }
    }

    // MARK: - 降级路径

    /// 模型不可用 / 抽取失败时的兜底：整句原文当标题，不设任何时间字段。
    ///
    /// 刻意**不猜日期** —— 宁可留给用户在确认卡上手动补，也不要把「明天」猜成别的日子。
    static func fallback(_ text: String) -> TodoDraft {
        var draft = TodoDraft()
        draft.title = clamp(text, limit: fallbackTitleLimit)
        draft.source = text
        return draft
    }

    // MARK: - JSON 解析

    /// 解析模型返回的 JSON 文本（纯函数，便于无头断言）。
    /// 返回 nil 表示无法得到一条**有标题**的草稿 —— 由调用方决定降级。
    static func decode(_ raw: String, now: Date = Date()) -> TodoDraft? {
        guard let data = extractJSONObject(from: raw),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        var draft = TodoDraft()
        draft.title = clamp(title, limit: 120)

        var explicitDate = false
        if let day = obj["due_date"] as? String, let parsed = parseDay(day, now: now) {
            draft.dueDate = parsed
            explicitDate = true
        }
        if let time = obj["due_time"] as? String, let clock = parseTime(time) {
            draft.dueHour = clock.hour
            draft.dueMinute = clock.minute
        }

        // 「下午三点提醒我」不带日期时，时刻没有落点 —— 先补今天（下面的兜底再决定要不要顺延）。
        if draft.dueHour != nil && !explicitDate {
            draft.dueDate = Calendar.current.startOfDay(for: now)
        }

        // 兜底不变量：**绝不产出已经错过的提醒**。
        //
        // 有两种路径会踩到它，实测都复现过：
        // 1. 模型自己把日期填成「今天」（17:45 说「三点开会」→ 今天 15:00）；
        // 2. 上面的推断路径补了今天，而那个时刻已经过去。
        // 二者都表现为「刚建的提醒立刻过期」。只要时刻已过、且日期就是今天，就顺延一天 ——
        // 用户说的「三点」必然是「下一个三点」。用户若真要往期日期，确认卡上改即可。
        if let instant = draft.dueInstant, instant <= now,
           let due = draft.dueDate,
           Calendar.current.isDate(due, inSameDayAs: now),
           let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: due) {
            draft.dueDate = tomorrow
        }

        if let minutes = intValue(obj["reminder_offset_minutes"]) {
            draft.reminderOffsetMinutes = max(0, minutes)
        }
        if let repeatRule = obj["repeat"] as? String, TodoRepeat.options.contains(repeatRule) {
            draft.repeatRule = repeatRule
        }
        if let priority = obj["priority"] as? String, TodoPriority.options.contains(priority) {
            draft.priority = priority
        }
        draft.notes = (obj["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return draft
    }

    /// 容忍模型用 Markdown 代码块包裹、或在 JSON 前后夹杂说明文字 ——
    /// 直接截取首个 `{` 到末个 `}`，比要求模型绝对听话可靠得多。
    static func extractJSONObject(from raw: String) -> Data? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end]).data(using: .utf8)
    }

    private static func parseDay(_ text: String, now: Date) -> Date? {
        let primary = DateFormatter()
        primary.locale = Locale(identifier: "en_US_POSIX")
        primary.timeZone = .current
        primary.dateFormat = "yyyy-MM-dd"
        if let date = primary.date(from: text) {
            return Calendar.current.startOfDay(for: date)
        }
        // 兜底：容忍 "yyyy/MM/dd"
        let secondary = DateFormatter()
        secondary.locale = Locale(identifier: "en_US_POSIX")
        secondary.timeZone = .current
        secondary.dateFormat = "yyyy/MM/dd"
        guard let date = secondary.date(from: text) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              hour >= 0, hour <= 23, minute >= 0, minute <= 59 else { return nil }
        return (hour, minute)
    }

    /// JSON 里的数字可能是 Int 也可能是 Double（`30` 与 `30.0`），两种都要接。
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func clamp(_ text: String, limit: Int) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
