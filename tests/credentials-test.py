"""Exercise production credential handlers with temporary projects and dummy secrets only."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
harness = r'''
extension AppDelegate {
    static func credentialRegression(_ root: URL) throws {
        func make() -> AppDelegate {
            let app = AppDelegate()
            app.settingsFile = root.appendingPathComponent("settings.json")
            for key in ["sdk", "releaseApk", "hardenedApk", "keystore", "alias", "vasDolly", "channels", "output", "storePassword", "keyPassword", "baiduAKey", "baiduSKey", "hardenType"] {
                app.fields[key] = NSTextField()
            }
            app.providerPicker = NSPopUpButton()
            app.providerPicker.addItems(withTitles: ["不加固", "百度", "梆梆"])
            app.fields["releaseApk"]!.stringValue = root.appendingPathComponent("input.apk").path
            return app
        }
        let app = make()
        let a = root.appendingPathComponent("a.jks").path, b = root.appendingPathComponent("b.jks").path
        app.fields["keystore"]!.stringValue = a
        app.projectConfigurationChanged()
        func edit(_ key: String, _ value: String) {
            app.fields[key]!.stringValue = value
            app.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: app.fields[key]!))
        }
        edit("alias", "alias-a"); edit("storePassword", "dummy-store-a"); edit("keyPassword", "dummy-key-a")
        edit("baiduAKey", "dummy-ak"); edit("baiduSKey", "dummy-sk")
        edit("alias", "alias-a-updated")
        precondition(app.fields["storePassword"]!.stringValue == "dummy-store-a")
        app.fields["keystore"]!.stringValue = b; app.projectConfigurationChanged()
        precondition(app.fields["alias"]!.stringValue.isEmpty && app.fields["storePassword"]!.stringValue.isEmpty)
        edit("alias", "alias-b"); edit("storePassword", "dummy-store-b"); edit("keyPassword", "dummy-key-b")
        app.fields["keystore"]!.stringValue = a; app.projectConfigurationChanged()
        precondition(app.fields["alias"]!.stringValue == "alias-a-updated")
        precondition(app.fields["storePassword"]!.stringValue == "dummy-store-a")
        precondition(app.fields["keyPassword"]!.stringValue == "dummy-key-a")
        edit("storePassword", "dummy-replaced"); edit("baiduAKey", "dummy-ak-replaced")
        let reopened = make(); reopened.fields["keystore"]!.stringValue = a
        reopened.restoreCredentials(savedProject: nil)
        precondition(reopened.fields["storePassword"]!.stringValue == "dummy-replaced")
        precondition(reopened.fields["alias"]!.stringValue == "alias-a-updated")
        precondition(reopened.fields["baiduAKey"]!.stringValue == "dummy-ak-replaced")
        precondition(reopened.fields["baiduSKey"]!.stringValue == "dummy-sk")
        let file = app.signingCredentialsFile(a)!
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        // Old combined credentials migrate only for the matching Keystore.
        let legacy = make(); let c = root.appendingPathComponent("c.jks").path
        legacy.fields["keystore"]!.stringValue = c; legacy.fields["alias"]!.stringValue = "legacy-alias"
        legacy.restoreCredentials(savedProject: root.path + "|" + c + "|legacy-alias")
        precondition(legacy.fields["alias"]!.stringValue == "legacy-alias")
        precondition(legacy.fields["storePassword"]!.stringValue == "dummy-replaced")
        print("PASS: immediate save, overwrite, Keystore isolation, alias editing, reopen restore, Baidu restore, legacy migration, permissions")
    }
}
@main enum CredentialRegression {
    static func main() throws {
        _ = NSApplication.shared
        try AppDelegate.credentialRegression(URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
'''
with tempfile.TemporaryDirectory(prefix="art-credentials-test-") as tmp:
    tmp = pathlib.Path(tmp)
    source = tmp / "Regression.swift"
    source.write_text((root / "AutoAppHPD.swift").read_text().split("@main\nenum AutoAppHPDMain")[0] + harness)
    binary = tmp / "regression"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", "/tmp/ARTRegressionModuleCache", "-framework", "AppKit", "-framework", "WebKit", str(source), str(root / "BangcleService.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(tmp)], check=True, timeout=30)
