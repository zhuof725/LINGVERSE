import Foundation

/// 书源请求用的最小 HTTP 客户端。
///
/// 刻意不引入第三方网络库：音频链路只有 GET/POST，URLSession 足够，
/// 少一个依赖就少一处版本漂移。
///
/// 两个要点：
/// 1. **编码**——中文书站大量使用 GBK/GB18030，`String(data:encoding:.utf8)` 会返回 nil。
///    这里先看响应头 charset，再嗅探 `<meta charset>`，最后才退回 UTF-8。
/// 2. **同步语义**——Legado 的 `java.ajax` 是同步的，书源脚本假定它同步返回，
///    所以这里用信号量把异步请求转成同步，并且每个请求带独立超时。
final class HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": "zh-CN,zh;q=0.9",
        ]
        session = URLSession(configuration: config)
    }

    /// GET，返回解码后的文本。失败返回 nil（区别于"成功但内容为空"）。
    func get(_ url: String, timeout: TimeInterval = 20) -> String? {
        request(url, method: "GET", body: nil, headers: [:], timeout: timeout)
    }

    func request(_ url: String, method: String, body: String?,
                 headers: [String: String], timeout: TimeInterval = 20) -> String? {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            Diagnostics.shared.add("http", "非法 URL: \(url.prefix(120))")
            return nil
        }
        var req = URLRequest(url: target)
        req.httpMethod = method
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body, !body.isEmpty {
            req.httpBody = body.data(using: .utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }

        let sem = DispatchSemaphore(value: 0)
        var result: String?
        var status = 0

        let task = session.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                Diagnostics.shared.add("http", "\(method) \(target.host ?? "") 失败: \(error.localizedDescription)")
                return
            }
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                Diagnostics.shared.add("http", "\(method) \(target.host ?? "") 无响应体")
                return
            }
            let text = Self.decode(data, response: response)
            result = text
            Diagnostics.shared.add("http", "\(method) \(target.host ?? "") → \(status) \(text.count) 字符")
        }
        task.resume()

        // 多给 2 秒等 URLSession 自己收尾，避免信号量先超时后回调又写 result
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            Diagnostics.shared.add("http", "\(method) \(target.host ?? "") 超时 \(Int(timeout))s")
            return nil
        }
        if status >= 400 {
            Diagnostics.shared.add("http", "\(method) \(target.host ?? "") HTTP \(status)")
        }
        return result
    }

    // MARK: - 编码

    /// 把响应字节解码成文本：响应头 charset → meta 嗅探 → UTF-8 → GB18030。
    static func decode(_ data: Data, response: URLResponse?) -> String {
        if let http = response as? HTTPURLResponse,
           let name = http.textEncodingName,
           let enc = encoding(for: name),
           let text = String(data: data, encoding: enc) {
            return text
        }
        // 只在头 4KB 里找 meta，整篇扫太浪费
        if let head = String(data: data.prefix(4096), encoding: .isoLatin1)?.lowercased(),
           let range = head.range(of: "charset=") {
            let tail = head[range.upperBound...].prefix(20)
            let name = tail.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if let enc = encoding(for: String(name)), let text = String(data: data, encoding: enc) {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .init(rawValue: 0x80000632)) { return text } // GB18030
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func encoding(for name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
