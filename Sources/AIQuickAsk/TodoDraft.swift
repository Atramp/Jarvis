import Foundation
import EventKit

/// 重复规则取值（存 UserDefaults / 走 JSON 用字符串，便于两条写入通路共用）。
enum TodoRepeat {
    static let none = "none"
    /// 下拉顺序。
    static let options: [String] = ["none", "daily", "weekly", "monthly", "yearly"]

    static func displayName(_ value: String) -> String {
        switch value {
        case "daily": return L10n.t(.todoRepeatDaily)
        case "weekly": return L10n.t(.todoRepeatWeekly)
        case "monthly": return L10n.t(.todoRepeatMonthly)
        case "yearly": return L10n.t(.todoRepeatYearly)
        default: return L10n.t(.todoRepeatNone)
        }
    }
}

/// 优先级取值。
///
/// 注意与 EventKit 的语义差异：本工具的 `priority` 是「重要程度」，
/// 而 `EKReminder.priority` 是数值优先级 —— **0 为无、(1…9) 数值越小越优先、5 为中**。
/// 映射关系集中在 `ekValue`，避免散落在各处。
enum TodoPriority {
    static let none = "none"
    static let options: [String] = ["none", "low", "medium", "high"]

    static func displayName(_ value: String) -> String {
        switch value {
        case "high": return L10n.t(.todoPriorityHigh)
        case "medium": return L10n.t(.todoPriorityMedium)
        case "low": return L10n.t(.todoPriorityLow)
        default: return L10n.t(.todoPriorityNone)
        }
    }

    /// 转 EventKit 的数值优先级。
    static func ekValue(_ value: String) -> Int {
        switch value {
        case "high": return 1
        case "medium": return 5
        case "low": return 9
        default: return 0
        }
    }
}

/// 一条待办草稿：LLM 从自然语言抽取的结果，也是面板内「确认卡」上可直接编辑的数据。
///
/// 刻意**与 EventKit 解耦** —— 该模型是两条写入通路（系统「提醒事项」、将来的「Microsoft To Do」）
/// 共用的中间表示，因此字段用中性的 `Date` / `Int` / `String` 表达，
/// 转换到具体平台类型的逻辑收敛在文件末尾的 extension 里。
struct TodoDraft: Equatable {
    /// 任务标题。已剥离时间词与「提醒我」这类口语。
    var title: String = ""
    /// 截止日（本地日历日）。nil = 不设截止。
    var dueDate: Date?
    /// 截止时刻。nil = 全天，不设具体时刻。
    var dueHour: Int?
    var dueMinute: Int?
    /// 相对截止时间**提前**多少分钟提醒。
    ///
    /// `nil` 与 `0` 语义相同，都是「到点提醒」—— 确认卡上的选择器把 nil 显示为「到点提醒」，
    /// 用户一旦交互就写成具体整数。之所以保留 nil，是为了让「模型没提提醒」与
    /// 「模型明确说了到点提醒」在数据层可区分。
    /// 注意：带具体时刻的提醒在「提醒事项」里**必然**会在该时刻响铃，不存在「有时刻但不提醒」。
    var reminderOffsetMinutes: Int?
    /// 见 `TodoRepeat`。
    var repeatRule: String = TodoRepeat.none
    /// 见 `TodoPriority`。
    var priority: String = TodoPriority.none
    /// 备注正文。
    var notes: String = ""
    /// 原始输入或来源问题，用于追溯（写入备注尾部）。
    var source: String = ""

    static let empty = TodoDraft()
}

// MARK: - EventKit 字段映射

extension TodoDraft {
    /// 是否带具体时刻（决定「全天提醒」还是「定时提醒」）。
    var hasTime: Bool { dueDate != nil && dueHour != nil }

    /// 截止时刻（仅当日期与时刻都存在）。用于算提前提醒的基准点。
    var dueInstant: Date? {
        guard let day = dueDate, let hour = dueHour else { return nil }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = dueMinute ?? 0
        comps.second = 0
        return cal.date(from: comps)
    }

    /// EventKit 的截止组件。
    ///
    /// 关键语义：**只有日期时不要带上时分** —— 那样会被系统当作「全天提醒」，
    /// 由「提醒事项 → 默认提醒时间」决定何时响铃。硬塞一个 00:00 会让提醒时间凭空变成午夜。
    var dueDateComponents: DateComponents? {
        guard let day = dueDate else { return nil }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        if let hour = dueHour {
            comps.hour = hour
            comps.minute = dueMinute ?? 0
        }
        comps.calendar = cal
        return comps
    }

    /// 闹钟时刻。
    ///
    /// 规则（与 `dueDateComponents` 配套，避免出现「没说要提醒却响了」）：
    /// - 有明确时刻 → 到点提醒；
    /// - 另外指定了「提前 N 分钟」→ 基准点前移 N 分钟；
    /// - **只有日期、没有时刻 → 不设闹钟**，交给系统的默认提醒时间。
    var alarmDate: Date? {
        guard let due = dueInstant else { return nil }
        if let offset = reminderOffsetMinutes {
            return due.addingTimeInterval(-Double(offset) * 60)
        }
        return due
    }

    /// EventKit 重复规则（不重复时为 nil）。
    var recurrenceRule: EKRecurrenceRule? {
        let frequency: EKRecurrenceFrequency
        switch repeatRule {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: return nil
        }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)
    }

    /// 落盘前补上来源追溯（备注为空时只放来源，非空时换行追加）。
    func notesWithSource() -> String {
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { return note }
        // 来源前缀随界面语言；来源正文（原问题/原句）保持用户原样，不翻译。
        let prefix = L10n.t(.todoNotesSourcePrefix)
        guard !note.isEmpty else { return prefix + src }
        return note + "\n\n" + prefix + src
    }

    /// 「9月15日 星期二 15:00 · 给张工回电话」——用于状态提示条与确认卡标题。
    var summary: String {
        guard let day = dueDate else { return title }
        let df = DateFormatter()
        df.locale = L10n.locale
        df.dateFormat = L10n.dayDateFormat
        var text = df.string(from: day)
        if let hour = dueHour {
            text += String(format: " %02d:%02d", hour, dueMinute ?? 0)
        }
        return text + " · " + title
    }
}
