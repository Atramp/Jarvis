// 浏览器内存行为验证 harness（tools/ 下，手动编译运行，不入 make 链）
// 适配内嵌 webview 版（BrowserWindow.swift 的 EmbeddedBrowserController）：
//   load(example.com) → 采样 → teardown → 采样，跑两轮验证「关闭即销毁、无累积泄漏」。
// 采样口径：本进程 phys_footprint；全系统 com.apple.WebKit* 子进程 PID 集合差值（归属本会话）。
// 编译：rm -f /tmp/aqa-perf && swiftc -O Sources/AIQuickAsk/BrowserWindow.swift tools/browser-perf-harness.swift -o /tmp/aqa-perf
// 注意：harness 文件改名为 main.swift 才能放顶层语句编译（swiftc 单文件场景限 main.swift）。
import AppKit
import WebKit

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576.0 : -1
}

/// WebContent 是 XPC 服务（父进程为 launchd，无法按 PPID 关联）。
/// 沙箱里 ps 被禁用，改用 sysctl 枚举进程。p_comm 截断到 15 字符，
/// 只能匹配「com.apple.WebKit」前缀（覆盖 WebContent + Networking + GPU），
/// 归属判断靠「打开前基线 vs 打开后 vs 关闭后」的 PID 集合差值口径。
func webKitPids() -> Set<Int32> {
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

    var pids = Set<Int32>()
    for _ in 0..<3 {                       // ENOMEM 时按 110% 扩容重试（标准套路）
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = Array(repeating: kinfo_proc(), count: size / stride)
        var newSize = size
        let rc = sysctl(&name, 4, &buffer, &newSize, nil, 0)
        if rc == 0 {
            for p in buffer[0..<newSize / stride] {
                let comm = withUnsafeBytes(of: p.kp_proc.p_comm) { raw in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if comm.hasPrefix("com.apple.WebKit") { pids.insert(p.kp_proc.p_pid) }
            }
            return pids
        }
        size = size * 11 / 10
    }
    return []
}

func stage(_ name: String) {
    let f = String(format: "%.1f", footprintMB())
    print("[STAGE] " + name + "  footprint=" + f + "MB  webkitPids=" + String(webKitPids().count))
    fflush(stdout)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let ctrl = EmbeddedBrowserController.shared

var baselinePids: Set<Int32> = []
var ourPids: Set<Int32> = []

DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    baselinePids = webKitPids()
    stage("before      ")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    guard let url = URL(string: "https://www.example.com") else { exit(2) }
    ctrl.load(url)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
    ourPids = webKitPids().subtracting(baselinePids)
    stage("cycle1 load 新增子进程=" + String(ourPids.count))
}
DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    ctrl.teardown()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
    stage("cycle1 close 残留=" + String(webKitPids().intersection(ourPids).count))
}
// 第二轮：验证 webview 重建不累积内存、GPU/Networking 保活复用
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    guard let url = URL(string: "https://www.example.com") else { exit(2) }
    ctrl.load(url)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
    stage("cycle2 load ")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
    ctrl.teardown()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 19) {
    stage("cycle2 close 残留=" + String(webKitPids().intersection(ourPids).count))
    exit(0)
}
app.run()
