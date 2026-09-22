import AppKit
import SwiftUI
import ApplicationServices
import Combine

/// 应用主入口：无主窗口、无 Dock 图标，仅菜单栏图标 + 全局快捷键。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var panel: PopupPanel!
    private var settingsWindow: NSWindow?
    private let viewModel = ChatViewModel()
    /// 语言变更订阅（见 `applyLanguage`）。
    private var languageCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须最先执行：拦截 macOS 27 beta 的 NSRemoteView 断言，
        // 否则系统休眠唤醒后菜单栏场景重建时 App 会被 SIGABRT 杀掉。
        RemoteViewCrashGuard.install()

        NSApp.setActivationPolicy(.accessory)

        // 双击右侧 Command 需要「辅助功能」权限，首次启动引导授权
        requestAccessibilityIfNeeded()

        panel = PopupPanel(viewModel: viewModel)

        hotkeyManager = HotkeyManager()
        hotkeyManager.onTrigger = { [weak self] in self?.togglePanel() }
        hotkeyManager.register()

        setupStatusItem()

        // 语言一变，菜单项与已打开的设置窗口标题要跟着变 ——
        // NSMenu / NSWindow.title 都是 AppKit 对象，不会随 SwiftUI 的 ObservableObject 自动重绘。
        languageCancellable = L10n.shared.$resolved
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyLanguage() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloseRequest),
            name: .panelCloseRequested,
            object: nil
        )
    }

    /// 若未授权辅助功能，仅自动弹一次系统授权框（避免每次启动打扰）。
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasRequestedAccessibility") else { return }
        defaults.set(true, forKey: "hasRequestedAccessibility")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        refreshStatusItemChrome()
        statusItem.menu = buildMenu()
    }

    /// 状态栏图标单独刷新：`accessibilityDescription` 也是要本地化的文案。
    private func refreshStatusItemChrome() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: L10n.t(.appName)
        )
    }

    /// 构建菜单。
    ///
    /// 抽成独立方法是为了让语言切换时能整体重建 —— 菜单项文字是**构建时快照**的，
    /// 改语言不会自动跟着变；同时每次重建都从 `LoginItemManager` 重读登录项勾选状态，
    /// 不会把状态做丢。
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: L10n.t(.menuOpenPanel), action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let browser = NSMenuItem(title: L10n.t(.menuBrowser), action: #selector(openBrowser), keyEquivalent: "")
        browser.target = self
        menu.addItem(browser)

        let settings = NSMenuItem(title: L10n.t(.menuSettings), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let loginItem = NSMenuItem(title: L10n.t(.menuLaunchAtLogin), action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t(.menuQuit), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// 语言变更后同步 AppKit 侧的文案：状态栏图标无障碍描述 + 菜单 + 设置窗口标题。
    /// （设置窗口内容由 `SettingsView` 自行订阅 `L10n.shared` 重绘，这里只补标题。）
    private func applyLanguage() {
        refreshStatusItemChrome()
        statusItem.menu = buildMenu()
        settingsWindow?.title = L10n.t(.settingsWindowTitle)
    }

    // MARK: - 动作

    @objc private func openPanel() {
        panel.show()
    }

    /// 菜单栏「浏览器」：弹出面板并展开内嵌网页（默认落 Google 首页）。
    @objc private func openBrowser() {
        panel.show()
        guard let home = EmbeddedBrowserController.homeURL else { return }
        viewModel.openInBrowser(url: home)
    }

    private func togglePanel() {
        if panel.isVisible {
            // 已打开（即使被其他窗口盖住）→ 置顶 + 聚焦输入框
            panel.bringToFront()
        } else {
            panel.show()
        }
    }

    private func hidePanel() {
        panel.hide()
        // 关面板 = 整个会话作废（reset 内含内嵌网页的收起销毁，webview 不在后台常驻）
        viewModel.reset()
    }

    @objc private func handleCloseRequest(_ note: Notification) {
        hidePanel()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let newValue = !LoginItemManager.isEnabled
        LoginItemManager.setEnabled(newValue)
        sender.state = newValue ? .on : .off
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 1000),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = L10n.t(.settingsWindowTitle)
            win.minSize = NSSize(width: 460, height: 400)
            win.contentView = NSHostingView(rootView: SettingsView())
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
