import SwiftUI
import AppKit

// MARK: - Markdown 块模型

/// 解析后的 Markdown 块（块级结构），行内格式（粗体/斜体/行内代码/链接）交给 AttributedString 处理。
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(language: String?, code: String)
    case listItem(ordered: Bool, index: Int?, text: String)
    case quote(text: String)
    case divider
}

// MARK: - 块级解析

/// 轻量 Markdown 解析器：行级状态机，天然容错（流式过程中代码块未闭合、段落未完成均可正确渲染）。
/// 支持：标题(#~######)、段落、围栏代码块(```)、无序/有序列表、引用(>)、分隔线(---/***)。
func parseMarkdown(_ source: String) -> [MarkdownBlock] {
    let lines = source.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var i = 0

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 1. 围栏代码块
        if trimmed.hasPrefix("```") {
            let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    break
                }
                codeLines.append(lines[i])
                i += 1
            }
            i += 1 // 跳过闭合的 ```
            blocks.append(.codeBlock(
                language: language.isEmpty ? nil : language,
                code: codeLines.joined(separator: "\n")
            ))
            continue
        }

        // 2. 标题
        if let heading = parseHeading(trimmed) {
            blocks.append(heading)
            i += 1
            continue
        }

        // 3. 分隔线（在列表前判断，避免 `- - -` 被误判为列表）
        if isDivider(trimmed) {
            blocks.append(.divider)
            i += 1
            continue
        }

        // 4. 引用
        if trimmed.hasPrefix(">") {
            let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            blocks.append(.quote(text: text))
            i += 1
            continue
        }

        // 5. 列表项
        if let item = parseListItem(trimmed) {
            blocks.append(item)
            i += 1
            continue
        }

        // 6. 空行
        if trimmed.isEmpty {
            i += 1
            continue
        }

        // 7. 段落（收集连续的非特殊行）
        var paraLines: [String] = [line]
        i += 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("```") || t.hasPrefix("#") || t.hasPrefix(">")
                || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")
                || isOrderedListItem(t) || isDivider(t) {
                break
            }
            paraLines.append(lines[i])
            i += 1
        }
        blocks.append(.paragraph(text: paraLines.joined(separator: "\n")))
    }

    return blocks
}

private func parseHeading(_ trimmed: String) -> MarkdownBlock? {
    var level = 0
    for ch in trimmed {
        if ch == "#" { level += 1 } else { break }
    }
    guard level >= 1, level <= 6 else { return nil }
    let rest = trimmed.dropFirst(level)
    // 与 CommonMark 一致：# 后必须跟空格才算标题，避免「#话题」这类社交语境写法被误判为 H1
    guard rest.first == " " else { return nil }
    let text = String(rest).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return .heading(level: level, text: text)
}

private func isDivider(_ trimmed: String) -> Bool {
    guard trimmed.count >= 3 else { return false }
    let cleaned = trimmed
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "*", with: "")
        .replacingOccurrences(of: "_", with: "")
    return cleaned.isEmpty
}

private func parseListItem(_ trimmed: String) -> MarkdownBlock? {
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
        let text = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return .listItem(ordered: false, index: nil, text: text)
    }
    if let ordered = parseOrderedListItem(trimmed) {
        return ordered
    }
    return nil
}

private func parseOrderedListItem(_ trimmed: String) -> MarkdownBlock? {
    var digits = ""
    for ch in trimmed {
        if ch.isNumber { digits.append(ch) } else { break }
    }
    guard !digits.isEmpty, trimmed.hasPrefix(digits + ". ") else { return nil }
    let text = String(trimmed.dropFirst(digits.count + 2)).trimmingCharacters(in: .whitespaces)
    return .listItem(ordered: true, index: Int(digits), text: text)
}

private func isOrderedListItem(_ trimmed: String) -> Bool {
    var digits = ""
    for ch in trimmed {
        if ch.isNumber { digits.append(ch) } else { break }
    }
    return !digits.isEmpty && trimmed.hasPrefix(digits + ". ")
}

// MARK: - 渲染视图

/// 结果正文字色：RGB(25, 25, 25)
private let resultTextColor = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)

/// 结果正文字号：14pt
private let resultFontSize: CGFloat = 14

/// 结果正文行距：1.5 倍（SwiftUI 默认行高约 1.2 倍字号，补足差额部分即为 1.5 倍行距）
private let resultLineSpacing: CGFloat = resultFontSize * 0.3

/// 结果正文字体：系统字体 14pt（跟随系统默认字体栈，默认常规字重）
private func resultFont(weight: Font.Weight = .regular) -> Font {
    .system(size: resultFontSize, weight: weight)
}

/// 把 Markdown 文本渲染为 SwiftUI 视图（流式输出时随内容增量刷新，容错未闭合结构）。
struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = parseMarkdown(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 容器级开启：标题/段落/列表/引用正文全部可选取复制（代码块内已单独开启）
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level))
                .lineSpacing(resultLineSpacing)
                .foregroundStyle(resultTextColor)
                .padding(.top, level <= 2 ? 4 : 0)

        case .paragraph(let text):
            Text(inline(text))
                .font(resultFont())
                .lineSpacing(resultLineSpacing)
                .foregroundStyle(resultTextColor)

        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)

        case .listItem(let ordered, let index, let text):
            HStack(alignment: .top, spacing: 8) {
                Text(ordered ? "\(index ?? 1)." : "•")
                    .font(resultFont())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(inline(text))
                    .font(resultFont())
                    .lineSpacing(resultLineSpacing)
                    .foregroundStyle(resultTextColor)
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(inline(text))
                    .font(resultFont())
                    .foregroundStyle(.secondary)
                    .lineSpacing(resultLineSpacing)
            }

        case .divider:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(resultFont())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: resultFontSize, design: .monospaced))
                    .lineSpacing(resultLineSpacing)
                    .foregroundStyle(resultTextColor)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(.vertical, 2)
    }

    /// 行内 Markdown（粗体/斜体/行内代码/链接）→ AttributedString。
    private func inline(_ text: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: opts) {
            return attributed
        }
        return AttributedString(text)
    }

    /// 标题字体：与正文一致（14pt 常规字重，不加粗），仅以上方留白区分层级。
    private func headingFont(_ level: Int) -> Font {
        _ = level
        return resultFont()
    }
}
