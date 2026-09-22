import Foundation

/// 单条来源引用。
struct SourceItem: Equatable {
    let title: String
    let url: String
    /// 正文摘要（Tavily `content`，已压平空白并截断）。
    /// 仅供喂给模型建立事实与时间线，界面只展示 `title` / `url`。
    let snippet: String
    /// 发布时间（Tavily `published_date`）。该字段仅在 `topic=news` 时返回，
    /// 常规搜索下普遍为空 —— 因此不能指望它来定时间线，才需要宿主另注入「当前时间」。
    let publishedDate: String

    init(title: String, url: String, snippet: String = "", publishedDate: String = "") {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.publishedDate = publishedDate
    }
}

/// Tavily 搜索返回：AI 摘要 + 来源条目列表。
struct TavilySearchResult {
    let answer: String
    let items: [SourceItem]
}

/// 搜索错误（String 不满足 Error 协议，单独封装）。
enum TavilyError: Error {
    case message(String)
}

/// Tavily 联网搜索客户端（单次 JSON 请求，非流式）。
final class TavilyClient {
    static let shared = TavilyClient()

    private let endpoint = "https://api.tavily.com/search"
    private var session: URLSession
    private var task: URLSessionDataTask?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)
    }

    /// 发起搜索。
    func search(query: String, completion: @escaping (Result<TavilySearchResult, TavilyError>) -> Void) {
        cancel()

        let key = Config.tavilyApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            completion(.failure(.message(L10n.t(.searchErrorMissingKey))))
            return
        }
        guard let url = URL(string: endpoint) else {
            completion(.failure(.message(L10n.t(.searchErrorInvalidURL))))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "query": query,
            "search_depth": "basic",
            "max_results": 5,
            "include_answer": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // 线程说明：task 引用的读写统一收敛到主线程，并在回调里按 task 身份过滤——
        // 被取消/被新请求替代的过期响应（self.task !== t）直接忽略，
        // 消除「completion handler 在 URLSession 内部队程清理 task」与「主线程 cancel」的竞态。
        var t: URLSessionDataTask!
        t = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.task === t else { return } // 过期响应：忽略
                self.task = nil

                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    completion(.failure(.message(error.localizedDescription)))
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    completion(.failure(.message(L10n.t(.searchErrorHTTP, http.statusCode))))
                    return
                }
                guard let data = data else {
                    completion(.failure(.message(L10n.t(.searchErrorEmpty))))
                    return
                }
                completion(TavilyClient.parse(data))
            }
        }
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// 解析 Tavily 响应 → TavilySearchResult；解析失败返回 failure。
    static func parse(_ data: Data) -> Result<TavilySearchResult, TavilyError> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.message(L10n.t(.searchErrorParseFailed)))
        }
        let answer = obj["answer"] as? String ?? ""

        var items: [SourceItem] = []
        if let results = obj["results"] as? [[String: Any]] {
            for r in results {
                let title = r["title"] as? String ?? ""
                let url = r["url"] as? String ?? ""
                guard !url.isEmpty else { continue }
                let content = r["content"] as? String ?? ""
                let published = (r["published_date"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(SourceItem(
                    title: title.isEmpty ? url : title,
                    url: url,
                    snippet: condense(content, limit: snippetLimit),
                    publishedDate: published
                ))
            }
        }
        return .success(TavilySearchResult(answer: answer, items: items))
    }

    /// 每条结果摘要的截断长度：5 条 × 300 字约 1000 token，兼顾信息量与上下文成本。
    private static let snippetLimit = 300

    /// 压平换行/连续空白并截断 —— 摘要直接拼进 prompt，保留原始换行会让提示词结构变乱。
    private static func condense(_ s: String, limit: Int) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
