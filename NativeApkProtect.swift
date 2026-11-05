import Foundation
import CryptoKit

// Native implementation of the Baidu v5 upload/task/download protocol.
// CLI flags stay compatible with the GUI; no Intel helper or Rosetta is needed.
private enum ClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private func emit(_ text: String) { print(text); fflush(stdout) }
private func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func fileMD5(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = Insecure.MD5()
    while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
private func encode(_ text: String, slash: Bool = false) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~" + (slash ? "/" : ""))
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
}
private func hmac(_ key: String, _ text: String) -> String {
    HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(key.utf8)))
        .map { String(format: "%02x", $0) }.joined()
}

private final class Transfer: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    let done = DispatchSemaphore(value: 0)
    var response: HTTPURLResponse?
    var data = Data()
    var saved: URL?
    var error: Error?
    var lastProgress = Date.distantPast
    var label = "请求"
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { self.data.append(data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.response = task.response as? HTTPURLResponse
        if self.error == nil { self.error = error }; done.signal()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: target); saved = target
        } catch { self.error = error }
    }
    private func progress(_ current: Int64, _ total: Int64) {
        guard Date().timeIntervalSince(lastProgress) >= 2 || current == total else { return }
        lastProgress = Date()
        if total > 0 { emit("\(label)：\(current * 100 / total)%（\(current / 1048576)/\(total / 1048576) MB）") }
        else { emit("\(label)：\(current / 1048576) MB") }
    }
    func perform(_ request: URLRequest, upload: URL? = nil, download: Bool = false) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 1200
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task: URLSessionTask
        if let upload { task = session.uploadTask(with: request, fromFile: upload) }
        else if download { task = session.downloadTask(with: request) }
        else { task = session.dataTask(with: request) }
        task.resume()
        let started = Date()
        while done.wait(timeout: .now() + 5) == .timedOut {
            emit("⏳ \(label)（loading，已等待 \(Int(Date().timeIntervalSince(started))) 秒）")
        }
        if let error { if let saved { try? FileManager.default.removeItem(at: saved) }; throw error }
        guard let response, (200..<300).contains(response.statusCode) else {
            if let saved { try? FileManager.default.removeItem(at: saved) }
            throw ClientError.message("\(label)失败：HTTP \(response?.statusCode ?? 0)")
        }
        return data
    }
}

private struct NativeClient {
    let server: URL
    let akey: String
    let skey: String
    func json(_ path: String, fields: [String: String]? = nil) throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: server) else { throw ClientError.message("无效服务地址") }
        var request = URLRequest(url: url)
        if let fields {
            let boundary = UUID().uuidString
            let body = fields.sorted(by: { $0.key < $1.key }).map {
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\($0.key)\"\r\n\r\n\($0.value)\r\n"
            }.joined() + "--\(boundary)--\r\n"
            request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        let transfer = Transfer(); transfer.label = "百度接口请求"
        let bytes = try transfer.perform(request)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ClientError.message("百度接口返回了无效数据")
        }
        guard object["success"] as? Bool == true else {
            let message = (object["message"] as? String) ?? (object["msg"] as? String) ?? "请求未成功"
            throw ClientError.message(message.replacingOccurrences(of: akey, with: "******")
                .replacingOccurrences(of: skey.isEmpty ? "__EMPTY_SECRET__" : skey, with: "******"))
        }
        guard let data = object["data"] as? [String: Any] else { throw ClientError.message("百度接口缺少 data") }
        return data
    }
    func upload(_ file: URL, type: String) throws -> String {
        emit("Uploading file to server（Apple 芯片原生上传）")
        let sts = try json("/api/v5/apk/sts")
        func value(_ name: String) throws -> String {
            guard let text = sts[name] as? String, !text.isEmpty else { throw ClientError.message("上传配置缺少 \(name)") }
            return text
        }
        let ak = try value("ak"), sk = try value("sk"), token = try value("token")
        let bucket = try value("bucket"), prefix = try value("key")
        let filename = md5(Data(file.deletingPathExtension().lastPathComponent.utf8)) + "." + file.pathExtension
        let objectKey = prefix + filename
        // Test servers may explicitly route their own local BOS endpoint. Production
        // always uses the Baidu BOS domain, never a server-supplied external host.
        let local = server.host == "127.0.0.1" || server.host == "localhost"
        let host = local ? server.host! + ":\(server.port!)" : "\(bucket).bj.bcebos.com"
        let scheme = local ? server.scheme! : "https"
        let path = "/" + encode(objectKey, slash: true)
        guard let url = URL(string: "\(scheme)://\(host)\(path)") else { throw ClientError.message("上传地址无效") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date())
        let info = "bce-auth-v1/\(ak)/\(stamp)/1800"
        let headers = ["host": host, "x-bce-date": stamp, "x-bce-security-token": token]
        let canonical = headers.sorted { $0.key < $1.key }.map { encode($0.key) + ":" + encode($0.value) }.joined(separator: "\n")
        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let signature = hmac(hmac(sk, info), "PUT\n\(path)\n\n\(canonical)")
        var request = URLRequest(url: url); request.httpMethod = "PUT"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("\(info)/\(signedHeaders)/\(signature)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.android.package-archive", forHTTPHeaderField: "Content-Type")
        let transfer = Transfer(); transfer.label = "上传 APK"
        _ = try transfer.perform(request, upload: file)
        emit("上传成功，正在创建加固任务")
        let sign = md5(Data((akey + (try fileMD5(file)) + skey).utf8))
        let result = try json("/api/v5/apk?Q=native", fields: [
            "type": type, "lib": "", "akey": akey, "timestamp": String(Int(Date().timeIntervalSince1970)),
            "sign": sign, "shellVersion": "", "configID": "0", "bos_path": objectKey
        ])
        guard let task = result["taskId"] as? String, !task.isEmpty else { throw ClientError.message("百度未返回 taskId") }
        emit("TaskId is \(task)")
        return task
    }
    func download(task: String, output: URL, timeout: Int) throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            let result = try json("/api/v5/apk/status?task_id=\(encode(task))&akey=\(encode(akey))")
            let status = result["status"] as? Int ?? -1
            if status == 100 {
                emit("Protection task complete, start downloading protected apk.")
                var candidates: [URL] = []
                for name in ["url", "backup_url"] {
                    if let text = result[name] as? String, !text.isEmpty,
                       let resolved = URL(string: text, relativeTo: server)?.absoluteURL,
                       var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) {
                        if components.scheme == "http", components.host != "127.0.0.1", components.host != "localhost" { components.scheme = "https" }
                        if let url = components.url { candidates.append(url) }
                    }
                }
                var lastError: Error = ClientError.message("百度未提供下载地址")
                for url in candidates {
                    let transfer = Transfer(); transfer.label = "下载加固 APK"
                    do {
                        _ = try transfer.perform(URLRequest(url: url), download: true)
                        guard let saved = transfer.saved else { throw ClientError.message("未收到下载文件") }
                        defer { try? FileManager.default.removeItem(at: saved) }
                        guard let expected = result["md5"] as? String, expected.count == 32,
                              try fileMD5(saved) == expected.lowercased() else { throw ClientError.message("加固 APK 的 MD5 校验失败") }
                        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                        try FileManager.default.moveItem(at: saved, to: output)
                        emit("Verifying md5 checksum success"); emit("Done, file saved at \(output.path)"); return
                    } catch { lastError = error; emit("警告：下载当前节点失败，尝试备用节点") }
                }
                throw lastError
            }
            guard (0..<100).contains(status) else { throw ClientError.message("百度加固失败：\(result["message"] as? String ?? "未知错误")") }
            emit("Protection task is running（loading），taskID: \(task)")
            Thread.sleep(forTimeInterval: 5)
        }
        emit("task is still running, you can try download packed file by -g flag and taskID: \(task)")
    }
}

@main
enum NativeApkProtectMain {
    static func main() {
        var arguments: [String: String] = [:]
        for arg in CommandLine.arguments.dropFirst() {
            let parts = arg.drop(while: { $0 == "-" }).split(separator: "=", maxSplits: 1).map(String.init)
            if !parts.isEmpty { arguments[parts[0]] = parts.count == 2 ? parts[1] : "true" }
        }
        if arguments["V"] != nil { emit("AutoAppHPD native Baidu client 1.0 (arm64 / x86_64)"); return }
        do {
            guard let akey = arguments["akey"], !akey.isEmpty,
                  let output = arguments["o"], !output.isEmpty else { throw ClientError.message("缺少 AKEY 或输出路径") }
            guard let server = URL(string: arguments["url"] ?? "https://apkprotect.baidu.com"),
                  server.scheme == "https" || (server.scheme == "http" && ["127.0.0.1", "localhost"].contains(server.host ?? "")) else {
                throw ClientError.message("服务地址必须使用 HTTPS")
            }
            let client = NativeClient(server: server, akey: akey, skey: arguments["skey"] ?? "")
            let task: String
            if let existing = arguments["g"] { task = existing }
            else {
                guard let input = arguments["i"], arguments["skey"]?.isEmpty == false else { throw ClientError.message("缺少输入 APK 或 SKEY") }
                task = try client.upload(URL(fileURLWithPath: input), type: arguments["type"] ?? "free")
            }
            try client.download(task: task, output: URL(fileURLWithPath: output), timeout: Int(arguments["t"] ?? "900") ?? 900)
        } catch { emit("错误：\(error.localizedDescription)"); exit(1) }
    }
}
