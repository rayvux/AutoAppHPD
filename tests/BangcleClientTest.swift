import Foundation

@main
enum BangcleClientTest {
    static func main() throws {
        let base = URL(string: CommandLine.arguments[1])!
        let file = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "testSession", .value: "test-only"])!
        let checkpoint = output.deletingPathExtension().appendingPathExtension("checkpoint.json")
        let client = BangcleClient(cookies: [cookie], baseURL: base, checkpoint: { saved in
            try JSONEncoder().encode(saved).write(to: checkpoint, options: .atomic)
        }, pollInterval: 0.05, retryDelay: 0.01) { print($0) }
        if CommandLine.arguments.last == "login" {
            try client.checkLogin()
        } else if CommandLine.arguments.last == "resume" {
            let saved = try JSONDecoder().decode(BangcleTaskRecord.self, from: Data(contentsOf: checkpoint))
            _ = try client.resume(saved)
        } else if CommandLine.arguments.last == "query" {
            _ = try client.queryTask(appID: "123")
        } else if CommandLine.arguments.count > 4 {
            _ = try client.download(appID: "123", output: output)
        } else { _ = try client.harden(file, output: output) }
    }
}
