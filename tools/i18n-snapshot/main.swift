import AppKit
import SwiftUI

// i18n 视觉验证 harness：把设置页在「简体中文 / 英文」两种语言下各栅格化两张 PNG
// （顶部 + 滚到底部）——「通用」分区里的语言下拉在页面底部，只看顶部会漏掉。
//
// 目的不是像素比对，而是回答几个只有看图才知道的问题：
//   1. 英文文案普遍更长（如 "Show “Save as Reminder” under answers"），会不会把行挤坏 / 截断？
//   2. 新增的「语言 / Language」下拉是否真的渲染出来、默认值是不是「跟随系统」？
//   3. 英文的计数文案单复数是否正确（1 source / 126 characters）？
//
// 踩过的坑（照抄 MEMORY.md《视觉取证方法论》）：
//   - NSHostingView 直接当 contentView 会把窗口重置成内容自然高度，
//     必须在 SwiftUI 侧显式 .frame(width:height:) 固定，并打印实际 frame 自检；
//   - ImageRenderer 离屏渲染会得到空白，必须走窗口 + cacheDisplay；
//   - 顶部胶囊区 / Liquid Glass 无法栅格化 —— 本 harness 不含这些，不受影响。

let outputDir = "/tmp/aqa-i18n-shots"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)

let size = NSSize(width: 460, height: 1000)
var failures: [String] = []

/// 语言切换会写 UserDefaults（Config.appLanguage），先存后还原，别污染用户设置。
let originalChoice = L10n.shared.choice

func wait(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func firstScrollView(_ view: NSView) -> NSScrollView? {
    if let sv = view as? NSScrollView { return sv }
    for sub in view.subviews {
        if let hit = firstScrollView(sub) { return hit }
    }
    return nil
}

func countScrollViews(_ view: NSView) -> Int {
    var count = view is NSScrollView ? 1 : 0
    for sub in view.subviews { count += countScrollViews(sub) }
    return count
}

/// 把设置页滚到底部 —— 语言下拉所在的分区在最下面。
@discardableResult
func scrollToBottom(_ view: NSView) -> Bool {
    guard let sv = firstScrollView(view),
          let doc = sv.documentView else { return false }
    let clip = sv.contentView
    let y = doc.isFlipped ? max(0, doc.frame.height - clip.bounds.height) : 0
    clip.scroll(to: NSPoint(x: 0, y: y))
    sv.reflectScrolledClipView(clip)
    return true
}

func snapshot(_ language: AppLanguage, _ fileName: String, scrolledToBottom: Bool) -> Bool {
    L10n.shared.setChoice(language)
    wait(0.4) // 让 @Published 的变更先传播到视图

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let host = NSHostingView(rootView: SettingsView().frame(width: size.width, height: size.height))
    window.contentView = host
    // 再钉一次 frame：contentView 赋值有可能把窗口拉成内容的自然高度
    window.setFrame(NSRect(origin: .zero, size: size), display: true)
    window.makeKeyAndOrderFront(nil)
    wait(1.4) // 等 SwiftUI 完成首帧布局与滚动视图挂载

    if scrolledToBottom {
        if scrollToBottom(host) {
            wait(0.5)
        } else {
            print("  ✗ 找不到 NSScrollView，无法滚到底部")
            failures.append("\(fileName) 找不到设置页的 NSScrollView")
        }
    }

    guard let view = window.contentView else {
        print("  ✗ contentView 为空")
        window.orderOut(nil)
        return false
    }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        print("  ✗ 无法创建位图缓存")
        window.orderOut(nil)
        return false
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("  ✗ PNG 编码失败")
        window.orderOut(nil)
        return false
    }

    let path = outputDir + "/" + fileName
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        print("  ✗ 写盘失败：\(error.localizedDescription)")
        window.orderOut(nil)
        return false
    }

    // 自检：窗口实际 frame 要钉住，视图树里要有滚动视图
    let frame = NSStringFromRect(window.frame)
    let px = "\(rep.pixelsWide)x\(rep.pixelsHigh)"
    let scrollViews = countScrollViews(view)
    let suffix = scrolledToBottom ? "（已滚到底）" : "（顶部）"
    print("  frame=\(frame) 位图=\(px) NSScrollView=\(scrollViews)\(suffix) → \(path)")
    if rep.pixelsHigh < 500 {
        failures.append("\(fileName) 位图高度只有 \(rep.pixelsHigh)pt，疑似窗口被压成内容自然高度")
    }
    if scrollViews == 0 {
        failures.append("\(fileName) 没找到 NSScrollView —— 设置页应当由滚动视图承载")
    }
    window.orderOut(nil)
    return true
}

// MARK: - 面板快照

/// 构造一个「有对话 + 待办确认卡 + 结果提示条」的会话状态。
///
/// 这是面板里元素最密的一屏（输入栏 + 状态条 + 确认卡 + 消息流四层同时在场），
/// 英文文案变长后最容易在这里挤坏 —— 而面板宽 968pt，比设置页宽裕得多，
/// 所以它和设置页是两种不同的挤压风险，两边都要看。
func makePanelViewModel(_ language: ResolvedLanguage) -> ChatViewModel {
    let isEnglish = language == .en
    let vm = ChatViewModel()
    vm.messages = [
        ChatMessage(role: .user, content: isEnglish
                    ? "What changed in Swift 6 concurrency?"
                    : "Swift 6 的并发有什么改动？"),
        ChatMessage(role: .assistant,
                    content: isEnglish
                    ? "Swift 6 turns data-race safety into a language-level guarantee: strict concurrency checking is on by default, `Sendable` conformance is enforced across module boundaries, and actor isolation is checked at compile time."
                    : "Swift 6 把数据竞争安全提升为语言级保证：严格并发检查默认开启，`Sendable` 一致性跨模块强制校验，actor 隔离在编译期检查。",
                    sources: [
                        SourceItem(title: "Swift 6 released — swift.org", url: "https://swift.org/blog/"),
                        SourceItem(title: "Migrating to Swift 6 — swift.org", url: "https://swift.org/migration/")
                    ])
    ]
    vm.todoComposerVisible = true
    // 必须显式给一个存在于 `reminderListOptions` 里的清单名。
    // 真实流程里由私有的 `prepareListName()` 负责设置；harness 绕过它直接展开确认卡，
    // 若留空串则 Picker 的 selection 匹配不到任何 tag、渲染成一块空白胶囊 ——
    // 那是 harness 造成的假象，很容易被误读成产品 bug。
    vm.todoListName = L10n.t(.todoDefaultListName)
    vm.todoDraft = TodoDraft(
        title: isEnglish ? "Call Zhang back" : "给张工回电话",
        dueDate: Calendar.current.startOfDay(for: Date()),
        dueHour: 15,
        dueMinute: 0,
        reminderOffsetMinutes: 15,
        repeatRule: "weekly",
        priority: "high",
        notes: "",
        source: ""
    )
    vm.todoStatus = TodoStatus(
        text: isEnglish
            ? "Added · Tue, Sep 22 15:00 · Call Zhang back"
            : "已添加 · 9月22日 星期二 15:00 · 给张工回电话",
        undoID: "snapshot"
    )
    return vm
}

func snapshotPanel(_ language: AppLanguage, _ fileName: String) -> Bool {
    L10n.shared.setChoice(language)
    wait(0.4)

    let panelSize = NSSize(width: PopupPanel.width, height: PopupPanel.expandedHeight)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: panelSize),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    let vm = makePanelViewModel(L10n.shared.resolved)
    let host = NSHostingView(rootView: ContentView(viewModel: vm, onClose: {})
        .frame(width: panelSize.width, height: panelSize.height))
    window.contentView = host
    window.setFrame(NSRect(origin: .zero, size: panelSize), display: true)
    window.makeKeyAndOrderFront(nil)
    wait(1.4)

    guard let view = window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        print("  ✗ 面板快照失败")
        failures.append("\(fileName) 无法创建面板位图")
        window.orderOut(nil)
        return false
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        failures.append("\(fileName) PNG 编码失败")
        window.orderOut(nil)
        return false
    }
    do {
        try data.write(to: URL(fileURLWithPath: outputDir + "/" + fileName))
    } catch {
        failures.append("\(fileName) 写盘失败")
        window.orderOut(nil)
        return false
    }
    print("  frame=\(NSStringFromRect(window.frame)) 位图=\(rep.pixelsWide)x\(rep.pixelsHigh)"
          + "（面板：消息 + 状态条 + 确认卡）→ \(outputDir)/\(fileName)")
    if rep.pixelsHigh < 400 {
        failures.append("\(fileName) 位图高度只有 \(rep.pixelsHigh)pt，面板疑似被压扁")
    }
    window.orderOut(nil)
    return true
}

print("渲染设置页快照…")
var allOK = true
for (language, tag) in [(AppLanguage.zhHans, "zh-Hans"), (AppLanguage.en, "en")] {
    allOK = snapshot(language, "settings-\(tag)-top.png", scrolledToBottom: false) && allOK
    allOK = snapshot(language, "settings-\(tag)-bottom.png", scrolledToBottom: true) && allOK
}

print("渲染面板快照…")
for (language, tag) in [(AppLanguage.zhHans, "zh-Hans"), (AppLanguage.en, "en")] {
    allOK = snapshotPanel(language, "panel-\(tag).png") && allOK
}

L10n.shared.setChoice(originalChoice)
print("语言选择已还原为 \(originalChoice.rawValue)")

if failures.isEmpty && allOK {
    print("✅ 六张快照均已生成（设置页 ×4 + 面板 ×2）")
    exit(0)
}
for f in failures { print("❌ " + f) }
exit(1)
