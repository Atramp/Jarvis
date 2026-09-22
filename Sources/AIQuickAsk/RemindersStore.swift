import Foundation
import EventKit
import AppKit
import Combine

/// 「提醒事项」写入错误（String 不满足 Error 协议，单独封装 —— 与 TavilyError / LLMError 同一范式）。
enum RemindersError: Error {
    case message(String)
    case notAuthorized
}

/// 系统「提醒事项」的读写封装（EventKit）。
///
/// 设计说明：
/// - 声明为 `ObservableObject`，是为了让 **SettingsView 无需 `@State`** 就能拿到实时授权状态与清单列表
///   （本工程用 swiftc 直编，不加载 SwiftUIMacros 宏插件，视图层禁用 `@State`）。
/// - `EKEventStore` 只在主线程创建与访问：单例的首次访问来自主线程的 UI，故不会在后台线程建库。
final class RemindersStore: ObservableObject {
    static let shared = RemindersStore()

    /// 授权状态。`.authorized` 之外都要显式引导用户，不能静默失败。
    enum AuthState: Equatable {
        case notDetermined
        case denied
        case restricted
        case authorized

        var isAuthorized: Bool { self == .authorized }

        var displayName: String {
            switch self {
            case .notDetermined: return L10n.t(.authNotDetermined)
            case .denied: return L10n.t(.authDenied)
            case .restricted: return L10n.t(.authRestricted)
            case .authorized: return L10n.t(.authAuthorized)
            }
        }
    }

    /// 当前授权状态（变更后由 `refreshStatus()` 推送）。
    @Published private(set) var authState: AuthState = .notDetermined
    /// 可见的提醒事项清单名（已排序）。授权前为空。
    @Published private(set) var listNames: [String] = []

    private let store = EKEventStore()

    private init() {
        refreshStatus()
        // 用户在「系统设置」里改动授权后，EventKit 会发这个通知；顺带刷新清单。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeChanged),
            name: .EKEventStoreChanged,
            object: store
        )
    }

    @objc private func storeChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshStatus() }
    }

    // MARK: - 授权

    /// 重新读取授权状态与清单列表。面板/设置页每次出现时都应调用一次 ——
    /// 用户可能刚在「系统设置」里放开权限，不刷新就看不到变化。
    func refreshStatus() {
        authState = Self.currentAuthState()
        listNames = authState.isAuthorized ? fetchListNames() : []
    }

    private static func currentAuthState() -> AuthState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .authorized
        case .writeOnly: return .authorized // 提醒事项无「仅写入」档，防御性归并
        @unknown default: return .notDetermined
        }
    }

    /// 请求提醒事项全权限。已授权时直接回调成功，不重复弹窗。
    ///
    /// 注意：**Info.plist 缺 `NSRemindersFullAccessUsageDescription` 时系统会静默拒绝、不弹框**
    /// （表现为「点了没反应」），排查时先确认这个键、再怀疑代码。
    func requestAccess(completion: @escaping (Bool) -> Void) {
        if authState.isAuthorized {
            completion(true)
            return
        }
        store.requestFullAccessToReminders { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.refreshStatus()
                completion(granted)
            }
        }
    }

    /// 跳转到「系统设置 → 隐私与安全性 → 提醒事项」。被拒绝后唯一的人工补救入口。
    static func openPrivacySettings() {
        let raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 清单

    private func fetchListNames() -> [String] {
        store.calendars(for: .reminder)
            .map { $0.title }
            .sorted()
    }

    /// 系统默认清单名（「提醒事项」新建任务的落点）。
    var systemDefaultListName: String? {
        store.defaultCalendarForNewReminders()?.title
    }

    /// 解析目标清单：优先用户指定 → 系统默认 → 第一个可写清单。
    /// 一定要排除只读清单（订阅清单 `allowsContentModifications == false`），否则保存必失败。
    private func resolveCalendar(preferred name: String?) -> EKCalendar? {
        let calendars = store.calendars(for: .reminder)
        if let name, !name.isEmpty,
           let hit = calendars.first(where: { $0.title == name && $0.allowsContentModifications }) {
            return hit
        }
        if let fallback = store.defaultCalendarForNewReminders(), fallback.allowsContentModifications {
            return fallback
        }
        return calendars.first(where: { $0.allowsContentModifications })
    }

    // MARK: - 写入

    /// 把草稿写入提醒事项。**必须已授权**，否则直接失败（不做隐式弹窗，避免在写操作里夹一个模态框）。
    /// - Returns: 成功时回调提醒事项的 `calendarItemIdentifier`（用于撤销）。
    func create(_ draft: TodoDraft, listName: String?, completion: @escaping (Result<String, RemindersError>) -> Void) {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            completion(.failure(.message(L10n.t(.todoErrorEmptyTitle))))
            return
        }
        guard authState.isAuthorized else {
            completion(.failure(.notAuthorized))
            return
        }
        guard let calendar = resolveCalendar(preferred: listName) else {
            completion(.failure(.message(L10n.t(.todoErrorNoWritableList))))
            return
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        reminder.priority = TodoPriority.ekValue(draft.priority)
        let notes = draft.notesWithSource()
        if !notes.isEmpty { reminder.notes = notes }
        if let components = draft.dueDateComponents { reminder.dueDateComponents = components }
        if let alarmDate = draft.alarmDate { reminder.addAlarm(EKAlarm(absoluteDate: alarmDate)) }
        if let rule = draft.recurrenceRule { reminder.addRecurrenceRule(rule) }

        do {
            try store.save(reminder, commit: true)
            completion(.success(reminder.calendarItemIdentifier))
        } catch {
            completion(.failure(.message(error.localizedDescription)))
        }
    }

    /// 撤销：按标识删除刚创建的提醒事项。
    @discardableResult
    func remove(id: String) -> Bool {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        do {
            try store.remove(item, commit: true)
            return true
        } catch {
            return false
        }
    }
}
