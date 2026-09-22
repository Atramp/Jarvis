# AI Quick Ask — 构建脚本

APP_NAME := AIQuickAsk
BUILD_DIR := build
BINARY := $(BUILD_DIR)/$(APP_NAME)
SOURCES := $(wildcard Sources/AIQuickAsk/*.swift)
# ObjC 源（ObjCExceptionCatcher）+ 桥接头：Swift 无法捕获 NSException，
# RemoteViewCrashGuard 拦截 macOS 27 beta 系统断言需要这层桥。
OBJC_SOURCES := $(wildcard Sources/AIQuickAsk/*.m)
BRIDGING_HEADER := Sources/AIQuickAsk/AIQuickAsk-Bridging-Header.h

# 代码签名身份名。可用 `make bundle SIGN_IDENTITY="自定义名称"` 覆盖。
#
# 为什么要签名：macOS 把「辅助功能」「提醒事项」等隐私授权绑定在
# 「代码签名 + Bundle ID + 磁盘路径」三者的组合上。未签名（或 adhoc 签名）的产物
# 每次重新编译 cdhash 都会变，系统就把它当成一个全新的 App —— 授权失效，严重时弹窗不再出现。
# 自签名证书即可（钥匙串访问 → 证书助理 → 创建证书 → 类型选「代码签名」），不需要 Apple 开发者账号。
SIGN_IDENTITY ?= AIQuickAsk Dev

# 最低系统版本。必须显式指定，否则 swiftc 会用**本机 SDK 版本**当前缀（minos），
# 于是同一份源码在不同机器上编出的 App 能跑的系统版本各不相同 ——
# 在老系统上要么被 LaunchServices 拒绝，要么运行时炸在缺失的 API 上。
#
# 26.0 是实测下限：代码用到 NSGlassEffectView、.buttonStyle(.glass)、
# onScrollGeometryChange（均为 macOS 26 液态玻璃 API），且未做 #available 降级。
# 若要支持更旧的系统，必须给这些调用补上 #available 分支。
MACOS_MIN ?= 26.0
TARGET := $(shell uname -m)-apple-macos$(MACOS_MIN)

.PHONY: build run bundle clean

# 直接用 swiftc 编译（无需 Xcode / SPM 构建系统，最稳）
build:
	@mkdir -p $(BUILD_DIR)
	swiftc -O -target $(TARGET) $(SOURCES) $(OBJC_SOURCES) -import-objc-header $(BRIDGING_HEADER) -o $(BINARY)
	@echo "✅ 编译完成：$(BINARY)（最低系统 macOS $(MACOS_MIN)）"

run: build
	$(BINARY)

# 打包为 .app（无 Dock 图标，带 AppIcon，可加入登录项）
bundle: build
	@mkdir -p $(BUILD_DIR)/$(APP_NAME).app/Contents/MacOS
	@mkdir -p $(BUILD_DIR)/$(APP_NAME).app/Contents/Resources
	@cp $(BINARY) $(BUILD_DIR)/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(BUILD_DIR)/$(APP_NAME).app/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUILD_DIR)/$(APP_NAME).app/Contents/Resources/
	@$(MAKE) --no-print-directory sign
	@echo "✅ 已生成 $(BUILD_DIR)/$(APP_NAME).app"
	@echo "   打开：open $(BUILD_DIR)/$(APP_NAME).app"
	@echo "   首次打开若提示未签名：右键 → 打开，或 xattr -dr com.apple.quarantine $(BUILD_DIR)/$(APP_NAME).app"

# 安装到 /Applications：TCC 授权与磁盘路径绑定，路径一旦固定就别再搬。
# 用 ditto（保留扩展属性与签名 sealed resources），不要用 cp -R。
# 另外：调试「提醒事项」必须跑 .app —— 裸二进制会被系统归因到父进程（终端），
# 授权记在终端名下、开关不生效。
# 流程：先杀运行中的实例（否则 ditto 后旧进程仍驻内存、open 只会激活旧进程），
# 再覆盖安装、重启新进程 —— 一次 make install 完成「编译→更新→热重启」。
install: bundle
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.5
	@rm -rf /Applications/$(APP_NAME).app
	@ditto $(BUILD_DIR)/$(APP_NAME).app /Applications/$(APP_NAME).app
	@echo "✅ 已安装到 /Applications/$(APP_NAME).app"
	@open /Applications/$(APP_NAME).app
	@echo "🔁 已重启应用（旧进程已终止，新进程已拉起）"

# 条件化签名：找不到证书就降级为「不签名」并说明后果，绝不中断构建。
# 注意签名必须在 Info.plist 写入**之后** —— 签名会绑定 Info.plist，
# 先签后改 plist 会让签名失效（连带权限用途说明读不到）。
#
# ⚠️ find-identity 这里**不能加 -v**。-v 是 "valid identities only"，
# 只列链到受信任锚（Apple 根）的证书；自签名证书永远不满足，
# 加了 -v 会导致证书明明在、签名却永久被跳过。
.PHONY: sign
sign:
	@if security find-identity -p codesigning 2>/dev/null | grep -q "$(SIGN_IDENTITY)"; then \
		codesign --force --timestamp=none --sign "$(SIGN_IDENTITY)" $(BUILD_DIR)/$(APP_NAME).app && \
		codesign --verify --verbose=2 $(BUILD_DIR)/$(APP_NAME).app && \
		echo "🔏 已签名（$(SIGN_IDENTITY)）—— 隐私授权可在重新编译后保留"; \
	else \
		echo "⚠️  未找到代码签名证书「$(SIGN_IDENTITY)」，本次未签名。"; \
		echo "   后果：「辅助功能」「提醒事项」等授权会在每次重新编译后失效，需要重新授权。"; \
		echo "   解决：钥匙串访问 → 证书助理 → 创建证书 → 类型选「代码签名」，"; \
		echo "         名称填「$(SIGN_IDENTITY)」（或自行指定后再 make bundle SIGN_IDENTITY=...）"; \
	fi

clean:
	rm -rf $(BUILD_DIR)
