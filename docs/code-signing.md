# 代码签名与隐私权限

本文说明本工具用到的两类 macOS 隐私权限，以及为什么**稳定的代码签名**是它们能持续生效的前提。若不打算使用「待办」功能，只需关注「辅助功能」一节。

## 用到的权限

| 权限 | 用途 | Info.plist 键 |
|------|------|---------------|
| 辅助功能（Accessibility） | 全局监听「双击右侧 ⌘ Command」 | 无需键 |
| 提醒事项（Reminders） | 写入待办 | `NSRemindersFullAccessUsageDescription`（macOS 14+）<br>`NSRemindersUsageDescription`（macOS 12–13） |

> **缺 `NSRemindersFullAccessUsageDescription` 时，系统是静默拒绝而不是弹授权框** —— 表现为「点了没反应」，极易误判成代码 bug。两个键都已写在 `Resources/Info.plist` 里。

## 为什么需要签名

macOS 把权限授予绑定在**「代码签名 + Bundle ID + 磁盘路径」三者的组合**上。未签名或 ad-hoc 签名的产物，每次重新编译 cdhash 都会变，系统视其为**一个全新的 App** —— 授权随之失效，严重时授权弹窗干脆不再出现。

这解释了两个常见现象：

- 双击右 Command 偶尔要重新授权；
- 只补了 `NSRemindersFullAccessUsageDescription` 却没签名，待办功能时灵时不灵。

**自签名证书即可解决**，不需要 Apple 开发者账号，约 2 分钟。

## 路线 A：命令行（可复现，推荐）

```bash
# 1) 生成带 codeSigning EKU 的自签名证书
#    必须用 /usr/bin/openssl（系统自带的 LibreSSL），它支持 -addext
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout /tmp/aqa.key -out /tmp/aqa.crt \
  -subj "/CN=AIQuickAsk Dev/O=AIQuickAsk/C=CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# 2) 打包 p12（用 LibreSSL 默认算法：证书 RC2-40 / 私钥 3DES / MAC SHA1，
#    正是 macOS 能读的那套。注意 -legacy 是 OpenSSL 3.x 才有的选项，
#    在 macOS 自带 LibreSSL 上会报 unknown option）
/usr/bin/openssl pkcs12 -export \
  -inkey /tmp/aqa.key -in /tmp/aqa.crt \
  -name "AIQuickAsk Dev" -out /tmp/aqa.p12 -passout pass:aqa

# 3) 导入登录钥匙串
#    -T /usr/bin/codesign 必须加，否则每次签名都会弹钥匙串授权框，
#    在非交互 shell 里会直接挂死
security import /tmp/aqa.p12 -k ~/Library/Keychains/login.keychain-db \
  -P aqa -T /usr/bin/codesign -T /usr/bin/security

# 4) 验证：应列出 "AIQuickAsk Dev"，后面带 (CSSMERR_TP_NOT_TRUSTED)
security find-identity -p codesigning

# 5) 清掉 /tmp 里的明文私钥
rm -f /tmp/aqa.key /tmp/aqa.crt /tmp/aqa.p12
```

### 几个实测确认过的事实

- **`CSSMERR_TP_NOT_TRUSTED` 不影响签名。** 自签名证书没链到 Apple 根，`find-identity` 必然给它挂这个标记，但 `codesign` 照样签成功、`codesign --verify` 照样 `valid on disk`。**不需要**去钥匙串里设「始终信任」。
- **`find-identity` 不要加 `-v`。** `-v` 是 *valid identities only*，只列链到受信任锚的证书 —— 自签名永远不满足，加了 `-v` 会看到 `0 valid identities found`，构建脚本据此判定「没证书」从而**永久跳过签名**。这是最容易踩的坑，`Makefile` 里已注释说明。
- **证书导出后 designated requirement 稳定。** 实测本产物的 DR 是
  `identifier "com.aiquickask.app" and certificate root = H"<证书哈希>"` ——
  只绑 Bundle ID 与证书，**不含路径、不含 cdhash**。所以重新编译、甚至把 `.app` 挪到别的目录，授权都不会失效。
- **自签名 ≠ 过 Gatekeeper。** `spctl -a -vv` 仍会 `rejected`，但本地产物没有 `com.apple.quarantine` 属性，双击照样能起，不需要右键 → 打开。

## 路线 B：钥匙串访问 GUI（备选）

1. 打开「钥匙串访问」→ 菜单「钥匙串访问 → 证书助理 → 创建证书」；
2. 名称填 `AIQuickAsk Dev`，**身份类型选「自签名根证书」，证书类型选「代码签名」**，创建。

两条路产出的证书等价；区别只在路线 A 可脚本化复现。

## 签名身份名可覆盖

```bash
make bundle SIGN_IDENTITY="你的证书名"
```

找不到证书时构建**不会失败**，只打印一段说明并跳过签名（功能可用，代价是权限在重编后失效）。

## 顺序很重要

**先写 Info.plist，再签名。** 签名会绑定 Info.plist，先签后改会让签名失效、连带权限用途说明读不到 —— 而缺 `NSRemindersFullAccessUsageDescription` 时系统是静默拒绝，极易误判成代码 bug。

`make bundle` 的实现已经保证了这个顺序（`cp Info.plist` → `make sign`）。

## 授权卡住时

权限卡死在「勾不动 / 不弹窗」时，重置该 App 的条目：

```bash
tccutil reset Accessibility com.aiquickask.app
tccutil reset Reminders     com.aiquickask.app
```

> `tccutil` 在 macOS 14+ 要求**调用方**（终端或你运行命令的那个 App）拥有「完全磁盘访问」权限，否则一律报
> `Operation not permitted from sandbox` —— 这个报错跟命令本身无关。
>
> 签名一旦换过身份，旧授权条目与新 App 就对不上了，此时**不重置也不会冲突**，直接让系统重新弹一次即可。

## 安装位置

TCC 授权与磁盘路径绑定，因此**把 `.app` 放在一个固定位置**再授权：

```bash
make install     # 构建 + 签名 + 拷贝到 /Applications/AIQuickAsk.app 并启动
```

> 调试提醒功能**必须跑 `make bundle` 后的 `.app`**。裸二进制会被系统归因到父进程（终端），授权记在终端名下、开关不生效。
