// 流光视觉取证 harness —— 用于调整 ContentView.edgeGlow 参数后的渲染层实测。
//
// 编译（源文件必须显式逐个列出；用 for+case 过滤会得到空数组，见 selftest.sh 注释）：
//   cd ai-quick-ask
//   BASE=(Sources/AIQuickAsk/AppDelegate.swift Sources/AIQuickAsk/BrowserWindow.swift \
//     Sources/AIQuickAsk/ChatViewModel.swift Sources/AIQuickAsk/Config.swift \
//     Sources/AIQuickAsk/HotkeyManager.swift Sources/AIQuickAsk/LLMClient.swift \
//     Sources/AIQuickAsk/LoginItemManager.swift Sources/AIQuickAsk/MarkdownRenderer.swift \
//     Sources/AIQuickAsk/ObjCExceptionCatcher.m Sources/AIQuickAsk/PopupPanel.swift \
//     Sources/AIQuickAsk/RemindersStore.swift Sources/AIQuickAsk/RemoteViewCrashGuard.swift \
//     Sources/AIQuickAsk/SettingsView.swift Sources/AIQuickAsk/TavilyClient.swift \
//     Sources/AIQuickAsk/TodoDraft.swift Sources/AIQuickAsk/TodoParser.swift)
//   swiftc "${BASE[@]}" Sources/AIQuickAsk/ContentView.swift tools/glow-verify/glow-harness.swift \
//     -import-objc-header Sources/AIQuickAsk/AIQuickAsk-Bridging-Header.h -o /tmp/glow-harness
//
// 运行（GLOW_OUT 指定帧输出目录）：
//   GLOW_OUT=/tmp/glow-frames-new /tmp/glow-harness
//
// 隔离变量对照法：把 ContentView.swift 复制成 /tmp/CV_base.swift，只改 cometLength 或
// cometPeriod 其中一个，用 /tmp/CV_base.swift 替换 BASE 列表里的 ContentView.swift 再编一份，
// 各抓 14 帧（覆盖一个完整周期）后对比「实测比值 vs 理论比值」—— 比重读代码可靠。
//
// 测量：
//   python tools/glow-verify/glow_measure.py /tmp/glow-frames-new   # 边缘覆盖比例
//   python tools/glow-verify/glow_speed.py  /tmp/glow-frames-new   # 彗头速度（需 timestamps.tsv）
//
// 注意：产物是真机窗口截图，流光像素会被色彩空间转换裁剪出 (255,0,255)/(255,0,0)，
// 分析时不要用「R-G 最大」定位彗头（见 glow_speed.py 头部说明）。

import SwiftUI
import AppKit

/// 流光参数调整后的视觉取证 harness：
/// 起两个真机窗口（展开 691 / 折叠 92），isStreaming = true 点亮流光，
/// 按固定间隔用 screencapture -l <WID> 抓帧，覆盖一整个周期（4.286s）。
@main
struct GlowHarness {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let outDir = ProcessInfo.processInfo.environment["GLOW_OUT"] ?? "/tmp/glow-frames"
        try? FileManager.default.removeItem(atPath: outDir)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        func makeWindow(height: CGFloat, tag: String, y: CGFloat) -> NSWindow {
            let vm = ChatViewModel()
            vm.isStreaming = true
            // 现场对齐：无消息时 VStack 自然高度仅约 70pt，流光会围成一块居中矮矩形；
            // 用户实际看到的是「有对话的展开态」，所以塞两条消息让 messageList(ScrollView) 撑满容器。
            vm.messages = [
                ChatMessage(role: .user, content: "流光参数核对用占位内容，用于撑开消息列表高度。"),
                ChatMessage(role: .assistant, content: "占位回答：用于让 ScrollView 占满容器，使边缘流光贴合窗口四边。"),
            ]
            // 关键：NSHostingView 作为 contentView 时会把窗口重置成内容自然高度（约 70pt），
            // 必须在外层固定 frame，否则 expand/collapse 会退化成同一个矮窗口，取证环境失真。
            let root = ContentView(viewModel: vm, onClose: {})
                .frame(width: PopupPanel.width, height: height)
            let hosting = NSHostingView(rootView: root)
            let size = NSSize(width: PopupPanel.width, height: height)
            hosting.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: y), size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = hosting
            w.setContentSize(size)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.orderFrontRegardless()
            print("[harness] \(tag) WID=\(w.windowNumber) 请求=\(Int(size.width))x\(Int(size.height)) 实际=\(Int(w.frame.width))x\(Int(w.frame.height))")
            return w
        }

        let expand = makeWindow(height: PopupPanel.expandedHeight, tag: "expand", y: 700)
        let collapse = makeWindow(height: PopupPanel.collapsedHeight, tag: "collapse", y: 120)

        // 周期 3.0/0.7 ≈ 4.286s；0.4s × 14 帧覆盖一整个周期还有余量
        // （screencapture 本身耗时，Timer 不补偿，故实际间隔更长 —— 每帧记录真实时间戳供测速用）。
        let frames = 14
        var i = 0
        var stampLog = ""
        let t0 = Date()
        let targets: [(String, NSWindow)] = [("expand", expand), ("collapse", collapse)]

        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
            print("[harness] frame \(i) 开始")
            for (tag, w) in targets {
                let elapsed = Date().timeIntervalSince(t0)
                stampLog += "\(tag)\t\(i)\t\(String(format: "%.4f", elapsed))\n"
                let path = "\(outDir)/\(tag)_f\(String(format: "%02d", i)).png"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(w.windowNumber), path]
                do {
                    try p.run()
                    p.waitUntilExit()
                    if p.terminationStatus != 0 {
                        print("[harness] snap \(tag) f\(i) exit=\(p.terminationStatus)")
                    } else if !FileManager.default.fileExists(atPath: path) {
                        print("[harness] snap \(tag) f\(i) 产物缺失")
                    }
                } catch {
                    print("[harness] snap \(tag) f\(i) 异常: \(error)")
                }
            }
            print("[harness] frame \(i) 完成")
            i += 1
            if i >= frames {
                t.invalidate()
                try? stampLog.write(toFile: "\(outDir)/timestamps.tsv", atomically: true, encoding: .utf8)
                print("[harness] 时间戳已写入 \(outDir)/timestamps.tsv")
                exit(0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        CFRunLoopRun()
    }
}
