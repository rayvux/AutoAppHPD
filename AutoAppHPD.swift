import AppKit
import Foundation
import UniformTypeIdentifiers

private let toolVersion = "2.6.0"

private struct PendingBangcleJob: Codable {
    var task: BangcleTaskRecord
    let releaseApk, keystore, alias: String
    let completeFlow: Bool
}

private struct Settings: Codable {
    var sdk = "", releaseApk = "", hardenedApk = "", keystore = ""
    var alias = "key0", vasDolly = "", channels = "", output = ""
    var credentialProject: String?
    var baiduEnabled: Bool?
    var hardeningProvider: String?
}

private struct SavedCredentials: Codable, Equatable {
    let baiduAKey, baiduSKey, storePassword, keyPassword: String
}

private struct SigningCredentials: Codable, Equatable {
    let alias, storePassword, keyPassword: String
}

private struct SecretEditor {
    let secure: NSSecureTextField
    let plain: NSTextField
}

private struct Values {
    let sdk, releaseApk, hardenedApk, keystore, alias: String
    let vasDolly, channels, output, storePassword, keyPassword: String
    let baiduAKey, baiduSKey, hardenType: String
    let baiduEnabled: Bool
    let hardeningProvider: String
}

private enum LogLevel { case info, warning, error }

private struct Tools {
    let buildTools, zipalign, apksigner, aapt, java: URL
    let passwords: [String: String]
}

private struct Naming { let app, version: String }

private enum Failure: LocalizedError {
    case text(String)
    var errorDescription: String? { if case .text(let value) = self { return value }; return nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let fm = FileManager.default
    private var window: NSWindow!
    private var fields: [String: NSTextField] = [:]
    private var secretEditors: [String: SecretEditor] = [:]
    private var logView: NSTextView!
    private var firstButton: NSButton!
    private var providerPicker: NSPopUpButton!
    private let bangcleLogin = BangcleLogin()
    private var bangcleCookies: [HTTPCookie] = []
    private var packageButton: NSButton!
    private var completeButton: NSButton!
    private var resumeButton: NSButton!
    private var loginButton: NSButton!
    private var credentialRows: [String: NSGridRow] = [:]
    private var progressIndicator: NSProgressIndicator!
    private var currentRun: URL?
    private var currentHardened: URL?
    private var activeCredentialProject: String?
    private var activeKeystore = ""
    private var restoringCredentials = false
    private var pendingBangcle: PendingBangcleJob?
    private var activeCompleteFlow = false
    private var loginRecoveries = 0
    private lazy var pendingBangcleFile = settingsFile.deletingLastPathComponent().appendingPathComponent("pending-bangcle-task.json")

    private lazy var settingsFile: URL = {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidReleaseTool/settings.json")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        makeUI()
        loadSettings()
        hardeningChanged()
        if let data = try? Data(contentsOf: pendingBangcleFile),
           let saved = try? JSONDecoder().decode(PendingBangcleJob.self, from: data) {
            pendingBangcle = saved
            log("发现未完成的梆梆任务 \(saved.task.appID)，可点击“续接梆梆任务”，登录后先查询原任务，不重复上传。", level: .warning)
        }
        log("工具 v\(toolVersion) 已就绪。密码不会写入设置文件。")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(logView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) {
        saveCredentialsIfNeeded(readValues())
        saveSettings()
    }

    private func makeUI() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "AutoAppHPD v\(toolVersion)"
        window.minSize = NSSize(width: 820, height: 780)
        window.center(); window.delegate = self

        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView(); window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16)
        ])

        let grid = NSGridView(); grid.rowSpacing = 8; grid.columnSpacing = 8
        root.addArrangedSubview(grid); grid.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        add(grid, "sdk", "Android SDK", detectSDK()?.path ?? "", "folder")
        add(grid, "releaseApk", "Release APK（待签名）", "", "apk")
        add(grid, "hardenedApk", "Release APK（已加固）", "", "apk")
        providerPicker = NSPopUpButton()
        providerPicker.addItems(withTitles: ["不加固", "百度", "梆梆"])
        providerPicker.selectItem(withTitle: "百度")
        providerPicker.target = self; providerPicker.action = #selector(hardeningChanged)
        loginButton = NSButton(title: "梆梆登录", target: self, action: #selector(checkBangcleLoginOnly))
        grid.addRow(with: [NSTextField(labelWithString: "加固方式"), providerPicker, loginButton])
        add(grid, "baiduAKey", "百度 AKEY", "", "", secure: true)
        add(grid, "baiduSKey", "百度 SKEY", "", "", secure: true)
        add(grid, "hardenType", "加固类型", "free", "")
        add(grid, "keystore", "Keystore", "", "keystore")
        add(grid, "alias", "Key Alias", "key0", "")
        add(grid, "vasDolly", "VasDolly.jar", bundledVasDolly().path, "jar")
        add(grid, "channels", "渠道文件", defaultChannels().path, "txt")
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        add(grid, "output", "输出目录", desktop.appendingPathComponent("AndroidReleaseOutput").path, "folder")
        add(grid, "storePassword", "Store 密码", "", "", secure: true)
        add(grid, "keyPassword", "Key 密码", "", "", secure: true)
        grid.column(at: 0).width = 150; grid.column(at: 2).width = 82

        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 10
        firstButton = NSButton(title: "1. 签名并加固", target: self, action: #selector(firstSign))
        packageButton = NSButton(title: "2. 对齐、重签并生成渠道包", target: self, action: #selector(package))
        buttons.addArrangedSubview(firstButton); buttons.addArrangedSubview(packageButton)
        buttons.addArrangedSubview(NSButton(title: "清空日志", target: self, action: #selector(clearLog)))
        buttons.addArrangedSubview(NSButton(title: "清除本地凭据", target: self, action: #selector(clearSavedCredentials)))
        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning; progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true; progressIndicator.isDisplayedWhenStopped = false
        buttons.addArrangedSubview(progressIndicator)
        root.addArrangedSubview(buttons)

        completeButton = NSButton(title: "一键签名、加固、对齐、重签并生成渠道包", target: self, action: #selector(completeRelease))
        root.addArrangedSubview(completeButton)
        resumeButton = NSButton(title: "续接梆梆任务（不重复上传）", target: self, action: #selector(resumeBangcleTask))
        root.addArrangedSubview(resumeButton)

        let logTitle = NSTextField(labelWithString: "执行日志（实时）")
        logTitle.font = .boldSystemFont(ofSize: 13)
        root.addArrangedSubview(logTitle)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        logView = NSTextView(); logView.isEditable = false; logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.textContainerInset = NSSize(width: 8, height: 8); scroll.documentView = logView
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    }

    private func add(_ grid: NSGridView, _ key: String, _ title: String, _ value: String,
                     _ browse: String, secure: Bool = false) {
        let label = NSTextField(labelWithString: title); label.alignment = .right
        if secure {
            let secureField = NSSecureTextField(), plainField = NSTextField()
            for field in [secureField, plainField] {
                field.stringValue = value; field.lineBreakMode = .byTruncatingMiddle
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                field.translatesAutoresizingMaskIntoConstraints = false
                field.delegate = self
            }
            plainField.isHidden = true
            let holder = NSView(); holder.addSubview(secureField); holder.addSubview(plainField)
            NSLayoutConstraint.activate([
                secureField.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                secureField.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                secureField.topAnchor.constraint(equalTo: holder.topAnchor),
                secureField.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                plainField.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                plainField.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                plainField.topAnchor.constraint(equalTo: holder.topAnchor),
                plainField.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
            ])
            let button = NSButton(title: "显示", target: self, action: #selector(toggleSecretVisibility(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(key)
            grid.addRow(with: [label, holder, button])
            credentialRows[key] = grid.row(at: grid.numberOfRows - 1)
            fields[key] = secureField; secretEditors[key] = SecretEditor(secure: secureField, plain: plainField)
            return
        }
        let field = NSTextField()
        field.stringValue = value; field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = self
        let button = NSButton(title: browse.isEmpty ? "" : "浏览…", target: self, action: #selector(browse(_:)))
        button.isEnabled = !browse.isEmpty
        button.identifier = NSUserInterfaceItemIdentifier("\(key)|\(browse)")
        grid.addRow(with: [label, field, button]); fields[key] = field
        credentialRows[key] = grid.row(at: grid.numberOfRows - 1)
    }

    @objc private func browse(_ sender: NSButton) {
        guard firstButton.isEnabled else { return }
        guard let raw = sender.identifier?.rawValue else { return }
        let bits = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard bits.count == 2, let field = fields[bits[0]] else { return }
        let panel = NSOpenPanel(); let folder = bits[1] == "folder"
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.canCreateDirectories = folder; panel.allowsMultipleSelection = false
        let types = ["apk": ["apk"], "keystore": ["jks", "keystore"], "jar": ["jar"], "txt": ["txt"]]
        if !folder { panel.allowedContentTypes = (types[bits[1]] ?? []).compactMap { UTType(filenameExtension: $0) } }
        let current = URL(fileURLWithPath: field.stringValue)
        if fm.fileExists(atPath: current.path) { panel.directoryURL = folder ? current : current.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
            if ["releaseApk", "keystore"].contains(bits[0]) { projectConfigurationChanged() }
            if bits[0] == "hardenedApk" { currentHardened = nil; currentRun = nil }
            saveSettings()
        }
    }

    @objc private func toggleSecretVisibility(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let editor = secretEditors[key] else { return }
        if editor.plain.isHidden {
            editor.plain.stringValue = editor.secure.stringValue
            editor.secure.isHidden = true; editor.plain.isHidden = false
            fields[key] = editor.plain; sender.title = "隐藏"
        } else {
            editor.secure.stringValue = editor.plain.stringValue
            editor.plain.isHidden = true; editor.secure.isHidden = false
            fields[key] = editor.secure; sender.title = "显示"
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if ["releaseApk", "keystore"].contains(where: { field === fields[$0] }) { projectConfigurationChanged() }
        if field === fields["hardenedApk"] { currentHardened = nil; currentRun = nil }
        saveCredentialsIfNeeded(readValues()); saveSettings()
    }
    func controlTextDidChange(_ obj: Notification) {
        guard !restoringCredentials, let field = obj.object as? NSTextField,
              ["baiduAKey", "baiduSKey", "alias", "storePassword", "keyPassword"].contains(where: { field === fields[$0] }) else { return }
        saveCredentialsIfNeeded(readValues())
    }

    @objc private func clearLog() { logView.string = "" }
    @objc private func clearSavedCredentials() {
        guard firstButton.isEnabled else { return }
        let alert = NSAlert(); alert.messageText = "清除当前项目凭据？"
        alert.informativeText = "将删除当前项目目录中保存的百度和签名凭据，此操作不可撤销。"
        alert.alertStyle = .warning; alert.addButton(withTitle: "清除"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if let file = self.credentialsFile() { try? self.fm.removeItem(at: file) }
            if let file = self.signingCredentialsFile(self.activeKeystore) { try? self.fm.removeItem(at: file) }
            self.clearSecretFields()
            self.log("当前项目的本地凭据已清除。", level: .warning)
        }
    }
    @objc private func firstSign() {
        startSigning(complete: false)
    }
    @objc private func completeRelease() {
        guard providerPicker.titleOfSelectedItem != "不加固" else { return }
        startSigning(complete: true)
    }
    private func startSigning(complete: Bool) {
        if providerPicker.titleOfSelectedItem == "梆梆", pendingBangcle != nil {
            log("存在未完成任务，先续接原任务，不重新签名或上传。", level: .warning)
            resumeBangcleTask(); return
        }
        activeCompleteFlow = complete; loginRecoveries = 0
        let work: (Values) throws -> URL = { values in
            let hardened = try self.signAndHarden(values)
            let result: URL
            if complete {
                self.log("加固已完成，已更新 Release APK（已加固），继续对齐、重签并生成渠道包。")
                result = try self.makePackages(values)
            } else { result = hardened }
            if values.hardeningProvider == "梆梆" { try self.finishPendingBangcle() }
            return result
        }
        if providerPicker.titleOfSelectedItem == "梆梆" {
            setBusy(true)
            log("正在确认梆梆登录；首次使用或会话过期时，请在官方登录窗口完成登录。")
            bangcleLogin.diagnostic = { self.log($0) }
            bangcleLogin.present { cookies in
                guard let cookies, !cookies.isEmpty else { self.setBusy(false); self.log("梆梆登录已取消。", level: .warning); return }
                self.bangcleCookies = cookies
                self.runTask(work)
            }
        } else { runTask(work) }
    }
    @objc private func checkBangcleLoginOnly() {
        guard firstButton.isEnabled else { return }
        setBusy(true)
        log(pendingBangcle == nil ? "仅验证梆梆登录，不操作线上任务。" : "重新登录后自动查询并续接已保存的原任务，不重复上传。")
        bangcleLogin.diagnostic = { self.log($0) }
        bangcleLogin.present { cookies in
            self.setBusy(false)
            if let cookies, !cookies.isEmpty {
                self.bangcleCookies = cookies
                self.log("梆梆登录成功，软件端会话已通过服务器只读接口验证。")
                if self.pendingBangcle != nil { self.continuePendingBangcle() }
                else { self.alert("梆梆登录验证成功", "本次只验证登录，没有操作线上应用。", .informational) }
            } else { self.log("梆梆登录验证已取消。", level: .warning) }
        }
    }
    @objc private func resumeBangcleTask() {
        guard firstButton.isEnabled else { return }
        guard pendingBangcle != nil else { alert("没有待续接任务", "没有发现本地保存的梆梆任务断点。", .informational); return }
        loginRecoveries = 0
        checkBangcleLoginOnly()
    }
    private func continuePendingBangcle() {
        guard let job = pendingBangcle else { setBusy(false); return }
        let values = readValues()
        guard values.releaseApk == job.releaseApk, values.keystore == job.keystore, values.alias == job.alias else {
            setBusy(false)
            alert("原任务配置已更换", "请恢复原任务的 Release APK、Keystore 和 Alias 后再续接。断点已保留，不会上传或修改其他任务。", .warning)
            return
        }
        log("续接原任务 \(job.task.appID)，先只读查询状态；已经加固或正在处理时不再提交。")
        runTask { v in
            self.currentRun = URL(fileURLWithPath: job.task.outputPath).deletingLastPathComponent().deletingLastPathComponent()
            let client = self.bangcleClient(v, complete: job.completeFlow)
            let apk = try client.resume(job.task)
            self.currentHardened = apk; self.publishHardened(apk)
            let result = job.completeFlow ? try self.makePackages(v) : apk
            try self.finishPendingBangcle()
            return result
        }
    }
    private func bangcleClient(_ values: Values, complete: Bool) -> BangcleClient {
        BangcleClient(cookies: bangcleCookies, checkpoint: { record in
            let job = PendingBangcleJob(task: record, releaseApk: values.releaseApk,
                                       keystore: values.keystore, alias: values.alias, completeFlow: complete)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(job)
            try self.fm.createDirectory(at: self.pendingBangcleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: self.pendingBangcleFile, options: .atomic)
            try self.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.pendingBangcleFile.path)
            try data.write(to: URL(fileURLWithPath: record.outputPath).deletingLastPathComponent().appendingPathComponent("梆梆任务断点.json"), options: .atomic)
            DispatchQueue.main.sync { self.pendingBangcle = job }
        }) { message in self.log(message, level: self.logLevel(for: message)) }
    }
    private func finishPendingBangcle() throws {
        if fm.fileExists(atPath: pendingBangcleFile.path) { try fm.removeItem(at: pendingBangcleFile) }
        DispatchQueue.main.sync { self.pendingBangcle = nil }
    }
    @objc private func hardeningChanged() {
        let provider = providerPicker.titleOfSelectedItem ?? "不加固"
        firstButton.title = provider == "不加固" ? "1. 仅签名" : "1. 签名并加固（\(provider)）"
        for key in ["baiduAKey", "baiduSKey", "hardenType"] { credentialRows[key]?.isHidden = provider != "百度" }
        loginButton.isHidden = provider != "梆梆"
        resumeButton.isHidden = provider != "梆梆"
        completeButton.isHidden = provider == "不加固"
        if provider == "百度" { restoreBaiduCredentials() }
        saveSettings()
    }
    @objc private func package() { runTask { try self.makePackages($0) } }

    private func runTask(_ work: @escaping (Values) throws -> URL) {
        let values = readValues(); saveCredentialsIfNeeded(values); saveSettings(); setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try work(values)
                DispatchQueue.main.async {
                    self.setBusy(false); self.alert("处理完成", "已生成：\n\(result.path)", .informational)
                    let location = result.pathExtension.lowercased() == "apk" ? result.deletingLastPathComponent() : result
                    NSWorkspace.shared.open(location)
                }
            } catch {
                if let failure = error as? BangcleFailure, case .loginExpired = failure, self.pendingBangcle != nil {
                    DispatchQueue.main.async {
                        self.setBusy(false)
                        self.log("梆梆会话失效，原任务断点已保存，等待重新登录后自动续接。", level: .warning)
                        if self.loginRecoveries < 3 {
                            self.loginRecoveries += 1
                            self.checkBangcleLoginOnly()
                        } else {
                            self.log("连续会话失效，已暂停原任务；可点击“续接梆梆任务”重试，不会重复上传。", level: .warning)
                        }
                    }
                    return
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.log("错误：\(message)", level: .error)
                DispatchQueue.main.async { self.setBusy(false); self.alert("执行失败", message, .critical) }
            }
        }
    }

    private func signAndHarden(_ v: Values) throws -> URL {
        let apk = try requireFile(v.releaseApk, "Release APK")
        let allowedTypes = ["free", "standard", "ultimate", "so", "jar"]
        let hardenType = v.hardenType.lowercased()
        if v.baiduEnabled && !allowedTypes.contains(hardenType) {
            throw Failure.text("加固类型仅支持：\(allowedTypes.joined(separator: ", "))。")
        }
        if v.baiduEnabled && (v.baiduAKey.isEmpty || v.baiduSKey.isEmpty) {
            throw Failure.text("启用百度加固时需要填写 AKEY 和 SKEY。")
        }
        let run = try newRun(v.output); currentRun = run
        currentHardened = nil
        let usesHardening = v.hardeningProvider != "不加固"
        let pending = run.appendingPathComponent(usesHardening ? "待加固" : "签名后", isDirectory: true)
        let hardenedDirectory = run.appendingPathComponent("加固后", isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: true)
        if usesHardening { try fm.createDirectory(at: hardenedDirectory, withIntermediateDirectories: true) }
        log("已创建本次任务目录：\(run.path)")
        let tools = try resolveTools(v), naming = try readNaming(apk, tools)
        let signed = pending.appendingPathComponent("\(naming.app)-\(naming.version)_signed.apk")
        let hardened = hardenedDirectory.appendingPathComponent("\(naming.app)-\(naming.version)_hardened.apk")
        let downloadTarget = run.appendingPathComponent("hardened-download.apk")
        log("使用 Build Tools：\(tools.buildTools.path)"); log("开始签名……")
        try execute(tools.apksigner, signArguments(v, signed, apk), run, tools.passwords, true,
                    activity: "正在签名 APK")
        try execute(tools.apksigner, ["verify", "--verbose", "--print-certs", signed.path], run, [:], true,
                    activity: "正在校验签名")
        log("签名完成：\(signed.path)")
        if !usesHardening {
            currentHardened = signed
            publishHardened(signed)
            log("未启用加固，本次仅签名完成；第二步可直接使用此签名包。")
            return signed
        }
        if v.hardeningProvider == "梆梆" {
            let result = try bangcleClient(v, complete: activeCompleteFlow).harden(signed, output: hardened)
            currentHardened = result
            publishHardened(result)
            return result
        }
        let client = try requireFile(bundledApkProtect().path, "百度加固客户端")
        guard fm.isExecutableFile(atPath: client.path) else { throw Failure.text("百度加固客户端不可执行：\(client.path)") }
        log("⏳ 正在上传 APK（loading）……")
        let args = ["-akey=\(v.baiduAKey)", "-skey=\(v.baiduSKey)", "-i=\(signed.path)",
                    "-o=\(downloadTarget.path)", "-type=\(hardenType)", "-t=900", "-p", "-v"]
        let safeArgs = ["-akey=******", "-skey=******", "-i=\(signed.path)",
                        "-o=\(downloadTarget.path)", "-type=\(hardenType)", "-t=900", "-p", "-v"]
        var clientOutput = try execute(client, args, run, [:], true, displayArguments: safeArgs,
                                       activity: "正在上传、等待百度加固并下载 APK")
        if !fm.fileExists(atPath: downloadTarget.path), let taskID = taskID(from: clientOutput) {
            log("百度任务仍在处理中，已取得 taskID，将自动继续等待并下载。", level: .warning)
            for attempt in 1...3 where !fm.fileExists(atPath: downloadTarget.path) {
                let retry = ["-akey=\(v.baiduAKey)", "-g=\(taskID)", "-o=\(downloadTarget.path)", "-t=900", "-v"]
                let safeRetry = ["-akey=******", "-g=\(taskID)", "-o=\(downloadTarget.path)", "-t=900", "-v"]
                log("⏳ 第 \(attempt) 次继续等待百度任务并下载（loading）……")
                clientOutput += "\n" + (try execute(client, retry, run, [:], true, displayArguments: safeRetry,
                                                   activity: "正在等待百度任务并下载 APK"))
            }
        }
        if !fm.fileExists(atPath: downloadTarget.path),
           let candidate = hardenedCandidate(in: run, excluding: signed) {
            log("百度客户端使用了不同文件名，已找到下载产物：\(candidate.path)", level: .warning)
            try fm.moveItem(at: candidate, to: downloadTarget)
        }
        guard fm.fileExists(atPath: downloadTarget.path) else {
            let taskNote = taskID(from: clientOutput).map { "，taskID：\($0)" } ?? ""
            throw Failure.text("百度任务结束后未找到下载的加固包\(taskNote)。任务目录已保留：\(run.path)")
        }
        let attributes = try fm.attributesOfItem(atPath: downloadTarget.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw Failure.text("下载的加固包为空文件：\(downloadTarget.path)")
        }
        if fm.fileExists(atPath: hardened.path) { try fm.removeItem(at: hardened) }
        try fm.moveItem(at: downloadTarget, to: hardened)
        _ = try requireFile(hardened.path, "百度加固产物")
        currentHardened = hardened
        publishHardened(hardened)
        log("✓ 加固包已下载到本次任务目录：\(hardened.path)")
        return hardened
    }

    private func publishHardened(_ apk: URL) {
        DispatchQueue.main.sync {
            self.fields["hardenedApk"]?.stringValue = apk.path
            self.saveSettings()
        }
    }

    private func makePackages(_ v: Values) throws -> URL {
        let release = try requireFile(v.releaseApk, "Release APK（用于确定最终文件名）")
        let hardened: URL
        if let currentHardened, fm.fileExists(atPath: currentHardened.path) {
            hardened = currentHardened
            log("使用第一步生成的 APK：\(hardened.path)")
        } else {
            hardened = try requireFile(v.hardenedApk, "Release APK（已加固）")
            log("使用手动选择的加固 APK：\(hardened.path)", level: .warning)
        }
        let dolly = try requireFile(v.vasDolly, "VasDolly.jar")
        let channelFile = try requireFile(v.channels, "渠道文件")
        let tools = try resolveTools(v), naming = try readNaming(release, tools)
        let run: URL
        if let current = currentRun, fm.fileExists(atPath: current.path) {
            run = current
        } else if ["加固后", "签名后"].contains(hardened.deletingLastPathComponent().lastPathComponent) {
            run = hardened.deletingLastPathComponent().deletingLastPathComponent()
            log("已恢复加固包所属任务目录：\(run.path)")
        } else {
            run = try newRun(v.output)
        }
        currentRun = run
        let mothers = run.appendingPathComponent("母包", isDirectory: true)
        let channelsDir = run.appendingPathComponent("渠道包", isDirectory: true)
        try fm.createDirectory(at: mothers, withIntermediateDirectories: true)
        try fm.createDirectory(at: channelsDir, withIntermediateDirectories: true)
        let temp = fm.temporaryDirectory.appendingPathComponent("AndroidReleaseTool/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? fm.removeItem(at: temp) }
        let aligned = temp.appendingPathComponent("aligned.apk"), signed = temp.appendingPathComponent("signed.apk")
        let mother = mothers.appendingPathComponent("\(naming.app)-base-\(naming.version)_final.apk")

        log("使用 Build Tools：\(tools.buildTools.path)")
        try execute(tools.zipalign, ["-f", "-p", "4", hardened.path, aligned.path], temp, [:], true,
                    activity: "正在对齐加固 APK")
        try execute(tools.apksigner, signArguments(v, signed, aligned), temp, tools.passwords, true,
                    activity: "正在重新签名 APK")
        try execute(tools.zipalign, ["-c", "-v", "4", signed.path], temp, [:], true,
                    activity: "正在校验 APK 对齐")
        try execute(tools.apksigner, ["verify", "--verbose", "--print-certs", signed.path], temp, [:], true,
                    activity: "正在校验最终签名")
        if fm.fileExists(atPath: mother.path) { try fm.removeItem(at: mother) }
        try fm.copyItem(at: signed, to: mother)

        let text = try String(contentsOf: channelFile, encoding: .utf8)
        let channelNames = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !channelNames.isEmpty else { throw Failure.text("渠道文件中没有有效渠道。") }
        var expected = Set<String>()
        for channel in channelNames {
            guard !channel.contains(",") else { throw Failure.text("渠道名不能包含逗号：\(channel)") }
            let safe = safeName(channel), name = "\(naming.app)-\(safe)-\(naming.version)_final.apk"
            guard !safe.isEmpty, safe == channel, expected.insert(name).inserted else {
                throw Failure.text("渠道名包含文件名非法字符、重复或清理后重名：\(channel)")
            }
            let target = channelsDir.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            log("生成渠道包：\(channel)")
            try execute(tools.java, ["-jar", dolly.path, "put", "-c", channel, mother.path, channelsDir.path], temp)
            _ = try requireFile(target.path, "VasDolly 渠道包 \(channel)")
        }
        let actual = try fm.contentsOfDirectory(at: channelsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "apk" && $0.lastPathComponent.hasSuffix("_final.apk") }.count
        guard actual == channelNames.count else { throw Failure.text("渠道包数量不正确：期望 \(channelNames.count)，实际 \(actual)。") }

        let apks = recursiveApks(run).sorted { $0.path < $1.path }
        var sums: [String] = []
        for apk in apks {
            let output = try execute(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", apk.path], run, [:], false)
            guard let hash = output.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { throw Failure.text("无法计算 SHA256：\(apk.path)") }
            sums.append("\(hash)  \(apk.path.dropFirst(run.path.count + 1))")
        }
        try (sums.joined(separator: "\n") + "\n").write(to: run.appendingPathComponent("SHA256SUMS.txt"), atomically: true, encoding: .utf8)
        log("处理完成：\(run.path)"); return run
    }

    private func resolveTools(_ v: Values) throws -> Tools {
        _ = try requireFile(v.keystore, "Keystore")
        guard !v.alias.isEmpty else { throw Failure.text("Key Alias 不能为空。") }
        guard !v.storePassword.isEmpty, !v.keyPassword.isEmpty else { throw Failure.text("签名密码不能为空（密码不会保存）。") }
        let sdk = try requireDirectory(v.sdk, "Android SDK")
        let root = try requireDirectory(sdk.appendingPathComponent("build-tools").path, "Android build-tools 目录")
        let versions = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let complete = versions.filter { dir in
            ["zipalign", "apksigner", "aapt"].allSatisfy { fm.isExecutableFile(atPath: dir.appendingPathComponent($0).path) }
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let build = complete.first else { throw Failure.text("没有找到可用的 zipalign/apksigner/aapt：\(root.path)") }
        let java = try javaURL()
        return Tools(buildTools: build, zipalign: build.appendingPathComponent("zipalign"),
                     apksigner: build.appendingPathComponent("apksigner"), aapt: build.appendingPathComponent("aapt"),
                     java: java, passwords: ["ART_STORE_PASSWORD": v.storePassword, "ART_KEY_PASSWORD": v.keyPassword])
    }

    private func signArguments(_ v: Values, _ output: URL, _ input: URL) -> [String] {
        ["sign", "--v4-signing-enabled", "false", "--ks", v.keystore, "--ks-key-alias", v.alias,
         "--ks-pass", "env:ART_STORE_PASSWORD", "--key-pass", "env:ART_KEY_PASSWORD", "--out", output.path, input.path]
    }

    private func readNaming(_ apk: URL, _ tools: Tools) throws -> Naming {
        let output = try execute(tools.aapt, ["dump", "badging", apk.path], apk.deletingLastPathComponent(), [:], false)
        let regex = try NSRegularExpression(pattern: "versionName='([^']+)'")
        let full = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: full), let range = Range(match.range(at: 1), in: output) else {
            throw Failure.text("无法从 Release APK 读取 versionName。")
        }
        let rawVersion = String(output[range]), safeVersion = safeName(rawVersion)
        let base = apk.deletingPathExtension().lastPathComponent
        let escaped = NSRegularExpression.escapedPattern(for: rawVersion)
        var app = base.replacingOccurrences(of: "(?i)[_-]release[_-]\(escaped)$", with: "", options: .regularExpression)
        if app == base { app = base.replacingOccurrences(of: "[_-]\(escaped)$", with: "", options: .regularExpression) }
        app = safeName(app); if app.isEmpty { app = safeName(base) }
        return Naming(app: app, version: safeVersion)
    }

    @discardableResult
    private func execute(_ executable: URL, _ args: [String], _ cwd: URL,
                         _ extra: [String: String] = [:], _ show: Bool = true,
                         displayArguments: [String]? = nil, activity: String? = nil) throws -> String {
        if show { log(([executable.lastPathComponent] + (displayArguments ?? args)).map(display).joined(separator: " ")) }
        let activityText = activity ?? "正在执行 \(executable.lastPathComponent)"
        if show { log("⏳ \(activityText)（loading）……") }
        let startedAt = Date()
        var loadingTimer: DispatchSourceTimer?
        if show {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                let seconds = Int(Date().timeIntervalSince(startedAt))
                self?.log("⏳ \(activityText)（loading，已等待 \(seconds) 秒）……")
            }
            timer.resume(); loadingTimer = timer
        }
        defer { loadingTimer?.cancel() }
        let secrets = args.compactMap { argument -> String? in
            let lower = argument.lowercased()
            guard lower.hasPrefix("-akey=") || lower.hasPrefix("-skey=") else { return nil }
            guard let equals = argument.firstIndex(of: "=") else { return nil }
            return String(argument[argument.index(after: equals)...])
        }.filter { !$0.isEmpty }
        func sanitized(_ text: String) -> String {
            secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "******") }
        }
        let process = Process(); process.executableURL = executable; process.arguments = args; process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment; extra.forEach { environment[$0] = $1 }; process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let readerQueue = DispatchQueue(label: "AndroidReleaseTool.process-output")
        let reachedEOF = DispatchSemaphore(value: 0)
        var completeData = Data(), pendingData = Data(), didReachEOF = false
        func consume(_ data: Data, flush: Bool = false) {
            completeData.append(data); pendingData.append(data)
            while let newline = pendingData.firstIndex(of: 0x0A) {
                var lineData = pendingData.prefix(upTo: newline)
                pendingData.removeSubrange(...newline)
                if lineData.last == 0x0D { lineData = lineData.dropLast() }
                let line = sanitized(String(decoding: lineData, as: UTF8.self))
                if show && !line.isEmpty { logProcessLine(line) }
            }
            if flush && !pendingData.isEmpty {
                let line = sanitized(String(decoding: pendingData, as: UTF8.self))
                if show && !line.isEmpty { logProcessLine(line) }
                pendingData.removeAll(keepingCapacity: false)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            readerQueue.async {
                if data.isEmpty {
                    if !didReachEOF {
                        didReachEOF = true; consume(Data(), flush: true); reachedEOF.signal()
                    }
                } else {
                    consume(data)
                }
            }
        }
        do { try process.run() } catch { throw Failure.text("无法启动 \(executable.path)：\(error.localizedDescription)") }
        process.waitUntilExit()
        if reachedEOF.wait(timeout: .now() + 2) == .timedOut {
            pipe.fileHandleForReading.readabilityHandler = nil
            let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
            readerQueue.sync { consume(remainder, flush: true) }
        } else {
            pipe.fileHandleForReading.readabilityHandler = nil
            readerQueue.sync { }
        }
        let output = sanitized(String(decoding: completeData, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw Failure.text("命令执行失败（退出码 \(process.terminationStatus)）：\(executable.lastPathComponent)\n\(output)") }
        if show { log("✓ \(activityText)完成") }
        return output
    }

    private func taskID(from output: String) -> String? {
        let patterns = ["(?i)task\\s*id\\s*(?:is|[:=])\\s*([A-Za-z0-9_-]+)",
                        "(?i)taskID\\s*[:=]\\s*([A-Za-z0-9_-]+)"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            if let match = regex.firstMatch(in: output, range: range),
               let valueRange = Range(match.range(at: 1), in: output) {
                return String(output[valueRange])
            }
        }
        return nil
    }

    private func hardenedCandidate(in run: URL, excluding signed: URL) -> URL? {
        recursiveApks(run).first {
            $0.standardizedFileURL != signed.standardizedFileURL &&
            !$0.path.contains("/母包/") && !$0.path.contains("/渠道包/")
        }
    }

    private func requireFile(_ path: String, _ name: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL; var directory: ObjCBool = false
        guard !path.isEmpty, fm.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { throw Failure.text("\(name) 不存在：\(path)") }
        return url
    }
    private func requireDirectory(_ path: String, _ name: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL; var directory: ObjCBool = false
        guard !path.isEmpty, fm.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw Failure.text("\(name) 不存在：\(path)") }
        return url
    }
    private func newRun(_ output: String) throws -> URL {
        guard !output.isEmpty else { throw Failure.text("输出目录不能为空。") }
        let root = URL(fileURLWithPath: output).standardizedFileURL; try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; let stamp = formatter.string(from: Date())
        var url = root.appendingPathComponent(stamp); var suffix = 1
        while fm.fileExists(atPath: url.path) { url = root.appendingPathComponent("\(stamp)-\(suffix)"); suffix += 1 }
        try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func javaURL() throws -> URL {
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"] {
            let url = URL(fileURLWithPath: home).appendingPathComponent("bin/java")
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        let url = URL(fileURLWithPath: "/usr/bin/java")
        guard fm.isExecutableFile(atPath: url.path) else { throw Failure.text("没有检测到 Java。请安装 JDK，或配置 JAVA_HOME。") }
        return url
    }
    private func detectSDK() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let paths: [String?] = [env["ANDROID_SDK_ROOT"], env["ANDROID_HOME"],
                                fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path]
        return paths.compactMap { $0 }.first(where: { fm.fileExists(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
    private func bundledVasDolly() -> URL {
        Bundle.main.resourceURL?.appendingPathComponent("VasDolly.jar") ?? URL(fileURLWithPath: "VasDolly.jar")
    }
    private func isAppBundledVasDolly(_ path: String) -> Bool {
        path.contains(".app/Contents/Resources/") && URL(fileURLWithPath: path).lastPathComponent == "VasDolly.jar"
    }
    private func bundledApkProtect() -> URL {
        Bundle.main.resourceURL?.appendingPathComponent("apkprotect") ?? URL(fileURLWithPath: "apkprotect")
    }
    private func defaultChannels() -> URL {
        let destination = settingsFile.deletingLastPathComponent().appendingPathComponent("channels.txt")
        if !fm.fileExists(atPath: destination.path),
           let source = Bundle.main.resourceURL?.appendingPathComponent("channels.txt"),
           fm.fileExists(atPath: source.path) {
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: destination)
        }
        return destination
    }
    private func safeName(_ text: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\0").union(.controlCharacters)
        return text.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func recursiveApks(_ directory: URL) -> [URL] {
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL).flatMap { $0.pathExtension.lowercased() == "apk" ? $0 : nil } }
    }
    private func display(_ value: String) -> String {
        value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? value : "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func readValues() -> Values {
        func text(_ key: String) -> String { fields[key]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        return Values(sdk: text("sdk"), releaseApk: text("releaseApk"), hardenedApk: text("hardenedApk"),
                      keystore: text("keystore"), alias: text("alias"), vasDolly: text("vasDolly"), channels: text("channels"),
                      output: text("output"), storePassword: fields["storePassword"]?.stringValue ?? "",
                      keyPassword: fields["keyPassword"]?.stringValue ?? "", baiduAKey: fields["baiduAKey"]?.stringValue ?? "",
                      baiduSKey: fields["baiduSKey"]?.stringValue ?? "", hardenType: text("hardenType"),
                      baiduEnabled: providerPicker.titleOfSelectedItem == "百度",
                      hardeningProvider: providerPicker.titleOfSelectedItem ?? "不加固")
    }
    private func setBusy(_ busy: Bool) {
        if busy { window.makeFirstResponder(logView) }
        for field in fields.values { field.isEnabled = !busy }
        firstButton.isEnabled = !busy; packageButton.isEnabled = !busy
        completeButton.isEnabled = !busy; loginButton.isEnabled = !busy
        resumeButton.isEnabled = !busy
        providerPicker.isEnabled = !busy
        if busy { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    }
    private func logLevel(for message: String) -> LogLevel {
        let value = message.lowercased()
        if ["error", "failed", "failure", "exception", "错误", "失败"].contains(where: value.contains) { return .error }
        if ["warning", "warn", "警告"].contains(where: value.contains) { return .warning }
        return .info
    }
    private func logProcessLine(_ line: String) {
        let value = line.lowercased()
        if value.contains("stscredential:") {
            log("百度临时上传凭据已隐藏。")
            return
        }
        if value.contains("uploading file to server") || value.contains("upload file to server") {
            log("⏳ 正在上传 APK（loading）……")
        } else if value.contains("waiting for protection task") || value.contains("start protecting") {
            log("⏳ APK 已上传，百度云端正在加固（loading）……")
        } else if value.contains("start downloading protected apk") || value.contains("trying fetch") {
            log("⏳ 加固完成，正在下载加固 APK（loading）……")
        }
        log(line, level: logLevel(for: line))
    }
    private func log(_ message: String, level: LogLevel = .info) {
        DispatchQueue.main.async {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let visible = self.logView.enclosingScrollView?.contentView.documentVisibleRect ?? .zero
            let wasNearBottom = visible.maxY >= self.logView.bounds.height - 24
            let color: NSColor
            switch level {
            case .info: color = .labelColor
            case .warning: color = .systemYellow
            case .error: color = .systemRed
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ]
            self.logView.textStorage?.append(NSAttributedString(
                string: "[\(f.string(from: Date()))] \(message)\n", attributes: attributes))
            if wasNearBottom { self.logView.scrollToEndOfDocument(nil) }
        }
    }
    private func alert(_ title: String, _ message: String, _ style: NSAlert.Style) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = style
        alert.addButton(withTitle: "好"); alert.beginSheetModal(for: window)
    }
    private func projectIdentity() -> String? {
        let release = fields["releaseApk"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keystore = fields["keystore"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let alias = fields["alias"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !release.isEmpty, !keystore.isEmpty, !alias.isEmpty else { return nil }
        return [projectRoot(for: release), URL(fileURLWithPath: keystore).standardizedFileURL.path, alias]
            .joined(separator: "|")
    }
    private func projectRoot(for apkPath: String) -> String {
        var directory = URL(fileURLWithPath: apkPath).standardizedFileURL.deletingLastPathComponent()
        let markers = [".git", "settings.gradle", "settings.gradle.kts", "gradlew", "pubspec.yaml"]
        for _ in 0..<12 {
            if markers.contains(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                return directory.path
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return URL(fileURLWithPath: apkPath).standardizedFileURL.deletingLastPathComponent().path
    }
    private func projectConfigurationChanged() {
        let next = projectIdentity()
        activeCredentialProject = next
        let keystore = fields["keystore"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if keystore != activeKeystore {
            activeKeystore = keystore
            restoreSigningCredentials()
        }
        currentHardened = nil; currentRun = nil
        // Baidu credentials remain available when APK/Keystore selections change.
        restoreBaiduCredentials()
        saveCredentialsIfNeeded(readValues())
    }
    private func setSecret(_ key: String, _ value: String) {
        secretEditors[key]?.secure.stringValue = value
        secretEditors[key]?.plain.stringValue = value
        fields[key]?.stringValue = value
    }
    private func clearSecretFields() {
        ["baiduAKey", "baiduSKey", "storePassword", "keyPassword"].forEach { setSecret($0, "") }
    }
    private func credentials(from values: Values) -> SavedCredentials {
        SavedCredentials(baiduAKey: values.baiduAKey, baiduSKey: values.baiduSKey,
                         storePassword: values.storePassword, keyPassword: values.keyPassword)
    }
    private func saveCredentialsIfNeeded(_ values: Values) {
        guard !restoringCredentials else { return }
        if let file = signingCredentialsFile(activeKeystore) {
            do {
                try persist(SigningCredentials(alias: values.alias, storePassword: values.storePassword,
                                               keyPassword: values.keyPassword), to: file)
            } catch { log("保存 Keystore 凭据失败：\(error.localizedDescription)", level: .warning) }
        }
        guard let file = credentialsFile() else { return }
        let credentials = credentials(from: values)
        do {
            try persist(credentials, to: file)
            activeCredentialProject = projectIdentity()
        } catch {
            log("保存项目凭据失败：\(error.localizedDescription)", level: .warning)
        }
    }
    private func restoreCredentials(savedProject: String?) {
        let project = projectIdentity(); activeCredentialProject = project
        activeKeystore = fields["keystore"]?.stringValue ?? ""
        restoreBaiduCredentials()
        let signingFile = signingCredentialsFile(activeKeystore)
        if let signingFile, fm.fileExists(atPath: signingFile.path) {
            restoreSigningCredentials()
            return
        }
        // Migrate the previous project-bound passwords only for the same Keystore.
        let savedKeystore = savedProject?.components(separatedBy: "|").dropFirst().first
        guard !activeKeystore.isEmpty, savedKeystore == activeKeystore else {
            restoreSigningCredentials(); return
        }
        do {
            guard let file = credentialsFile(), fm.fileExists(atPath: file.path) else { restoreSigningCredentials(); return }
            let data = try Data(contentsOf: file)
            let credentials = try JSONDecoder().decode(SavedCredentials.self, from: data)
            setSecret("storePassword", credentials.storePassword); setSecret("keyPassword", credentials.keyPassword)
            saveCredentialsIfNeeded(readValues())
            log("已将旧版签名凭据迁移为按 Keystore 保存。")
        } catch {
            restoreSigningCredentials()
            log("读取当前项目凭据失败：\(error.localizedDescription)", level: .warning)
        }
    }
    private func persist<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        if let old = try? Data(contentsOf: file), old == data { return }
        let directory = file.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try "*\n!.gitignore\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func signingCredentialsFile(_ keystore: String) -> URL? {
        guard !keystore.isEmpty else { return nil }
        let key = URL(fileURLWithPath: keystore).standardizedFileURL
        return key.deletingLastPathComponent().appendingPathComponent(".android-release-tool")
            .appendingPathComponent(key.lastPathComponent + ".signing.json")
    }
    private func restoreSigningCredentials() {
        restoringCredentials = true; defer { restoringCredentials = false }
        fields["alias"]?.stringValue = ""
        setSecret("storePassword", ""); setSecret("keyPassword", "")
        guard let file = signingCredentialsFile(activeKeystore), fm.fileExists(atPath: file.path) else { return }
        do {
            let saved = try JSONDecoder().decode(SigningCredentials.self, from: Data(contentsOf: file))
            fields["alias"]?.stringValue = saved.alias
            setSecret("storePassword", saved.storePassword); setSecret("keyPassword", saved.keyPassword)
            log("已从本地恢复所选 Keystore 的 Alias 和密码。")
        } catch { log("读取 Keystore 凭据失败：\(error.localizedDescription)", level: .warning) }
    }
    private func restoreBaiduCredentials() {
        guard let file = credentialsFile(), let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(SavedCredentials.self, from: data) else { return }
        setSecret("baiduAKey", saved.baiduAKey); setSecret("baiduSKey", saved.baiduSKey)
    }
    private func credentialsFile() -> URL? {
        let release = fields["releaseApk"]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: URL
        if !release.isEmpty { base = URL(fileURLWithPath: projectRoot(for: release), isDirectory: true) }
        else if !activeKeystore.isEmpty { base = URL(fileURLWithPath: activeKeystore).deletingLastPathComponent() }
        else { base = settingsFile.deletingLastPathComponent() }
        return base
            .appendingPathComponent(".android-release-tool", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }
    private func saveSettings() {
        let v = readValues()
        let persistedVasDolly = isAppBundledVasDolly(v.vasDolly) ? "" : v.vasDolly
        let settings = Settings(sdk: v.sdk, releaseApk: v.releaseApk, hardenedApk: v.hardenedApk,
            keystore: v.keystore, alias: v.alias, vasDolly: persistedVasDolly, channels: v.channels, output: v.output,
            credentialProject: activeCredentialProject ?? projectIdentity(), baiduEnabled: v.baiduEnabled,
            hardeningProvider: v.hardeningProvider)
        do {
            try fm.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsFile, options: .atomic)
        } catch { log("保存设置失败：\(error.localizedDescription)", level: .warning) }
    }
    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsFile), let s = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        ["sdk": s.sdk, "releaseApk": s.releaseApk, "hardenedApk": s.hardenedApk, "keystore": s.keystore,
         "alias": s.alias, "channels": s.channels, "output": s.output]
            .forEach { if !$0.value.isEmpty { fields[$0.key]?.stringValue = $0.value } }
        if !s.vasDolly.isEmpty, !isAppBundledVasDolly(s.vasDolly), fm.fileExists(atPath: s.vasDolly) {
            fields["vasDolly"]?.stringValue = s.vasDolly
        } else {
            fields["vasDolly"]?.stringValue = bundledVasDolly().path
            if !s.vasDolly.isEmpty {
                log("旧的 VasDolly 临时路径已失效，已自动切换到当前 App 内置版本。", level: .warning)
            }
        }
        restoreCredentials(savedProject: s.credentialProject)
        let provider = s.hardeningProvider ?? ((s.baiduEnabled ?? true) ? "百度" : "不加固")
        providerPicker.selectItem(withTitle: ["不加固", "百度", "梆梆"].contains(provider) ? provider : "不加固")
        hardeningChanged()
    }
}

@main
enum AutoAppHPDMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
