import AppKit
import WebKit
import Foundation

enum BangcleFailure: LocalizedError {
    case message(String)
    case loginExpired
    case transport(Int)
    case http(Int)
    case downloadRetry(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .loginExpired: return "梆梆登录已失效，任务断点已保留，重新登录后将查询原任务并继续。"
        case .transport(let code):
            let detail = [-1001: "请求超时", -1005: "连接中断", -1009: "网络不可用", -1003: "域名解析失败", -1004: "无法连接服务器"][code] ?? "网络传输失败"
            return "\(detail)（错误码 \(code)），任务与已下载数据已保留。"
        case .http(let code): return "服务器返回 HTTP \(code)，任务与已下载数据已保留。"
        case .downloadRetry(let text): return text
        }
    }
}

private struct DownloadReceipt: Codable {
    let validator: String?
    let total: Int64
}

struct BangcleTaskRecord: Codable {
    enum Phase: String, Codable { case uploaded, submitting, submitted, downloaded }
    let appID: String
    let outputPath: String
    var phase: Phase
}

// Login stays on the official site. Passwords are never read by the app.
final class BangcleLogin: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var completion: (([HTTPCookie]?) -> Void)?
    private var checking = false
    private var generation = UUID()
    var diagnostic: ((String) -> Void)?
    func present(_ completion: @escaping ([HTTPCookie]?) -> Void) {
        self.completion = completion
        generation = UUID()
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "梆梆登录 · 登录成功后自动继续"; window.isReleasedWhenClosed = false
            window.delegate = self; window.center()
            webView = WKWebView(); webView.navigationDelegate = self; window.contentView = webView
        }
        checking = false
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: URL(string: "https://dev.bangcle.com/devwebsite/apps/index")!))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let safePath = url.path.components(separatedBy: ";").first ?? "/"
        diagnostic?("梆梆页面已载入：\(url.host ?? "")\(safePath)")
        // SSO can land on home/index or append a ;JSESSIONID path parameter.
        // Authenticate with a read-only API rather than an exact landing URL or page text.
        guard url.host == "dev.bangcle.com", url.path.hasPrefix("/devwebsite/"),
              completion != nil, !checking else { return }
        checking = true
        let generation = self.generation
        diagnostic?("⏳ 正在只读验证梆梆登录会话（loading）……")
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] allCookies in
            guard let self, self.generation == generation else { return }
            let cookies = allCookies.filter { $0.domain == "bangcle.com" || $0.domain.hasSuffix(".bangcle.com") }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try BangcleClient(cookies: cookies) { [weak self] line in
                        DispatchQueue.main.async { self?.diagnostic?(line) }
                    }.checkLogin()
                    DispatchQueue.main.async {
                        guard self.generation == generation, self.completion != nil else { return }
                        self.checking = false
                        let callback = self.completion; self.completion = nil
                        self.window.orderOut(nil); callback?(cookies)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.generation == generation, self.completion != nil else { return }
                        self.checking = false
                        self.diagnostic?("梆梆会话尚未通过验证，请在登录窗口完成登录。")
                    }
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != 102, (error as NSError).code != NSURLErrorCancelled else { return }
        diagnostic?("梆梆登录页面载入失败（错误码 \((error as NSError).code)），可关闭窗口后重试。")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        diagnostic?("梆梆登录页面跳转失败（错误码 \((error as NSError).code)）。")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let host = url.host,
              host == "bangcle.com" || host.hasSuffix(".bangcle.com") else {
            decisionHandler(.cancel); return
        }
        // The official SSO backurl may still use http. Upgrade navigations,
        // never send a password or session cookie over plaintext HTTP.
        if url.scheme == "http", navigationAction.request.httpMethod == "GET",
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"; decisionHandler(.cancel)
            if let secureURL = components.url { webView.load(URLRequest(url: secureURL)) }
            return
        }
        guard url.scheme == "https" else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func windowWillClose(_ notification: Notification) {
        generation = UUID(); checking = false
        let callback = completion; completion = nil; callback?(nil)
    }
}

final class BangcleClient: NSObject, URLSessionDataDelegate {
    private let log: (String) -> Void
    private let cookies: [HTTPCookie]
    private let base: URL
    private let cookieJar: HTTPCookieStorage?
    private let checkpoint: ((BangcleTaskRecord) throws -> Void)?
    private let pollInterval: TimeInterval
    private let retryDelay: TimeInterval
    private var partialFile: URL?, partialWriter: FileHandle?
    private var offset: Int64 = 0, received: Int64 = 0, expected: Int64 = -1
    private var receipt: DownloadReceipt?
    private var body = Data(), failure: Error?
    private var response: HTTPURLResponse?
    private let done = DispatchSemaphore(value: 0)
    private var stage = "请求", lastProgress = Date.distantPast
    init(cookies: [HTTPCookie], baseURL: URL = URL(string: "https://dev.bangcle.com")!,
         checkpoint: ((BangcleTaskRecord) throws -> Void)? = nil,
         pollInterval: TimeInterval = 180, retryDelay: TimeInterval = 5, log: @escaping (String) -> Void) {
        self.cookies = cookies; self.base = baseURL; self.log = log
        self.checkpoint = checkpoint
        self.pollInterval = pollInterval
        self.retryDelay = retryDelay
        cookieJar = URLSessionConfiguration.ephemeral.httpCookieStorage
        for cookie in cookies { cookieJar?.setCookie(cookie) }
    }

    private func request(_ url: URL, method: String = "GET", data: Data? = nil,
                         contentType: String? = nil, upload: URL? = nil, downloadTo: URL? = nil) throws -> Data {
        body = Data(); failure = nil; response = nil; lastProgress = .distantPast
        partialFile = downloadTo; offset = 0; received = 0; expected = -1; receipt = nil
        if let downloadTo {
            receipt = (try? Data(contentsOf: downloadTo.appendingPathExtension("json")))
                .flatMap { try? JSONDecoder().decode(DownloadReceipt.self, from: $0) }
            if receipt != nil {
                offset = ((try? FileManager.default.attributesOfItem(atPath: downloadTo.path)[.size]) as? NSNumber)?.int64Value ?? 0
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        // Share the isolated jar across requests so upload response cookie rotations survive.
        configuration.httpCookieStorage = cookieJar
        configuration.timeoutIntervalForRequest = downloadTo == nil ? 300 : 90
        configuration.timeoutIntervalForResource = downloadTo == nil ? 7200 : 86400
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url); req.httpMethod = method; req.httpBody = data
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if downloadTo != nil {
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 {
                req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                if let validator = receipt?.validator { req.setValue(validator, forHTTPHeaderField: "If-Range") }
                log("从本次任务已保存的 \(offset) 字节处尝试断点续传。")
            }
        }
        req.setValue("https://dev.bangcle.com/devwebsite/apps/index", forHTTPHeaderField: "Referer")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let task: URLSessionTask
        if let upload { task = session.uploadTask(with: req, fromFile: upload) }
        else { task = session.dataTask(with: req) }
        log("⏳ \(stage)（loading）")
        let start = Date(); var lastNotice = start; task.resume()
        while done.wait(timeout: .now() + 5) == .timedOut {
            if Date().timeIntervalSince(lastNotice) >= progressInterval {
                // Transfer callbacks already print progress; avoid duplicate loading lines.
                if Date().timeIntervalSince(lastProgress) >= progressInterval {
                    log("⏳ \(stage)（loading，已等待 \(Int(Date().timeIntervalSince(start))) 秒）")
                }
                lastNotice = Date()
            }
        }
        if let failure {
            if let known = failure as? BangcleFailure { throw known }
            if (failure as NSError).domain == NSURLErrorDomain && (failure as NSError).code == NSURLErrorUserAuthenticationRequired { throw BangcleFailure.loginExpired }
            if (failure as NSError).domain == NSURLErrorDomain { throw BangcleFailure.transport((failure as NSError).code) }
            throw BangcleFailure.message("\(stage)本地文件处理失败（错误码 \((failure as NSError).code)）。")
        }
        if response?.statusCode == 401 || response?.url?.path.contains("/authcenter/") == true {
            throw BangcleFailure.loginExpired
        }
        guard let response, (200..<300).contains(response.statusCode) else {
            throw BangcleFailure.http(response?.statusCode ?? 0)
        }
        if upload != nil { log("梆梆上传 APK：传输完成（100%），正在确认服务器结果。") }
        if downloadTo != nil {
            if expected > 0 && offset + received != expected { throw BangcleFailure.downloadRetry("下载内容长度不足，保留部分文件后重试。") }
            log("梆梆下载加固 APK：传输完成（100%），正在校验 APK。")
        }
        return body
    }
    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? ""
    }
    private func json(_ path: String, fields: [String: String]) throws -> [String: Any] {
        let form = fields.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&")
        let data = try request(base.appendingPathComponent(path), method: "POST", data: Data(form.utf8),
                               contentType: "application/x-www-form-urlencoded")
        return try checkedJSON(data)
    }
    private func checkedJSON(_ data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let html = String(decoding: data, as: UTF8.self)
            if html.contains("/authcenter/Users/") { throw BangcleFailure.loginExpired }
            throw BangcleFailure.message("梆梆返回的内容不是接口数据，请重新登录后重试。")
        }
        let message = result["msg"] as? String ?? ""
        if result["code"] as? Int == 401 || ["未登录", "登录失效", "登录已过期", "请先登录", "重新登录"].contains(where: message.contains) {
            throw BangcleFailure.loginExpired
        }
        guard result["code"] as? Int == 0 else {
            throw BangcleFailure.message("梆梆：\(result["msg"] as? String ?? "请求未成功，请检查登录和实名认证状态")")
        }
        return result
    }
    func checkLogin() throws {
        stage = "只读验证梆梆登录会话"
        _ = try json("devwebsite/home/getuserset", fields: [:])
    }
    func harden(_ apk: URL, output: URL) throws -> URL {
        let fm = FileManager.default
        let boundary = "AndroidRelease-" + UUID().uuidString
        let multipart = output.deletingLastPathComponent().appendingPathComponent(".bangcle-upload-\(UUID().uuidString)")
        fm.createFile(atPath: multipart.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? fm.removeItem(at: multipart) }
        let writer = try FileHandle(forWritingTo: multipart)
        let reader = try FileHandle(forReadingFrom: apk)
        do {
            let name = apk.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            try writer.write(contentsOf: Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\n\(name)\r\n" +
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/vnd.android.package-archive\r\n\r\n").utf8))
            while let bytes = try reader.read(upToCount: 1024 * 1024), !bytes.isEmpty { try writer.write(contentsOf: bytes) }
            try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try writer.close(); try reader.close()
        } catch { try? writer.close(); try? reader.close(); throw error }
        stage = "梆梆上传 APK"
        let uploaded = try checkedJSON(request(base.appendingPathComponent("devwebsite/apps/upload"), method: "POST",
            contentType: "multipart/form-data; boundary=\(boundary)", upload: multipart))
        let appID = (uploaded["msg"] as? String) ?? (uploaded["msg"] as? NSNumber)?.stringValue ?? ""
        guard !appID.isEmpty, appID.allSatisfy({ $0.isNumber }) else { throw BangcleFailure.message("梆梆上传未返回有效应用 ID。") }
        try appID.write(to: output.deletingLastPathComponent().appendingPathComponent("梆梆任务ID.txt"), atomically: true, encoding: .utf8)
        log("梆梆上传成功，任务 ID：\(appID)")
        let task = BangcleTaskRecord(appID: appID, outputPath: output.path, phase: .uploaded)
        try checkpoint?(task)
        return try resume(task)
    }
    func queryTask(appID: String) throws -> (status: Int, label: String) {
        guard !appID.isEmpty, appID.allSatisfy({ $0.isNumber }) else { throw BangcleFailure.message("无效的梆梆任务 ID。") }
        stage = "梆梆只读查询原任务 \(appID)"
        let state = try json("devwebsite/reinforces/getApkInfo", fields: ["app_id": appID])
        guard let info = state["info"] as? [String: Any], let status = info["reinforceStatus"] as? Int else {
            throw BangcleFailure.message("梆梆任务状态格式不正确，任务 ID：\(appID)")
        }
        let label = info["reinforceStatusLabel"] as? String ?? "状态 \(status)"
        log("梆梆任务 \(appID)：\(label)（\(status)）")
        return (status, label)
    }
    func resume(_ saved: BangcleTaskRecord) throws -> URL {
        var task = saved
        let output = URL(fileURLWithPath: task.outputPath)
        var state = try queryTask(appID: task.appID)
        if state.status == 10 || state.label == "已加固" {
            log("原任务已完成，直接获取下载，不重新上传或提交加固。")
        } else if [2, 9, 11].contains(state.status) || state.label.contains("失败") {
            throw BangcleFailure.message("原任务 \(task.appID) 加固失败：\(state.label)，已保留断点，不自动重新提交。")
        } else if ["未加固", "未提交", "待提交", "已上传", "上传成功", "待完善信息"].contains(state.label) {
            guard task.phase != .submitted && task.phase != .downloaded else {
                throw BangcleFailure.message("原任务状态与已保存的提交结果不一致，已停止自动提交以避免重复加固。")
            }
            task.phase = .submitting; try checkpoint?(task)
            try submit(appID: task.appID)
            task.phase = .submitted; try checkpoint?(task)
            state = try queryTask(appID: task.appID)
        } else if state.status == 4 || ["排队", "加固中", "等待", "处理中", "已提交"].contains(where: state.label.contains) {
            log("原任务正在处理，继续等待，不重新提交加固。")
        } else {
            throw BangcleFailure.message("原任务 \(task.appID) 状态为“\(state.label)”（\(state.status)），无法确认是否需要提交，已保留断点且未修改线上任务。")
        }
        let result: URL
        if FileManager.default.fileExists(atPath: output.path) {
            try validateAPK(output)
            result = output
            log("本次任务的加固包已在本地，通过校验后继续后续步骤。")
        } else { result = try download(appID: task.appID, output: output, initialState: state) }
        task.phase = .downloaded; try checkpoint?(task)
        return result
    }
    private func submit(appID: String) throws {
        stage = "梆梆提交本次加固任务"
        _ = try json("devwebsite/apps/completeApkInfo", fields: ["authenticityToken": "", "appId": appID,
            "isCeping": "false", "isReinforce": "true", "isApm": "false", "isAdvertising": "false"])
    }
    func download(appID: String, output: URL, initialState: (status: Int, label: String)? = nil) throws -> URL {
        let deadline = Date().addingTimeInterval(7200)
        var nextState = initialState
        while true {
            let state = try nextState ?? queryTask(appID: appID)
            nextState = nil
            let status = state.status, label = state.label
            if label == "已加固" || status == 10 { break }
            if [2, 9, 11].contains(status) || label.contains("失败") {
                throw BangcleFailure.message("梆梆加固失败：\(label)，任务 ID：\(appID)")
            }
            guard Date() < deadline else { throw BangcleFailure.message("梆梆等待超时，线上任务不会取消。可在梆梆控制台用任务 ID \(appID) 继续查看和下载。") }
            log("⏳ 原任务正在等待云端处理（loading，\(Int(pollInterval)) 秒后再次查询；加固成功后自动下载）")
            Thread.sleep(forTimeInterval: min(pollInterval, max(0, deadline.timeIntervalSinceNow)))
        }
        let partial = output.appendingPathExtension("part")
        for attempt in 1...6 {
            do {
                if let data = try? Data(contentsOf: partial.appendingPathExtension("json")),
                   let saved = try? JSONDecoder().decode(DownloadReceipt.self, from: data), saved.total > 0,
                   let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber,
                   size.int64Value == saved.total {
                    log("已保存完整下载内容，直接校验，不重新传输。")
                } else { try downloadAttempt(appID: appID, partial: partial) }
                do { try validateAPK(partial) }
                catch {
                    // Invalid payload belongs only to this task; never reuse it as a valid APK.
                    try? FileManager.default.removeItem(at: partial)
                    try? FileManager.default.removeItem(at: partial.appendingPathExtension("json"))
                    throw error
                }
                guard !FileManager.default.fileExists(atPath: output.path) else { throw BangcleFailure.message("目标文件已存在：\(output.path)") }
                try FileManager.default.moveItem(at: partial, to: output)
                try? FileManager.default.removeItem(at: partial.appendingPathExtension("json"))
                log("梆梆加固包校验完成：\(output.path)"); return output
            } catch {
                let retryable: Bool
                switch error {
                case BangcleFailure.transport(let code): retryable = [-1001, -1003, -1004, -1005, -1006, -1009, -1011, -1015, -1017].contains(code)
                case BangcleFailure.http(let code): retryable = [403, 404, 408, 410, 416, 429].contains(code) || code >= 500
                case BangcleFailure.downloadRetry: retryable = true
                default: retryable = false
                }
                guard retryable else { throw error }
                guard attempt < 6 else {
                    throw BangcleFailure.message("下载连续重试后仍失败：\(error.localizedDescription) 可点击“续接梆梆任务”继续，已下载的部分文件和任务断点均保留。")
                }
                let delay = min(60, retryDelay * Double(attempt))
                log("警告：\(error.localizedDescription) ⏳ \(Int(delay)) 秒后重新获取下载凭证并第 \(attempt + 1)/6 次下载；不重新上传或加固。")
                Thread.sleep(forTimeInterval: delay)
            }
        }
        throw BangcleFailure.message("下载任务已暂停，断点已保留。")
    }
    private func downloadAttempt(appID: String, partial: URL) throws {
        stage = "梆梆获取本次任务下载凭证"
        let code = try json("devwebsite/reinforces/downApkCode", fields: ["appId": appID, "hideDownloadNotice": "false"])
        guard let info = code["info"] as? [String: Any] else { throw BangcleFailure.message("梆梆未返回下载凭证。") }
        var components = URLComponents(url: base.appendingPathComponent("devwebsite/reinforces/downloadFile"), resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = []
        for (key, field) in [("id", "model_id"), ("sid", "sid"), ("user_id", "user_id"), ("code", "code")] {
            guard let value = info[field], !(value is NSNull) else { throw BangcleFailure.message("梆梆下载信息缺少 \(field)。") }
            query.append(URLQueryItem(name: key, value: String(describing: value)))
        }
        components.queryItems = query; stage = "梆梆下载加固 APK"
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try request(components.url!, downloadTo: partial)
    }
    private func validateAPK(_ temp: URL) throws {
        stage = "校验梆梆加固 APK"
        log("⏳ \(stage)")
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        check.arguments = ["-tq", temp.path]; check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        try check.run(); check.waitUntilExit()
        guard check.terminationStatus == 0 else {
            if let reader = try? FileHandle(forReadingFrom: temp) {
                let prefix = (try? reader.read(upToCount: 16384)) ?? Data()
                try? reader.close()
                if String(decoding: prefix, as: UTF8.self).contains("/authcenter/Users/") { throw BangcleFailure.loginExpired }
            }
            throw BangcleFailure.message("梆梆下载内容不是完整 APK，未将其交给第二步。")
        }
        let manifest = Process(); manifest.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        manifest.arguments = ["-Z1", temp.path, "AndroidManifest.xml"]
        manifest.standardOutput = FileHandle.nullDevice; manifest.standardError = FileHandle.nullDevice
        try manifest.run(); manifest.waitUntilExit()
        guard manifest.terminationStatus == 0 else { throw BangcleFailure.message("梆梆下载文件缺少 AndroidManifest.xml，未将其交给第二步。") }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incoming: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let partialFile, let http = incoming as? HTTPURLResponse else { completionHandler(.allow); return }
        do {
            if http.statusCode == 401 || http.url?.path.contains("/authcenter/") == true { throw BangcleFailure.loginExpired }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                if http.statusCode == 416 {
                    try? FileManager.default.removeItem(at: partialFile)
                    try? FileManager.default.removeItem(at: partialFile.appendingPathExtension("json"))
                }
                throw BangcleFailure.http(http.statusCode)
            }
            guard !(http.mimeType ?? "").contains("text/html") else { throw BangcleFailure.downloadRetry("下载接口返回网页，保留原文件并重新获取下载凭证。") }
            let etag = http.value(forHTTPHeaderField: "ETag")
            let validator = etag.flatMap { $0.hasPrefix("W/") ? nil : $0 } ?? http.value(forHTTPHeaderField: "Last-Modified")
            if http.statusCode == 206 {
                let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                let pieces = range.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
                let bounds = pieces.first?.split(separator: "-") ?? []
                guard pieces.count == 2, bounds.count == 2, Int64(bounds[0]) == offset,
                      let total = Int64(pieces[1]), let end = Int64(bounds[1]), end >= offset, end < total,
                      receipt == nil || receipt!.total <= 0 || receipt!.total == total,
                      receipt?.validator == nil || receipt?.validator == validator else {
                    try? FileManager.default.removeItem(at: partialFile)
                    try? FileManager.default.removeItem(at: partialFile.appendingPathExtension("json"))
                    throw BangcleFailure.downloadRetry("服务器续传范围或文件标识已变化，将重新获取完整文件。")
                }
                expected = total
            } else {
                if offset > 0 { log("警告：服务器未接受断点续传，本次安全地重新下载，不拼接旧数据。") }
                offset = 0; expected = http.expectedContentLength
            }
            if !FileManager.default.fileExists(atPath: partialFile.path) {
                FileManager.default.createFile(atPath: partialFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let writer = try FileHandle(forWritingTo: partialFile)
            if offset == 0 { try writer.truncate(atOffset: 0) }
            try writer.seek(toOffset: UInt64(offset)); partialWriter = writer
            let metadata = partialFile.appendingPathExtension("json")
            try JSONEncoder().encode(DownloadReceipt(validator: validator, total: expected)).write(to: metadata, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let partialWriter {
            do { try partialWriter.write(contentsOf: data); received += Int64(data.count); progress(offset + received, expected) }
            catch { failure = error; dataTask.cancel() }
        } else { body.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let partialWriter {
            do { try partialWriter.synchronize(); try partialWriter.close() }
            catch { if failure == nil { failure = error } }
            self.partialWriter = nil
        }
        response = task.response as? HTTPURLResponse; if failure == nil { failure = error }; done.signal()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { progress(totalBytesSent, totalBytesExpectedToSend) }
    private func progress(_ count: Int64, _ total: Int64) {
        guard stage == "梆梆上传 APK" || stage == "梆梆下载加固 APK" else { return }
        guard Date().timeIntervalSince(lastProgress) >= progressInterval else { return }; lastProgress = Date()
        let megabytes = String(format: "%.1f", Double(count) / 1048576)
        let totalMegabytes = String(format: "%.1f", Double(total) / 1048576)
        log("\(stage)：\(megabytes) MB" + (total > 0 ? " / \(totalMegabytes) MB（\(count * 100 / total)%）" : ""))
    }
    private var progressInterval: TimeInterval {
        if stage == "梆梆上传 APK" { return 30 }
        if stage == "梆梆下载加固 APK" { return 15 }
        return 5
    }
}
