import Foundation

/// LLM 调用错误（String 不满足 Error 协议，单独封装）。
enum LLMError: Error {
    case message(String)
}

/// 单个流式分片的增量内容。
///
/// DeepSeek 的自适应思考模型（如 `deepseek-flash`）会先推送 `reasoning_content`（思考过程，
/// 此时同一条 delta 的 `content` 为 JSON `null`），思考结束后再推送 `content`（正式回答）。
/// 两者必须分开累加：reasoning 只用于展示，绝不可回填进后续请求的 messages。
struct StreamDelta {
    var reasoning: String?
    var content: String?
}

/// OpenAI 兼容接口的流式客户端（SSE）。
/// 逐行解析 `data:` 事件，收到完整行立即回调（不等待空行分隔符），兼容 \n 与 \r\n 行尾，
/// 避免因分隔符不匹配导致的整段缓冲，从而降低「首字」延迟。
///
/// 线程模型：每次请求一个独立的 StreamState（buffer / errorBuffer / statusCode / 回调），
/// 只在其所属请求的 delegate 队列上访问；主线程与 delegate 队列通过 states 路由表 + lock 交接，
/// 按 task 身份路由——被取消/过期任务的迟到回调查不到 state，直接忽略。
/// 由此同时消除「解析状态跨线程读写竞态」与「旧任务迟到回调误触发」两类问题。
final class LLMClient: NSObject, URLSessionDataDelegate {
    static let shared = LLMClient()

    private var session: URLSession!

    /// 单次流式请求的解析状态（只在 delegate 队列上访问）。
    private final class StreamState {
        let onReasoning: (String) -> Void
        let onDelta: (String) -> Void
        let onDone: () -> Void
        let onError: (String) -> Void
        var buffer = Data()
        var errorBuffer = Data()
        var statusCode: Int?

        init(onReasoning: @escaping (String) -> Void,
             onDelta: @escaping (String) -> Void,
             onDone: @escaping () -> Void,
             onError: @escaping (String) -> Void) {
            self.onReasoning = onReasoning
            self.onDelta = onDelta
            self.onDone = onDone
            self.onError = onError
        }
    }

    /// task → state 路由表与当前任务（跨线程访问需持 lock）。
    private let lock = NSLock()
    private var states: [ObjectIdentifier: StreamState] = [:]
    private var currentTask: URLSessionDataTask?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        // 允许更多并发连接并复用（长连接），降低重复请求的建连开销
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /// 发起流式请求。
    /// - Parameter thinkingEnabled: 本会话是否启用思考模式（面板内可临时覆盖设置页默认值）。
    /// - Parameter onReasoning: 思考过程增量（`delta.reasoning_content`）；关闭思考模式后不再回调。
    /// - Parameter onDelta: 正式回答增量（`delta.content`）。
    func stream(
        messages: [[String: String]],
        thinkingEnabled: Bool,
        onReasoning: @escaping (String) -> Void,
        onDelta: @escaping (String) -> Void,
        onDone: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        cancel()

        guard !Config.apiKey.isEmpty else {
            onError(L10n.t(.errorMissingAPIKey))
            return
        }

        let base = Config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            onError(L10n.t(.errorInvalidBaseURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")
        // 明确声明 SSE，促使服务端/代理立即流式返回而非缓冲
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body = Self.makeRequestBody(
            messages: messages,
            model: Config.model,
            thinkingEnabled: thinkingEnabled,
            reasoningEffort: Config.reasoningEffort,
            maxTokensOverride: Config.maxTokensOverride,
            temperature: Config.temperature,
            isDeepSeek: Config.isDeepSeekEndpoint
        )
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let state = StreamState(onReasoning: onReasoning, onDelta: onDelta, onDone: onDone, onError: onError)
        let task = session.dataTask(with: request)
        lock.lock()
        states[ObjectIdentifier(task)] = state
        currentTask = task
        lock.unlock()
        task.resume()
    }

    // MARK: - 非流式补全（结构化抽取用）

    /// 独立的无 delegate 会话。
    ///
    /// 为什么不复用主 `session`：主会话带 `URLSessionDataDelegate`，且靠「task → StreamState」路由表
    /// 分发回调；若在同一会话上再挂一个 completion handler，同一个 task 会同时走 delegate 与 completion
    /// 两条路径，互相干扰且难以推理。独立会话让流式与非流式彻底隔离，各管各的。
    private lazy var plainSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()

    /// 一次性拿完整文本（非流式）。
    ///
    /// 用途：待办抽取这类「需要拿到完整 JSON 再解析」的场景 —— 流式分片对解析毫无帮助，
    /// 反而要多写一套增量拼装逻辑。
    /// - Parameter thinkingEnabled: 抽取任务建议传 `false`：这是确定性抽取而非推理题，
    ///   关掉思考能显著压低「加个待办还要等十几秒」的体感延迟。
    func complete(
        messages: [[String: String]],
        thinkingEnabled: Bool,
        onResult: @escaping (Result<String, LLMError>) -> Void
    ) {
        guard !Config.apiKey.isEmpty else {
            onResult(.failure(.message(L10n.t(.errorMissingAPIKey))))
            return
        }

        let base = Config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else {
            onResult(.failure(.message(L10n.t(.errorInvalidBaseURL))))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Config.apiKey)", forHTTPHeaderField: "Authorization")

        let body = Self.makeRequestBody(
            messages: messages,
            model: Config.model,
            thinkingEnabled: thinkingEnabled,
            reasoningEffort: Config.reasoningEffort,
            maxTokensOverride: Config.maxTokensOverride,
            temperature: Config.temperature,
            isDeepSeek: Config.isDeepSeekEndpoint,
            stream: false
        )
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = plainSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    onResult(.failure(.message(error.localizedDescription)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    onResult(.failure(.message(L10n.t(.errorNoResponse))))
                    return
                }
                guard let data = data else {
                    onResult(.failure(.message(L10n.t(.errorEmptyBody))))
                    return
                }
                guard http.statusCode == 200 else {
                    let detail = Self.parseErrorBody(data) ?? L10n.t(.errorHTTP, http.statusCode)
                    onResult(.failure(.message(detail)))
                    return
                }
                guard let text = Self.parseMessageContent(data) else {
                    onResult(.failure(.message(L10n.t(.errorParseFailed))))
                    return
                }
                onResult(.success(text))
            }
        }
        task.resume()
    }

    /// 从非流式响应里取 `choices[0].message.content`。
    /// 注意与流式的区别：非流式是 `message`，流式是 `delta` —— 字段名不同，不能照抄。
    private static func parseMessageContent(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }

    /// 组装 `/chat/completions` 请求体（纯函数，便于无头验证）。
    ///
    /// 依据 DeepSeek 官方文档现行版本，策略核心是**不发送无效参数**：
    /// - `thinking` / `reasoning_effort` 是 DeepSeek 私有扩展字段，**仅对 DeepSeek 端点发送**；
    ///   通义千问 / Kimi / OpenAI 等兼容服务若严格校验未知字段会直接 400，故按域名判定后跳过。
    /// - `temperature` 在思考模式下不生效（官方明确说明），因此**只在非思考模式下发送**；
    /// - `top_p` / `presence_penalty` / `frequency_penalty` **一律不发送**：前者的传入值在
    ///   非思考模式下被忽略（恒为 1.0）、在思考模式下有 0.95 下限，后两者官方已 deprecated；
    /// - `max_tokens` **仅在用户显式配置（> 0）时发送**。不发送时由服务端决定额度
    ///   （思考模式 64K，`effort=max` 时 128K），比此前硬编码的 16384 宽松得多，是「输出更详细」的直接保障。
    static func makeRequestBody(
        messages: [[String: String]],
        model: String,
        thinkingEnabled: Bool,
        reasoningEffort: String,
        maxTokensOverride: Int,
        temperature: Double,
        isDeepSeek: Bool,
        stream: Bool = true
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            "response_format": ["type": "text"]
        ]

        let thinkingActive = isDeepSeek && thinkingEnabled

        if isDeepSeek {
            body["thinking"] = ["type": thinkingEnabled ? "enabled" : "disabled"]
        }
        if thinkingActive {
            body["reasoning_effort"] = reasoningEffort
        } else {
            body["temperature"] = temperature
        }

        if maxTokensOverride > 0 {
            body["max_tokens"] = maxTokensOverride
        }

        return body
    }

    func cancel() {
        lock.lock()
        let task = currentTask
        currentTask = nil
        if let task {
            states[ObjectIdentifier(task)] = nil
        }
        lock.unlock()
        // 在锁外取消：task.cancel() 可能同步触发 delegate 回调，避免重入死锁
        task?.cancel()
    }

    // MARK: - 路由

    private func state(for task: URLSessionTask) -> StreamState? {
        lock.lock()
        defer { lock.unlock() }
        return states[ObjectIdentifier(task)]
    }

    private func removeState(for task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        states[ObjectIdentifier(task)] = nil
        if currentTask === task {
            currentTask = nil
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            state(for: dataTask)?.statusCode = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let st = state(for: dataTask) else { return }
        if let code = st.statusCode, code != 200 {
            st.errorBuffer.append(data)
            return
        }
        st.buffer.append(data)
        drain(st)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 已取消/过期任务的迟到回调：查不到 state，直接忽略
        guard let st = state(for: task) else { return }
        removeState(for: task)

        if let error = error {
            // 主动取消不算错误（cancel 时 state 已移除，正常到不了这里，双保险）
            if (error as NSError).code == NSURLErrorCancelled { return }
            let msg = error.localizedDescription
            DispatchQueue.main.async { st.onError(msg) }
            return
        }

        if let code = st.statusCode, code != 200 {
            let msg = Self.parseErrorBody(st.errorBuffer) ?? L10n.t(.errorHTTP, code)
            DispatchQueue.main.async { st.onError(msg) }
            return
        }

        // 最后一段可能没有换行符，补一次解析
        if !st.buffer.isEmpty {
            if let d = parseDelta(from: st.buffer) {
                if let r = d.reasoning { DispatchQueue.main.async { st.onReasoning(r) } }
                if let c = d.content { DispatchQueue.main.async { st.onDelta(c) } }
            }
            st.buffer.removeAll()
        }
        DispatchQueue.main.async { st.onDone() }
    }

    // MARK: - SSE 解析（逐行）

    /// 单趟扫描提取所有完整行（兼容 \n 与 \r\n 行尾），一次性移除已消费前缀，
    /// 避免逐行 removeSubrange 造成的 O(N²) 内存搬移；每个网络分片只回调一次，减少主线程抖动。
    /// 思考与正文分两路累加，各自聚合成一次回调。
    private func drain(_ st: StreamState) {
        var combinedReasoning = ""
        var combinedContent = ""
        let data = st.buffer
        var lineStart = data.startIndex
        var cursor = data.startIndex
        var consumedEnd: Data.Index?

        while cursor < data.endIndex {
            if data[cursor] == 0x0A {
                var lineEnd = cursor
                if cursor > lineStart, data[data.index(before: cursor)] == 0x0D {
                    lineEnd = data.index(before: cursor) // 去掉行尾 \r
                }
                if let d = parseDelta(from: data[lineStart..<lineEnd]) {
                    if let r = d.reasoning { combinedReasoning += r }
                    if let c = d.content { combinedContent += c }
                }
                lineStart = data.index(after: cursor)
                consumedEnd = lineStart
            }
            cursor = data.index(after: cursor)
        }

        if let end = consumedEnd {
            st.buffer.removeSubrange(data.startIndex..<end)
        }
        if !combinedReasoning.isEmpty {
            DispatchQueue.main.async { st.onReasoning(combinedReasoning) }
        }
        if !combinedContent.isEmpty {
            DispatchQueue.main.async { st.onDelta(combinedContent) }
        }
    }

    /// 解析单行 `data: {...}`，提取 `choices[0].delta` 中的思考过程与正文。
    /// 注意：思考阶段 `content` 是 JSON `null`（`as? String` 会得到 nil），
    /// 因此两个字段必须各自判空，不能再用「content 为空就丢弃整行」的旧逻辑。
    private func parseDelta(from lineData: Data) -> StreamDelta? {
        guard let line = String(data: lineData, encoding: .utf8),
              line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else { return nil }
        guard let d = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else { return nil }

        let reasoning = (delta["reasoning_content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let content = (delta["content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard reasoning != nil || content != nil else { return nil }
        return StreamDelta(reasoning: reasoning, content: content)
    }

    private static func parseErrorBody(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8)
    }
}
