# AI 快捷问答（macOS）

[English](README.md) | **简体中文**

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-blue)
![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![License](https://img.shields.io/badge/license-MIT-green)

一个 macOS 原生 AI 快捷问答工具：**无启动界面、无 Dock 图标**，常驻菜单栏，按全局快捷键弹出输入窗口，提交后**流式**显示大模型回答。

设计目标是「想到就问」——不切窗口、不找输入框、不选模型，**双击右侧 ⌘ Command** 直接开问。

- **纯原生**：SwiftUI + AppKit，符合 macOS 26 液态玻璃视觉，零第三方依赖
- **无 Xcode 依赖**：`swiftc` 直编，命令行 `make` 一条命令出 App
- **模型无关**：OpenAI 兼容接口，DeepSeek / 通义千问 / Kimi / OpenAI 等通用
- **中英双语**：界面支持简体中文 / English，切换即时生效、无需重启，发给模型的人设与提示词同步切换
- **可落地**：回答一键存为系统「提醒事项」，`#todo` 开头的一句话直接变提醒

---

## 特性

| 能力 | 说明 |
|------|------|
| **全局快捷键** | 双击右侧 ⌘ Command 弹出 / 收起，无需切换应用 |
| **流式输出** | SSE 逐字刷新，可中途停止；等待期间窗口边缘有流光指示 |
| **多轮对话** | 上下文累加，整篇历史按 OpenAI 规范回传 |
| **Markdown 渲染** | 标题 / 列表 / 表格 / 代码块 / 引用等块级结构 + 行内格式 |
| **系统提示词** | 可开关、可自定义，内置 6 套预设；支持多套人设切换 |
| **思考模式** | 对齐 DeepSeek 思考模型文档，可选强度，会话级临时切换 |
| **联网搜索** | 接入 Tavily，回答附参考来源（默认折叠，点击展开） |
| **内置浏览器** | 搜索结果与来源链接在面板内打开，不跳系统浏览器 |
| **Google 搜索** | 输入框内按 `⌘ Enter` 直接用 Google 搜索当前内容，结果在内置浏览器打开 |
| **提醒事项** | `#todo` 一句话创建系统提醒；回答可「存为待办」 |
| **时间感知** | 每次请求注入当前日期，修正模型对「今天 / 昨天」的误判 |
| **界面语言** | 简体中文 / English 可切换，改完即时生效、无需重启；发给模型的预设与提示词同步切换 |
| **开机自启** | LaunchAgent 实现，无需额外权限 |
| **无边框面板** | 液态玻璃背景，空白处可拖动，失焦自动收起 |

## 截图

填入 **Base URL / API Key / Model** 三项即可开始使用（下图为示例值）：

![模型接入设置](docs/settings-model.png)

---

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | **macOS 26.0 或更高** |
| 工具链 | Command Line Tools（`xcode-select --install`）—— 不需要完整 Xcode |

> **为什么要求 macOS 26？** 界面用到 `NSGlassEffectView`、`.buttonStyle(.glass)`、`onScrollGeometryChange` 等液态玻璃 API，且**未做 `#available` 降级**。若要支持更旧的系统，需要给这些调用补上降级分支。
>
> 最低版本在三个地方显式声明并保持一致：`Makefile` 的 `MACOS_MIN`、`Resources/Info.plist` 的 `LSMinimumSystemVersion`、`Package.swift` 的 `platforms`。

## 快速开始

### 构建与运行

```bash
git clone https://github.com/Atramp/Jarvis.git
cd Jarvis

make build     # 或 make run（构建并直接启动）
```

`make build` 等价于：

```bash
swiftc -O -target arm64-apple-macos26.0 Sources/AIQuickAsk/*.swift \
       Sources/AIQuickAsk/ObjCExceptionCatcher.m \
       -import-objc-header Sources/AIQuickAsk/AIQuickAsk-Bridging-Header.h \
       -o build/AIQuickAsk
```

> `-target` 不要省略：swiftc 会用**本机 SDK 版本**当前缀，导致同一份源码在不同机器上编出的 App 能跑的系统版本各不相同。
>
> 若你更习惯 SPM，也可以用 `swift build -c release`（产物在 `.build/release/`）。

### 打包为 .app（推荐）

```bash
make bundle      # 构建 → 打包 → 签名（产物 build/AIQuickAsk.app）
make install     # 再拷到 /Applications/AIQuickAsk.app 并热重启（推荐）
```

`make install` 是**推荐用法**：macOS 的隐私授权与磁盘路径绑定，把 `.app` 固定到 `/Applications` 后就不会因为 `make clean` 或移动目录而失效。它用 `ditto` 拷贝以保留签名封存的资源。

### 首次配置

1. 运行后菜单栏出现 ✨ 图标，**双击右侧 ⌘ Command** 弹出输入框。
2. 点菜单栏 ✨ →「设置…」（或 `⌘,`），填三项：

   | 字段 | 默认值 |
   |------|--------|
   | Base URL | `https://api.deepseek.com` |
   | API Key | 你的模型密钥 |
   | Model | `deepseek-flash` |

3. 回到输入框，输入问题回车，即可流式看到回答。

> **首次使用需要授权「辅助功能」**（系统设置 → 隐私与安全性 → 辅助功能），否则全局快捷键不生效。未授权时仍可点菜单栏 ✨ →「打开问答窗口」手动呼出。

---

## 使用

### 快捷键

| 操作 | 按键 |
|------|------|
| 弹出 / 收起输入窗 | 双击右侧 ⌘ Command |
| 提交问题 | 回车 |
| 切换思考模式 | `⌘T` |
| 切换联网搜索 | `⌘S` |
| Google 搜索输入内容 | `⌘ Enter` |
| 内嵌网页：后退 / 前进 | `⌘[` / `⌘]` |
| 收起内嵌网页（回对话） | `Esc` 或工具栏 ✕ |
| 停止生成 | 点击「停止」 |
| 关闭窗口 | `⌘W` / `Esc`（网页展开时先收网页） |

双击判定逻辑在 `Sources/AIQuickAsk/HotkeyManager.swift`：`rightCommandKeyCode`（右侧 Command = `0x36`）与 `doubleTapThreshold`（默认 0.35 秒）。

### 系统提示词

「设置…」→ **系统提示词（System Prompt）**，可自定义助手的角色与回答风格。

| 配置项 | 说明 |
|--------|------|
| 启用系统提示词 | 默认**开启**。关闭后本次起的所有请求都不再发送 system 消息 |
| 预设模板 | 内置「通用问答 / 简洁直答 / 严谨考证 / 翻译助手 / 代码助手 / 详尽解读」，选中即灌入输入框；手改内容后下拉自动显示「自定义」 |
| 提示词输入框 | 多行自由编辑，右下角显示字数 |
| 恢复默认 | 一键回到内置的「通用问答」文案 |

内容以 `system` 角色放在 `messages` **首位**；`/chat/completions` 是无状态 API，每轮都会重新注入。

> **想让它答得更长，改人设而不是改思考强度。** 实测换成「详尽解读」人设后回答字数从 880 涨到 2978（约 3.4 倍），而提高 `reasoning_effort` 只增加思考量、几乎不增加回答长度。详见 [思考模式与参数](docs/thinking-mode.md)。

### 思考模式

「设置…」→ **思考模式**，默认开启、强度 `high`、`max_tokens` 留 0（不发送，完全跟随服务端额度）。问答窗口内按 `⌘T` 可对当轮临时切换。

思考过程（`reasoning_content`）**不在界面展示** —— 它只影响 API 行为（答案质量与首字耗时），等待期间由窗口边缘流光统一指示状态。详见 [思考模式与参数](docs/thinking-mode.md)。

### 联网搜索

在设置里填入 Tavily API Key 后，问答窗口内按 `⌘S` 开启（**默认关闭**，且仅对当前对话有效）。开启后：

- 强制先搜索再回答，答案基于检索结果；
- 回答末尾附「参考来源 · N 条」，**默认折叠**，点击标题展开（逐条独立，不跨轮继承）；
- 来源条目在内置浏览器打开，悬停显示完整标题与 URL；
- 每条来源的正文摘要（截断 300 字）会一并带入上下文。

### 提醒事项（`#todo`）

在输入框以 `#todo` 开头写一句话，回车即创建系统「提醒事项」：

```
#todo 明天下午三点提醒我给张工回电话
```

流程是**抽取 → 确认 → 写入**：模型把自然语言抽成结构化字段，弹出确认卡供修改，确认后才经 EventKit 写入。几条刻意定死的规则：

- 只有日期没有时刻 = **全天提醒**，不硬塞 00:00；
- **绝不产出已经错过的提醒**（今天 + 已过的时刻会自动顺延一天）；
- 抽不出时间就只留标题，**不编造日期**。

另外每条 AI 回答下方有「存为待办」，模型只负责压缩标题，回答原文由程序直接写入备注。详见 [提醒事项](docs/todo.md)。

### 内置浏览器

`⌘Enter` 的搜索与「参考来源」的点击**都在面板内打开**，不跳系统默认浏览器（外跳只保留工具栏的 safari 按钮）。页面内链接、`target=_blank` 新标签都留在这个 webview 里，支持触摸板左右滑动前进 / 后退。

内存策略是**收起即销毁**：webview 整体析构，页面内存立即退出，反复开关无累积泄漏。

### 时间与日期

模型自身没有时钟，只能用训练语料的时间先验去猜「今天」，于是「昨天 / 最近」这类相对时间会整体算到错误日期上。本工具在每次请求中注入一条独立的 `system` 消息修正：

```
当前时间：2026-09-14 星期一（Asia/Shanghai，UTC+8）。
涉及「今天/昨天/明天/最近/前几天」等相对时间的表述，一律以上述时间为基准换算；
搜索结果未标明发布时间时，不要臆测日期。
```

默认**精确到「天」**（字符串一天内不变，前缀缓存命中最好）；仅当问题看起来在问「此刻」时才补上时分。关键词表**中英两套都查**（`现在 / 此刻 / 几点 / 刚刚` 与 `right now / what time / o'clock`），与界面语言无关 —— 中文界面里敲 "what time is it" 同样会拿到精确到分钟的时钟。

### 界面语言

界面提供**简体中文与英文**两套文案。设置 → 通用 → 语言可选「跟随系统 / 简体中文 / English」，切换**立即生效，无需重启**。

- **跟随系统**按顺序扫描 macOS 的语言偏好列表：任何 `zh*` 命中简体中文，`en*` 命中英文，其余（日语、德语等）回落简体中文（与 `CFBundleDevelopmentRegion` 一致）。繁体中文目前回落简体而不是英文 —— 还没有 `zh-Hant` 译文表。
- 本地化范围覆盖**界面文案与发给模型的文本两侧**。人设预设、联网搜索上下文、时间上下文、`#todo` 抽取提示词（含 few-shot 示例）都跟着界面一起切，英文界面下的模型行为与英文应用一致，而不是只有一层翻译壳。
- `#todo` 的时间表达解析与「精确时间」关键词表**中英输入都识别**，与界面语言无关。
- 模型**回答用什么语言**不由此开关决定，那是「系统提示词」的职责。

| 界面语言：简体中文 | 界面语言：English |
|---|---|
| ![语言设置，中文](docs/settings-language-zh.png) | ![语言设置，英文](docs/settings-language-en.png) |

译文放在 `Sources/AIQuickAsk/L10n.swift`（界面文案）与 `Sources/AIQuickAsk/Prompts.swift`（模型侧文本），而不是 `.lproj/Localizable.strings` —— 原因与新增文案的操作步骤见 [docs/i18n.md](docs/i18n.md)。

---

## 更换模型

在「设置」里改 Base URL / Model 即可，常见组合：

| 服务 | Base URL | Model |
|------|----------|-------|
| DeepSeek | `https://api.deepseek.com` | `deepseek-flash` |
| 通义千问 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus` |
| Kimi | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |

> `thinking` / `reasoning_effort` 是 DeepSeek 私有扩展字段，本工具**只对 `deepseek.com` 域名发送**，换其他服务商时自动跳过，避免严格校验未知字段的服务端直接返回 400。
>
> DeepSeek 的旧模型名 `deepseek-chat` 仍可调用，但会被路由到 `deepseek-flash` 并按该模型计费，建议直接用 `deepseek-flash`。

## 深入阅读

| 文档 | 内容 |
|------|------|
| [架构与实现要点](docs/architecture.md) | 项目结构、流式渲染策略、边缘流光算法、内嵌浏览器、状态管理约定 |
| [思考模式与参数](docs/thinking-mode.md) | `thinking` / `reasoning_effort` 配置、被移除的无效参数、实测数据 |
| [提醒事项](docs/todo.md) | `#todo` 三步链路、抽取效果实测、不变量规则 |
| [界面语言（i18n）](docs/i18n.md) | 为什么用 Swift 表而不是 `.lproj`、语言判定规则、哪些内容已/未本地化、新增文案怎么做 |
| [代码签名与隐私权限](docs/code-signing.md) | 为什么要自签名证书、TCC 授权为什么失效、完整修复步骤 |

## 自检

仓库自带无头断言，不联网、秒级：

```bash
./tools/selftest.sh                            # 纯逻辑断言（166 项）

# 额外跑真实 API 抽取（需要 API Key）
AQA_LIVE=1 AQA_KEY="$(defaults read com.aiquickask.app apiKey)" ./tools/selftest.sh
```

覆盖前缀匹配边界、`TodoDraft` ↔ EventKit 字段映射（含全天语义）、`TodoParser` 的 JSON 解码与「绝不产出已错过提醒」不变量、请求体组装，以及本地化表（两语言键全覆盖、无空串、`%d`/`%@` 占位符数量一致，并扫描确认英文表里没有漏译的中文）。

`tools/` 下还有几个用于验证不可见行为的 harness（手动编译运行，不入 `make` 链）：`browser-perf-harness.swift`（内嵌浏览器内存与启动耗时）、`glow-verify/`（边缘流光几何与速度测量）、`i18n-snapshot/`（把设置页在两种语言下各渲染成 PNG —— 英文按钮被挤成 "Open System S…" 的截断就是它抓出来的）。

## 权限与代码签名

本工具用到两类隐私权限：**辅助功能**（全局快捷键）与**提醒事项**（写入待办）。

macOS 把权限授予绑定在**「代码签名 + Bundle ID + 磁盘路径」三者的组合**上。未签名的产物每次重新编译 cdhash 都会变，系统视其为全新的 App，授权随之失效 —— 表现为「双击快捷键没反应」或「授权弹窗不再出现」。

**自签名证书即可解决**，不需要 Apple 开发者账号，约 2 分钟。完整可复现的命令见 [代码签名与隐私权限](docs/code-signing.md)。

```bash
make bundle SIGN_IDENTITY="你的证书名"   # 找不到证书时不报错，仅跳过签名并提示后果
```

## 已知限制

- **仅支持 macOS 26+**，且未做旧系统降级分支。
- **界面目前只有简体中文与 English 两套译文。** 繁体中文会归到简体（尚无 `zh-Hant` 表），而不是英文。
- **思考参数只对 DeepSeek 端点发送**（按域名白名单判断），将来若需可配置需改动 `Config.isDeepSeekEndpoint`。
- **联网搜索默认关闭**，且需要自备 Tavily API Key。
- **Tavily 常规搜索不返回发布时间**，因此「某条新闻是不是昨天的」往往无法从结果本身证实（可在 `TavilyClient` 请求体加 `"topic": "news"` 与 `"days": N` 切换）。
- 配置保存在本机 `UserDefaults`（键名见 `Config.swift`），**API Key 以明文存储**，不经过任何第三方。

## 贡献

欢迎 Issue 与 PR。改动前建议先跑一遍 `./tools/selftest.sh`；涉及构建脚本（`Makefile`）的改动请留意文件内的注释 —— 里面记录了若干踩过的坑（`find-identity` 不能加 `-v`、签名必须在写 Info.plist 之后等），不要「简化」掉。

## License

[MIT](LICENSE)
