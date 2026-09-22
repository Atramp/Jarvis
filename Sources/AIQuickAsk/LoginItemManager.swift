import Foundation
import Darwin

/// 管理「登录时启动」：通过 ~/Library/LaunchAgents 下的 LaunchAgent 实现，无需签名、无需辅助功能权限。
enum LoginItemManager {
    static let label = "com.aiquickask.app"

    private static var plistPath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("\(label).plist").path
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// 当前可执行文件路径（优先取 .app 内二进制，其次取启动参数并转绝对路径）。
    static var executablePath: String {
        if let p = Bundle.main.executablePath, !p.isEmpty {
            return p
        }
        let arg0 = CommandLine.arguments.first ?? ""
        return (arg0 as NSString).standardizingPath
    }

    static func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    // MARK: - 私有

    private static func enable() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]
        let dir = (plistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: plistPath, atomically: true)

        // 立即加载（先清理旧实例再 bootstrap）
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        _ = runLaunchctl(["bootstrap", "gui/\(uid)", plistPath])
    }

    private static func disable() {
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return nil
        }
        // 先在后台排空管道，再等待退出：若先 waitUntilExit，子进程输出填满管道缓冲（64KB）
        // 后会阻塞在 write 上，与本进程的 wait 互相等待造成死锁（launchctl 实际输出很小，防御性修复）。
        let handle = pipe.fileHandleForReading
        var output = Data()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = handle.availableData // 阻塞至有数据或 EOF
                if chunk.isEmpty { break }
                output.append(chunk)
            }
            drainGroup.leave()
        }
        p.waitUntilExit()
        drainGroup.wait() // 进程退出后管道写端关闭 → 读取循环收到 EOF 自然结束
        return String(data: output, encoding: .utf8)
    }
}
