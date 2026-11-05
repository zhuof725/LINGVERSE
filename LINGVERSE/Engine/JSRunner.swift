import Foundation
import JavaScriptCore
import CommonCrypto

/// 书源 JS 规则的执行器。
///
/// Legado 用 Rhino 跑 JS，书源作者依赖一套固定的宿主 API：
/// `java.ajax` / `java.connect` / `java.base64Encode` / `java.md5Encode` / 全局 `result` …
/// iOS 上没有 Rhino，用 JavaScriptCore 承担同一角色，把这套 API 做成宿主函数注入。
///
/// 每次求值新建一个 JSContext：书源脚本会往全局对象上乱写变量，
/// 复用上下文会让不同源的脚本互相污染，排查起来极其痛苦。
final class JSRunner {
    static let shared = JSRunner()

    /// JSContext 不保证线程安全，规则求值统一串行。
    private let lock = NSRecursiveLock()

    /// 最近一次执行的异常文本，供调试面板展示。
    private(set) var lastError: String?

    private init() {}

    // MARK: - 入口

    /// 求值一段脚本，返回字符串。按 Legado 约定取「最后一个表达式的值」。
    func run(_ script: String, ctx: RuleContext, json: Any?, result: String? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let context = makeContext(ctx: ctx, json: json, result: result) else { return "" }
        guard let value = evaluate(script, in: context) else { return "" }
        return value.isObject ? stringify(value.toObject()) : (value.toString() ?? "")
    }

    /// 求值一段返回数组的脚本（bookList / chapterList）。
    func runList(_ script: String, ctx: RuleContext, json: Any?) -> [[String: Any]] {
        let text = run(script, ctx: ctx, json: json)
        return Self.parseList(text)
    }

    /// 把脚本结果按 JSON 数组解析成字典数组。脚本返回对象时包成单元素数组。
    static func parseList(_ text: String) -> [[String: Any]] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8) else { return [] }
        let parser = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let arr = parser as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
        if let obj = parser as? [String: Any] { return [obj] }
        return []
    }

    // MARK: - 上下文

    private func makeContext(ctx: RuleContext, json: Any?, result: String?) -> JSContext? {
        guard let context = JSContext() else { return nil }

        context.exceptionHandler = { [weak self] _, exception in
            self?.lastError = exception?.toString() ?? "unknown"
        }
        lastError = nil

        // 宿主函数：闭包直接捕获本次求值的上下文，不用全局状态传递
        let ajax: @convention(block) (String) -> String = { url in
            HTTPClient.shared.get(url) ?? ""
        }
        let ajaxTimeout: @convention(block) (String, Double) -> String = { url, ms in
            HTTPClient.shared.get(url, timeout: max(1, ms / 1000)) ?? ""
        }
        let ajaxAll: @convention(block) (JSValue) -> [String] = { arr in
            let urls = (arr.toArray() as? [Any])?.compactMap { $0 as? String } ?? []
            return urls.map { HTTPClient.shared.get($0) ?? "" }
        }
        let request: @convention(block) (String, String) -> String = { url, optsJSON in
            let opts = (try? JSONSerialization.jsonObject(with: Data(optsJSON.utf8))) as? [String: Any] ?? [:]
            let method = (opts["method"] as? String)?.uppercased() ?? "POST"
            let body = opts["body"] as? String
            let headers = opts["headers"] as? [String: String] ?? [:]
            return HTTPClient.shared.request(url, method: method, body: body, headers: headers) ?? ""
        }
        let base64Encode: @convention(block) (String) -> String = { s in
            Data(s.utf8).base64EncodedString()
        }
        let base64Decode: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        let md5: @convention(block) (String) -> String = { s in
            Digest.md5Hex(Data(s.utf8))
        }
        let sha256: @convention(block) (String) -> String = { s in
            Digest.sha256Hex(Data(s.utf8))
        }
        let log: @convention(block) (String) -> Void = { s in
            Diagnostics.shared.add("js", s)
        }

        context.setObject(ajax, forKeyedSubscript: "__ajax" as NSString)
        context.setObject(ajaxTimeout, forKeyedSubscript: "__ajaxTimeout" as NSString)
        context.setObject(ajaxAll, forKeyedSubscript: "__ajaxAll" as NSString)
        context.setObject(request, forKeyedSubscript: "__request" as NSString)
        context.setObject(base64Encode, forKeyedSubscript: "__base64Encode" as NSString)
        context.setObject(base64Decode, forKeyedSubscript: "__base64Decode" as NSString)
        context.setObject(md5, forKeyedSubscript: "__md5" as NSString)
        context.setObject(sha256, forKeyedSubscript: "__sha256" as NSString)
        context.setObject(log, forKeyedSubscript: "__log" as NSString)

        // 变量：key / page / baseUrl / 源变量 / book / chapter / result
        context.setObject(ctx.key, forKeyedSubscript: "key" as NSString)
        context.setObject(ctx.page, forKeyedSubscript: "page" as NSString)
        context.setObject(ctx.baseURL, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(ctx.vars["__sourceKey"] ?? "", forKeyedSubscript: "__sourceKey" as NSString)
        context.setObject(ctx.vars["__sourceUrl"] ?? "", forKeyedSubscript: "__sourceUrl" as NSString)
        context.setObject(ctx.vars["__sourceName"] ?? "", forKeyedSubscript: "__sourceName" as NSString)
        for (k, v) in ctx.vars where k.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil {
            context.setObject(v, forKeyedSubscript: k as NSString)
        }
        context.evaluateScript("var book = \(Self.jsLiteral(ctx.book));"
                             + "var chapter = \(Self.jsLiteral(ctx.chapter));")
        if let result { context.setObject(result, forKeyedSubscript: "result" as NSString) }

        // 让脚本能拿到当前响应（部分源写成 `result` 之外的名字）
        context.setObject(ctx.body, forKeyedSubscript: "__body" as NSString)

        context.evaluateScript(Self.prelude)
        if let error = lastError {
            Diagnostics.shared.add("js", "prelude failed: \(error)")
            lastError = nil
        }
        return context
    }

    private func evaluate(_ script: String, in context: JSContext) -> JSValue? {
        let value = context.evaluateScript(script, withSourceURL: URL(string: "lingverse://rule.js"))
        if let exception = context.exception {
            lastError = exception.toString() ?? "unknown"
            Diagnostics.shared.add("js", "rule failed: \(lastError ?? "")")
            context.exception = nil
            return nil
        }
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value
    }

    private func stringify(_ object: Any) -> String {
        if let s = object as? String { return s }
        if let n = object as? NSNumber { return n.stringValue }
        if let a = object as? [Any] { return a.map { stringify($0) }.joined(separator: "\n") }
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: object)
    }

    private static func jsLiteral(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Prelude

    /// Legado 宿主对象。只实现音频链路会碰到的那一批；
    /// 未实现的 API 刻意不定义 —— 脚本调用会抛 ReferenceError 并在诊断里可见，
    /// 比静默返回空串更容易定位。
    private static let prelude = """
    var java = {
      ajax: function(u, opt) {
        if (typeof opt === 'number') return __ajaxTimeout(String(u), opt);
        if (opt && typeof opt === 'object') return __request(String(u), JSON.stringify(opt));
        return __ajax(String(u));
      },
      ajaxAll: function(list) { return __ajaxAll(list); },
      connect: function(u) { return __ajax(String(u)); },
      connectNative: function(u) { return __ajax(String(u)); },
      get: function(u) { var o = __request(String(u), '{"method":"GET"}'); return o; },
      post: function(u, body, headers) {
        var opt = {method:'POST', body:String(body === undefined ? '' : body)};
        if (headers) opt.headers = headers;
        return __request(String(u), JSON.stringify(opt));
      },
      put: function(u, body) {
        return __request(String(u), JSON.stringify({method:'PUT', body:String(body === undefined ? '' : body)}));
      },
      head: function(u) { return __request(String(u), '{"method":"HEAD"}'); },
      base64Encode: function(s) { return __base64Encode(String(s)); },
      base64Decode: function(s) { return __base64Decode(String(s)); },
      md5Encode: function(s) { return __md5(String(s)); },
      md5Encode16: function(s) { return __md5(String(s)).substring(8, 24); },
      digestHex: function(s) { return __sha256(String(s)); },
      hexDecodeToString: function(s) {
        var out = '', t = String(s);
        for (var i = 0; i + 1 < t.length; i += 2) out += String.fromCharCode(parseInt(t.substr(i, 2), 16));
        return out;
      },
      hexEncodeToString: function(s) {
        var out = '';
        for (var i = 0; i < s.length; i++) {
          var h = s.charCodeAt(i).toString(16);
          if (h.length < 2) h = '0' + h;
          out += h;
        }
        return out;
      },
      strToBytes: function(s) {
        var a = [];
        for (var i = 0; i < s.length; i++) {
          var c = s.charCodeAt(i);
          if (c < 128) a.push(c);
          else if (c < 2048) { a.push(192 | (c >> 6)); a.push(128 | (c & 63)); }
          else { a.push(224 | (c >> 12)); a.push(128 | ((c >> 6) & 63)); a.push(128 | (c & 63)); }
        }
        return a;
      },
      bytesToStr: function(b) {
        var s = '';
        for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i] & 255);
        try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
      },
      log: function(s) { __log(String(s)); return s; },
      toast: function(s) { __log(String(s)); return s; },
      longToast: function(s) { __log(String(s)); return s; },
      sleep: function(ms) { return ''; },
      timeFormat: function(t) {
        var d = new Date(t);
        function p(n) { return n < 10 ? '0' + n : '' + n; }
        return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
             + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
      },
      setContent: function() { return ''; }
    };

    var source = {
      getKey: function() { return (typeof __sourceKey !== 'undefined') ? __sourceKey : ''; },
      getBookSourceUrl: function() { return (typeof __sourceUrl !== 'undefined') ? __sourceUrl : ''; },
      getBookSourceName: function() { return (typeof __sourceName !== 'undefined') ? __sourceName : ''; },
      getVariable: function() { return ''; },
      setVariable: function() { return ''; }
    };

    var cookie = {
      get: function() { return ''; },
      set: function() { return true; },
      remove: function() { return true; },
      replace: function() { return true; },
      getKey: function() { return ''; },
      toMap: function() { return []; },
      fromMap: function() { return ''; }
    };

    if (typeof result === 'undefined') { var result = ''; }
    if (typeof baseUrl === 'undefined') { var baseUrl = ''; }
    """
}

// MARK: - 摘要

/// book 源常用 `java.md5Encode` 做签名。用 CommonCrypto，避免手写实现出错。
enum Digest {
    static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
