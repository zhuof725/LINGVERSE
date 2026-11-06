import Foundation

/// 书源 Cookie。
///
/// 未登录时绝大多数取值为空，但 `cookie.getKey(url, "sessionid")` 这类调用
/// 必须存在 —— 书源脚本不会判断 API 是否存在，直接调用。
///
/// 只做最小实现：按 host 存一条原始 Cookie 串，能读能写能删。
/// 真正的登录流程（loginUrl/loginUi）本期不做。
final class CookieStore {
    static let shared = CookieStore()

    private var storage: [String: String] = [:]   // host -> "k1=v1; k2=v2"
    private let lock = NSLock()

    private init() {}

    /// 取某个 host 下指定 key 的值。key 传空串时返回整条 Cookie。
    func value(url: String, key: String) -> String {
        let host = hostOf(url)
        lock.lock(); defer { lock.unlock() }
        guard let raw = storage[host] else { return "" }
        guard !key.isEmpty else { return raw }
        for part in raw.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if let eq = kv.firstIndex(of: "=") {
                let name = String(kv[..<eq]).trimmingCharacters(in: .whitespaces)
                if name == key {
                    return String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return ""
    }

    /// 写入。`raw` 可以是完整 Cookie 串，也可以是单个值（此时覆盖）。 
    func set(url: String, raw: String) {
        let host = hostOf(url)
        lock.lock(); defer { lock.unlock() }
        storage[host] = raw
    }

    func remove(url: String) {
        let host = hostOf(url)
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: host)
    }

    /// 供 HTTPClient 使用：把某个 URL 的 Cookie 带上。
    func headerValue(for url: String) -> String? {
        let host = hostOf(url)
        lock.lock(); defer { lock.unlock() }
        guard let v = storage[host], !v.isEmpty else { return nil }
        return v
    }

    private func hostOf(_ url: String) -> String {
        URL(string: url)?.host ?? url.split(separator: "/").dropFirst().first.map(String.init) ?? ""
    }
}
