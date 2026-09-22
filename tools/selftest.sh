#!/bin/bash
# AI Quick Ask — 无头自检入口
#
#   ./tools/selftest.sh              纯逻辑断言（不联网，秒级）
#   AQA_LIVE=1 ./tools/selftest.sh   额外跑真实 API 抽取（需 AQA_KEY）
#
# 例：AQA_LIVE=1 AQA_KEY="$(defaults read com.aiquickask.app apiKey)" ./tools/selftest.sh
#
# 三条硬性约束（都是踩过的坑，改动本脚本时不要"简化"掉）：
#
# 1. 源文件列表**显式用数组逐个传入**。`SRC="a.swift b.swift"; swiftc $SRC` 不行 ——
#    zsh/bash 都不会在这里按空格拆分字符串，会把整串当成一个文件名。
# 2. 编译结果**不能接管道**。写成 `swiftc ... | head -5 && ./test` 时，管道的退出码
#    来自 head（恒为 0），swiftc 的失败被吞掉，于是静默复跑上一版旧二进制，
#    报出一份"全部通过"的假结果。所以这里先 rm -f 旧产物，再用 if ! 取真实退出码。
# 3. 源文件列表**必须包含 RemindersStore.swift** —— ChatViewModel 依赖其中的
#    RemindersError。漏掉会编译失败（由约束 2 保证会被发现，而不是被掩盖）。

set -u
cd "$(dirname "$0")/.." || exit 1

SOURCES=()
for f in Sources/AIQuickAsk/*.swift; do
    case "$f" in
        # 含 @main，与 tools/main.swift 的顶层测试代码冲突，必须排除
        *AIQuickAskApp.swift) continue ;;
    esac
    SOURCES+=("$f")
done
SOURCES+=("tools/main.swift")
# RemoteViewCrashGuard 依赖 ObjC 桥（ObjCExceptionCatcher）：.m 与桥接头必须一起编译
SOURCES+=("Sources/AIQuickAsk/ObjCExceptionCatcher.m")

OUT=/tmp/aqa-selftest
rm -f "$OUT"

# 与 Makefile 的 MACOS_MIN 保持一致，避免自检产物和正式产物的最低系统版本不同。
MACOS_MIN="${MACOS_MIN:-26.0}"
TARGET="$(uname -m)-apple-macos${MACOS_MIN}"

echo "编译中（${#SOURCES[@]} 个源文件，target ${TARGET}）…"
if ! swiftc "${SOURCES[@]}" -target "$TARGET" -import-objc-header Sources/AIQuickAsk/AIQuickAsk-Bridging-Header.h -o "$OUT"; then
    echo "❌ 编译失败 —— 不执行测试，避免复跑旧二进制报出假通过"
    exit 1
fi

echo "编译完成：$OUT"
"$OUT"
exit $?
