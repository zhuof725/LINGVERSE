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

    /// 规则变量表：`java.put(k,v)` 写入，`java.get(k)` 读出。
    /// 必须在多个规则之间共享 —— 书源常见做法是在 bookInfo 里 put 一个 id，
    /// 到 toc 规则里再 get 出来拼 URL。每次求值新建 JSContext 的话这里必须由原生侧持有。
    private var ruleVars: [String: String] = [:]

    /// 最近一次执行的异常文本，供调试面板展示。
    private(set) var lastError: String?

    /// `source.setVariable(...)` 最近写入的值。legado 用它存跨次会话的源状态。
    private(set) var lastSourceVariable: String?

    private init() {}

    // MARK: - 入口

    /// 求值一段脚本，返回字符串。按 Legado 约定取「最后一个表达式的值」。
    func run(_ script: String, ctx: RuleContext, json: Any?, result: String? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let context = makeContext(ctx: ctx, json: json, result: result) else { return "" }
        guard let value = evaluate(script, in: context) else { return "" }
        if value.isObject, let object = value.toObject() {
            return stringify(object)
        }
        return value.toString() ?? ""
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
            let raw = arr.toArray() ?? []
            let urls: [String] = raw.compactMap { $0 as? String }
            return urls.map { HTTPClient.shared.get($0) ?? "" }
        }
        let request: @convention(block) (String, String) -> String = { url, optsJSON in
            let opts = (try? JSONSerialization.jsonObject(with: Data(optsJSON.utf8))) as? [String: Any] ?? [:]
            let method = (opts["method"] as? String)?.uppercased() ?? "POST"
            let body: String?
            if let s = opts["body"] as? String { body = s }
            else if let b = opts["body"] { body = String(describing: b) }
            else { body = nil }
            // headers 可能是 [String:String]，也可能值里有数字；宽松转换，别整批丢掉
            var headers: [String: String] = [:]
            if let raw = opts["headers"] as? [String: Any] {
                for (k, v) in raw {
                    if let s = v as? String { headers[k] = s }
                    else if !(v is NSNull) { headers[k] = String(describing: v) }
                }
            }
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
        // 给 result 双面值用的内部解码器
        let decodeB64: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }

        // Cookie 存根。真实书源的 cookie.getKey 用于带登录态；
        // 未登录时返回空串即可，但要存在，否则脚本抛 ReferenceError。
        let cookieGet: @convention(block) (String, String) -> String = { url, key in
            CookieStore.shared.value(url: url, key: key)
        }
        let cookieSet: @convention(block) (String, String) -> Bool = { url, value in
            CookieStore.shared.set(url: url, raw: value)
            return true
        }
        let cookieRemove: @convention(block) (String) -> Bool = { url in
            CookieStore.shared.remove(url: url)
            return true
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
        context.setObject(decodeB64, forKeyedSubscript: "__decodeB64" as NSString)
        context.setObject(cookieGet, forKeyedSubscript: "__cookieGet" as NSString)
        context.setObject(cookieSet, forKeyedSubscript: "__cookieSet" as NSString)
        context.setObject(cookieRemove, forKeyedSubscript: "__cookieRemove" as NSString)

        // 规则变量：把原生侧的表序列化进去，求值结束后再回收。
        // 这样 java.put 在 bookInfo 里写的 book_id，toc 规则里才 get 得到。
        let ruleVarsJSON = (try? JSONSerialization.data(withJSONObject: ruleVars))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        context.evaluateScript("var __ruleVars = \(ruleVarsJSON);")

        let setSourceVar: @convention(block) (String) -> Void = { [weak self] value in
            self?.lastSourceVariable = value
        }
        context.setObject(setSourceVar, forKeyedSubscript: "__setSourceVar" as NSString)

        // java.put 必须回写到原生表，否则 JSContext 一销毁，bookInfo 里 put 的 id 就没了
        let putRuleVar: @convention(block) (String, String) -> Void = { [weak self] key, value in
            self?.ruleVars[key] = value
        }
        context.setObject(putRuleVar, forKeyedSubscript: "__putRuleVar" as NSString)

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
        // `result` 必须是"双面"的：既能 JSON.parse(result) 当字符串，
        // 也能 result.author 当对象。真实书源两种写法都用：
        //   bookList: JSON.parse(result)      ← 要字符串
        //   author:   String(result.author)   ← 要对象
        // 只满足一种，另一种就静默失败（脚本 catch 成 {} 返回空数组），
        // 界面上表现为「搜不到」，完全看不出原因。
        // 让脚本能拿到当前响应（部分源写成 `result` 之外的名字）
        context.setObject(ctx.body, forKeyedSubscript: "__body" as NSString)

        context.evaluateScript(Self.prelude)
        if let error = lastError {
            Diagnostics.shared.add("js", "prelude failed: \(error)")
            lastError = nil
        }

        // result 必须在 prelude 之后注入：injectResult 内部要用 __decodeB64，
        // 那个宿主函数是在 prelude 之前才 setObject 的……
        // 更重要的是这一行的位置：之前它排在 prelude 前面，
        // __decodeB64 还不存在，注入结果成了空串，
        // 于是 bookList 的 JSON.parse(result) 抛异常被书源 catch 成 {}，
        // 表现为「搜不到」但零报错。
        if let result {
            injectResult(result, into: context)
        }

        // jsLib 必须在 prelude 之后、规则之前注入：
        // 真实书源的 jsLib 里定义了签名函数和常量（fanqieSignHeaders / FQ_IID 等），
        // 规则脚本直接调用它们。少这一步，任何 API 型书源都会报 undefined is not a function。
        if !ctx.jsLib.isEmpty {
            context.evaluateScript(ctx.jsLib, withSourceURL: URL(string: "lingverse://jslib.js"))
            if let error = context.exception {
                lastError = error.toString() ?? "unknown"
                Diagnostics.shared.add("js", "jsLib 执行失败: \(lastError ?? "")")
                context.exception = nil
            } else {
                // 常量定义在 jsLib 末尾，中间任何一步抛异常都会导致它们没定义。
                // 这里显式回报，一眼能看出 jsLib 到底跑完了没有。
                let probe = context.evaluateScript(
                    "[typeof FQ_BASE, typeof FQ_IID, typeof fanqieSignHeaders].join('|')")
                Diagnostics.shared.add("js", "jsLib 就绪: \(probe?.toString() ?? "?")")
            }
        }

        return context
    }

    /// 把 `result` 注入成「双面值」。
    ///
    /// JavaScriptCore 里没法给已有对象挂 Swift 闭包当 toString，所以换个思路：
    /// 用 JS 侧构造一个包装对象，`toString/valueOf` 返回原始 JSON 文本，
    /// 属性访问透传到解析后的对象。这样 `JSON.parse(result)` 和 `result.author` 都成立。
    private func injectResult(_ raw: String, into context: JSContext) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        guard isJSON else {
            context.setObject(raw, forKeyedSubscript: "result" as NSString)
            return
        }
        // 用 base64 传文本，避免 JSON 里的引号/换行破坏 JS 字面量
        let encoded = Data(raw.utf8).base64EncodedString()
        let js = """
        (function() {
          var text = __decodeB64('\(encoded)');
          var obj;
          try { obj = JSON.parse(text); } catch (e) { obj = {}; }
          if (obj === null || typeof obj !== 'object') { return { value: text }; }
          // 字符串语义：JSON.parse(result) / String(result) 都拿原文
          Object.defineProperty(obj, 'toString', { value: function() { return text; }, enumerable: false });
          Object.defineProperty(obj, 'valueOf',  { value: function() { return text; }, enumerable: false });
          return { value: obj };
        })()
        """
        if let value = context.evaluateScript(js), let obj = value.objectForKeyedSubscript("value") {
            context.setObject(obj, forKeyedSubscript: "result" as NSString)
        } else {
            context.setObject(raw, forKeyedSubscript: "result" as NSString)
        }
    }

    private func evaluate(_ script: String, in context: JSContext) -> JSValue? {        let value = context.evaluateScript(script, withSourceURL: URL(string: "lingverse://rule.js"))
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
      // Legado 的 java.ajax / connect / get 返回 StrResponse，不是字符串。
      // 真实书源写 java.get(url, map).body() —— 返回纯字符串会让 .body() 抛
      // TypeError，被书源自己的 try/catch 吞掉，界面上只剩「请求失败」。
      ajax: function(u, opt) {
        var text, code = 0;
        if (typeof opt === 'number') {
          text = __ajaxTimeout(String(u), opt);
        } else if (opt && typeof opt === 'object') {
          text = __request(String(u), JSON.stringify(opt));
        } else {
          text = __ajax(String(u));
        }
        return __wrapResponse(text);
      },
      ajaxAll: function(list) {
        var raw = __ajaxAll(list) || [];
        var out = [];
        for (var i = 0; i < raw.length; i++) out.push(__wrapResponse(raw[i]));
        return out;
      },
      connect: function(u, headers) {
        if (headers) {
          var h = (typeof headers === 'string') ? JSON.parse(headers) : headers;
          return __wrapResponse(__request(String(u), JSON.stringify({ method: 'GET', headers: h })));
        }
        return __wrapResponse(__ajax(String(u)));
      },
      connectNative: function(u) { return __wrapResponse(__ajax(String(u))); },
      put: function(k, v) {
        __ruleVars[String(k)] = String(v);
        __putRuleVar(String(k), String(v));
        return '';
      },
      // java.get 有两个重载，Legado 靠参数形态区分：
      //   get(url, headers)  取网页，返回 StrResponse
      //   get(key)           读 java.put 存的变量，返回字符串
      get: function(a, b) {
        var s = String(a === undefined || a === null ? '' : a);
        var isURL = /^https?:/i.test(s);
        if (typeof b === 'undefined' && !isURL) {
          // 变量读取：找不到就返回空串，不要当成请求发出去
          return (__ruleVars[s] !== undefined) ? __ruleVars[s] : '';
        }
        if (!isURL) {
          // URL 为空或不是 http 开头：这是调用方的 bug，记下来但要能看出是哪次调用
          var where = '';
          try { where = String((new Error()).stack || '').split('\n')[1] || ''; } catch (e) {}
          __log('[get] 非法地址: ' + JSON.stringify(s.slice(0, 60)) + ' · ' + where.slice(0, 80));
          return __wrapResponse('');
        }
        var opt = { method: 'GET' };
        if (b) {
          try {
            opt.headers = (typeof b === 'string') ? JSON.parse(b) : b;
            if (opt.headers && opt.headers.__map) opt.headers = opt.headers.__map;
          } catch (e) { opt.headers = {}; }
        }
        var body = __request(s, JSON.stringify(opt));
        __log('[get] ' + s.slice(0, 70) + ' -> ' + String(body).length + ' 字符');
        return __wrapResponse(body);
      },
      post: function(u, body, headers) {
        var opt = {method: 'POST', body: String(body === undefined ? '' : body)};
        if (headers) {
          var h = (typeof headers === 'string') ? JSON.parse(headers) : headers;
          if (h && h.__map) h = h.__map;
          opt.headers = h;
        }
        return __wrapResponse(__request(String(u), JSON.stringify(opt)));
      },
      head: function(u) { return __wrapResponse(__request(String(u), '{"method":"HEAD"}')); },
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
      getVariable: function() { return (typeof __sourceVars !== 'undefined') ? __sourceVars : ''; },
      setVariable: function(v) { __setSourceVar(String(v)); return ''; }
    };

    // java.put / java.get 共用的规则变量表。legado 用它跨规则传 book_id 这类值。
    if (typeof __ruleVars === 'undefined') { var __ruleVars = {}; }

    // Legado 的 StrResponse：书源写 resp.body() / resp.code()。
    // 包一层，让 java.* 的返回值既能当字符串（String(r)）又能调 .body()。
    function __wrapResponse(text) {
      var t = (text === undefined || text === null) ? '' : String(text);
      return {
        body: function() { return t; },
        code: function() { return 200; },
        headers: function() { return {}; },
        url: function() { return ''; },
        isSuccessful: function() { return true; },
        string: function() { return t; },
        toString: function() { return t; },
        valueOf: function() { return t; }
      };
    }

    // Packages.java.util.HashMap：书源用它构造请求头，然后传给 java.get。
    // 只要能被 for..in 遍历、支持 put 就够了。
    var Packages = {
      java: {
        util: {
          HashMap: function() {
            var m = {};
            return {
              __map: m,
              put: function(k, v) { m[String(k)] = String(v); return v; },
              get: function(k) { return (m[String(k)] !== undefined) ? m[String(k)] : null; },
              containsKey: function(k) { return Object.prototype.hasOwnProperty.call(m, String(k)); },
              keySet: function() { return Object.keys(m); },
              size: function() { return Object.keys(m).length; }
            };
          },
          ArrayList: function() { return []; }
        },
        lang: { String: String, Integer: Number }
      }
    };

    // cache.*：书源用来缓存详情/目录，LINGVERSE 侧用内存表（进程内有效）
    var __cacheMap = {};
    var cache = {
      putMemory: function(k, v) { __cacheMap[String(k)] = String(v); return ''; },
      getFromMemory: function(k) { return (__cacheMap[String(k)] !== undefined) ? __cacheMap[String(k)] : ''; },
      deleteMemory: function(k) { delete __cacheMap[String(k)]; return ''; },
      put: function(k, v) { __cacheMap[String(k)] = String(v); return ''; },
      get: function(k) { return (__cacheMap[String(k)] !== undefined) ? __cacheMap[String(k)] : ''; },
      delete: function(k) { delete __cacheMap[String(k)]; return ''; }
    };

    // cookie.*：真实书源用 getKey(url, name) 取单个 cookie、getCookie(url) 取整条。
    // 这些只影响需要登录的源；未登录时返回空串是正确行为。
    var cookie = {
      getKey: function(url, key) { return __cookieGet(String(url), String(key)); },
      getCookie: function(url) { return __cookieGet(String(url), ''); },
      setCookie: function(url, v) { return __cookieSet(String(url), String(v)); },
      removeCookie: function(url) { return __cookieRemove(String(url)); },
      replaceCookie: function(url, v) { return __cookieSet(String(url), String(v)); },
      get: function() { return __cookieGet('', ''); },
      set: function(url, v) { return __cookieSet(String(url), String(v)); },
      remove: function(url) { return __cookieRemove(String(url)); },
      replace: function(url, v) { return __cookieSet(String(url), String(v)); },
      getKey_: function() { return ''; },
      toMap: function() { return []; },
      fromMap: function() { return ''; }
    };

    if (typeof result === 'undefined') { var result = ''; }
    if (typeof baseUrl === 'undefined') { var baseUrl = ''; }
    """
}

// MARK: - 摘要

/// book 源常用 `java.md5Encode` 做签名。
///
/// MD5 在这里不是安全用途 —— 书源作者用它拼接请求参数，
/// 换成 SHA-256 会导致签名校验失败。CC_MD5 在 iOS 13 被标废弃，
/// 所以这里关掉废弃诊断，而不是改用别的算法。
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
