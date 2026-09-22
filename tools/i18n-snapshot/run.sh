#!/bin/bash
# 编译并运行 i18n 视觉验证 harness。
#
#   ./tools/i18n-snapshot/run.sh
#   → /tmp/aqa-i18n-shots/settings-{zh-Hans,en}-{top,bottom}.png
#
# 为什么需要它：断言只能证明「字符串对」，证明不了「版面没被挤坏」。
# 英文文案普遍比中文长（"Open System S…" 就是这么被截断的），只有看图才知道。
#
# 三条与 selftest.sh 同源的硬性约束（改动本脚本时不要"简化"掉）：
# 1. 源文件列表用数组逐个累积 —— `SRC="a.swift b.swift"; swiftc $SRC` 不会按空格拆分；
# 2. 编译结果不接管道 —— `| head` 会吞掉非零退出码，静默复跑旧二进制报假通过；
# 3. 必须排除 AIQuickAskApp.swift（含 @main，与 harness 的顶层代码冲突）。

set -u
cd "$(dirname "$0")/../.." || exit 1

SOURCES=()
for f in Sources/AIQuickAsk/*.swift; do
    case "$f" in
        # 含 @main，与 harness 的顶层测试代码冲突，必须排除
        *AIQuickAskApp.swift) continue ;;
    esac
    SOURCES+=("$f")
done
# RemoteViewCrashGuard 依赖 ObjC 桥（ObjCExceptionCatcher）：.m 与桥接头必须一起编译
SOURCES+=("Sources/AIQuickAsk/ObjCExceptionCatcher.m")
SOURCES+=("tools/i18n-snapshot/main.swift")

# 与 Makefile 的 MACOS_MIN 保持一致，避免 harness 产物与正式产物的最低系统版本不同。
MACOS_MIN="${MACOS_MIN:-26.0}"
TARGET="$(uname -m)-apple-macos${MACOS_MIN}"

OUT=/tmp/aqa-i18n-shots-bin
rm -f "$OUT"

echo "编译中（${#SOURCES[@]} 个源文件，target ${TARGET}）…"
if ! swiftc "${SOURCES[@]}" -target "$TARGET" \
     -import-objc-header Sources/AIQuickAsk/AIQuickAsk-Bridging-Header.h -o "$OUT"; then
    echo "❌ 编译失败 —— 不执行，避免复跑旧二进制报出假结果"
    exit 1
fi

echo "编译完成：$OUT"
"$OUT"
exit $?
