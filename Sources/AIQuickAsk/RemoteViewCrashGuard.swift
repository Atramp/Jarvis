import AppKit
import ObjectiveC

/// macOS 27（Golden Gate）beta 的 ViewBridge 系统缺陷兜底。
///
/// 症状：系统休眠唤醒（或菜单栏场景重建、sheet 弹出等）时，App 无征兆退出。
/// 成因：`-[NSRemoteView containingWindowWillOrderOnScreen:]` 内部断言失败，
/// 抛出未捕获的 NSInternalInconsistencyException → SIGABRT。
/// 崩溃特征：EXC_CRASH (SIGABRT)，堆栈含
/// `_CFBundleGetValueForInfoKey → NSRemoteView containingWindowWillOrderOnScreen:
///  → NSSceneStatusItem _wakeStatusItem`。
/// Apple 已知问题（FB23642313 等，状态 Potential fix identified），
/// 正式修复前按社区验证过的方案打运行时补丁：仅吞掉这一类系统断言，
/// 其余异常原样抛出，不掩盖真 bug。系统修复后本补丁自然空转（无异常可吞）。
/// 参考：https://developer.apple.com/forums/thread/837342
enum RemoteViewCrashGuard {
    private static var isInstalled = false

    /// 在 applicationDidFinishLaunching 最开头调用。
    static func install() {
        guard shouldInstall, !isInstalled else { return }
        isInstalled = true
        swizzle()
    }

    /// 仅 macOS 27 受影响（beta 系统缺陷）；其他版本不碰系统私有类。
    private static var shouldInstall: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27
    }

    private static func swizzle() {
        // ViewBridge 是私有框架且按需加载：启动早期（尚未建窗口/菜单栏图标时）
        // NSRemoteView 类还没注册进 runtime，必须先强制加载，否则补丁静默空转。
        if NSClassFromString("NSRemoteView") == nil {
            Bundle(path: "/System/Library/PrivateFrameworks/ViewBridge.framework")?.load()
        }
        guard let cls = NSClassFromString("NSRemoteView") else { return }
        let sel = NSSelectorFromString("containingWindowWillOrderOnScreen:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }

        typealias OriginalFn = @convention(c) (AnyObject, Selector, NSWindow?) -> Void
        let originalIMP = method_getImplementation(method)
        let callOriginal = unsafeBitCast(originalIMP, to: OriginalFn.self)

        let guarded: @convention(block) (AnyObject, NSWindow?) -> Void = { receiver, window in
            guard let exception = ObjCExceptionCatcher.catchException({
                callOriginal(receiver, sel, window)
            }) else { return }

            let reason = exception.reason ?? ""
            if exception.name == .internalInconsistencyException, reason.contains("NSRemoteView") {
                FileHandle.standardError.write(Data("[RemoteViewCrashGuard] 已拦截系统断言: \(reason)\n".utf8))
            } else {
                exception.raise()
            }
        }

        method_setImplementation(method, imp_implementationWithBlock(guarded))
        FileHandle.standardError.write(Data("[RemoteViewCrashGuard] 已安装（macOS 27 系统缺陷兜底）\n".utf8))
    }
}
