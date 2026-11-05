# AutoAppHPD（macOS）

Android APK 签名、百度 / 梆梆加固、对齐、重签和渠道包生成工具。

[下载安装包](https://github.com/rayvux/AutoAppHPD/releases/latest) · [源码仓库](https://github.com/rayvux/AutoAppHPD)

安装包名称为 `AutoAppHPD.dmg` 和 `AutoAppHPD.pkg`，支持 Apple Silicon / Intel，最低 macOS 12。
目前使用本地 ad hoc 签名，未经过 Apple Developer ID 签名和公证。

一个可复制到任意目录、供多个 Android 项目共用的 macOS 原生 GUI 发布工具。

## 能做什么

- 选择已经构建好的 Release APK，加固方式可选“不加固 / 百度 / 梆梆”。
- 自动把加固产物交给第二步，也可手动选择已有加固 APK 作为兜底。
- 自动执行 `zipalign`。
- 使用 Android SDK 的 `apksigner` 重新签名并校验。
- 调用 `VasDolly.jar` 批量生成渠道包。
- 为所有 APK 生成 `SHA256SUMS.txt`。
- 自动记住路径配置；百度 AKEY、SKEY 输入后自动保存，修改后覆盖，选择百度时自动恢复。
- 按 Keystore 分别保存 Key Alias、Store 密码和 Key 密码，切换 Keystore 自动填充。
- 选择百度或梆梆时显示“一键签名、加固、对齐、重签并生成渠道包”按钮。

工具内置原生百度接口客户端，主程序和客户端均为 arm64 / x86_64 通用二进制，无需 Rosetta。
第一步会先签名，再上传百度加固并下载产物；
第二步直接对加固产物执行对齐、重签和渠道包生成。日志中的错误显示为红色，警告显示为黄色。
所有等待中的命令都会持续输出 `loading` 和已等待时间；上传、云端加固、下载会显示各自阶段。
如果百度任务超时返回 taskID，工具会自动继续查询并把产物下载到本次任务的“加固后”目录。

## 使用

1. App 已内置 `VasDolly.jar`，也可以在界面里选择其他版本。
   内置版本始终从当前 App 读取，不会保存 DMG 的临时 `/Volumes/...` 路径。
2. 首次运行会把默认渠道文件复制到
   `~/Library/Application Support/AndroidReleaseTool/channels.txt`，每行一个渠道。
3. 打开 `AutoAppHPD.dmg`，双击“安装并更新.pkg”，安装程序会覆盖 `/Applications/AutoAppHPD.app`。
   安装前退出正在运行的旧版本。也可以将 App 拖到“应用程序”并选择替换。
   首次从旧版 Android Release Tool 升级，请先退出旧软件；安装程序会清理同一工具的旧名称 App，保留本地配置、凭据和任务断点。
   `AutoAppHPD.command` 仅用于源码调试，会在隐藏的 `.build` 目录生成 App。
   如果 macOS 阻止首次打开，请在 Finder 中右键该文件并选择“打开”。
4. 选择已经构建好的 Release APK 和 keystore。
5. 填写百度加固控制台提供的 AKEY、SKEY，默认加固类型为 `free`。
6. 选择加固方式，再点击第一步。选择“不加固”时只签名，不上传 APK。
   选择“百度”时使用 AKEY/SKEY；选择“梆梆”时首次在软件弹出的官方网页登录，
   后续会话有效时自动继续上传、提交本次新任务、等待和下载。梆梆密码由官方页面处理，软件不读取。
   加固方式会自动保存，并兼容旧版的百度勾选设置。
   首次使用可先点击“梆梆登录”单独验证会话；该按钮不会上传、提交加固或下载线上应用。
   软件通过官方只读接口确认登录，不依赖登录后跳转到某个固定页面。
7. 点击“2. 对齐、重签并生成渠道包”。
   也可在选择加固方式后点击完整流程按钮：等待加固包下载完成，自动更新“Release APK（已加固）”路径，
   然后继续对齐、重签并生成渠道包。选择“不加固”时隐藏此按钮，保留原来的两步按钮。

配置保存在 `~/Library/Application Support/AndroidReleaseTool/settings.json`。整个工具
目录可以复制到其他磁盘或其他电脑使用，不依赖当前项目。四项凭据不会写入全局设置或钥匙串，
而是保存在项目根目录的 `.android-release-tool/credentials.json`，文件权限为仅当前用户可读写。
签名凭据另外保存在 Keystore 所在目录的 `.android-release-tool/<Keystore文件名>.signing.json`，
同目录下的不同 Keystore 分别保存。首次更新会自动迁移当前 Keystore 的旧凭据。
工具会同时生成 `.gitignore`，防止凭据文件被提交到 Git。
选择保存过的 Keystore 自动恢复三项签名凭据，新的 Keystore 显示空值；修改 Alias 不会清空密码。
每个凭据输入框右侧均可点击“显示/隐藏”切换明文。
卸载前可点击“清除本地凭据”删除当前项目保存的信息。

梆梆加固结果会下载到本次任务的“加固后”目录，通过 APK 完整性校验后才交给第二步。
任务 ID 保存在该目录的“梆梆任务ID.txt”；等待超时不会取消线上任务。
软件只对本次新上传的应用提交加固，不会删除、覆盖或重新加固线上已有应用。
梆梆登录会话与 Codex 内置浏览器相互独立，更新软件不会自动导入内置浏览器的登录信息。
上传返回任务 ID 后立即保存断点，提交前、提交成功后和下载完成后分别更新。
登录失效会自动打开官方登录窗口，验证成功后先查询原任务：已完成则下载，处理中则继续等待，
只有服务器明确显示尚未提交时才补交加固。状态不明确或加固失败时暂停，不自动重传或重新加固。
关闭登录窗口会保留断点，之后点击“梆梆登录”或“续接梆梆任务”可继续；重启软件也能恢复。
断点保存在本次“加固后/梆梆任务断点.json”和本地设置目录，不包含密码或会话 Cookie。
梆梆上传进度每 30 秒更新，提交成功后加固状态每 3 分钟查询，查询到成功即下载；下载进度每 15 秒更新。
传输开始、完成、登录失效等状态会立即显示，不受进度间隔限制。
下载断线会显示具体网络错误码并自动重试（最多 6 次），每次重新获取原任务的下载凭证。
数据流式写入目标 APK 同目录的 `.apk.part` 文件；服务器支持 Range 时断点续传，登录或重启后仍保留。
服务器忽略 Range 时会安全清空该任务的部分文件并重新下载，防止错误拼接。完整下载通过 ZIP 和 Manifest 校验后才更新界面、进入第二步。

## 输出结构与命名

假设输入 APK 名为 `demo-app_release_1.0.0.apk`：

```text
时间戳目录/
├─ 待加固/
│  └─ demo-app-1.0.0_signed.apk
├─ 加固后/
│  └─ demo-app-1.0.0_hardened.apk
├─ 母包/
│  └─ demo-app-base-1.0.0_final.apk
├─ 渠道包/
│  ├─ demo-app-yyb-1.0.0_final.apk
│  └─ demo-app-huawei-1.0.0_final.apk
└─ SHA256SUMS.txt
```

zipalign 中间文件放在系统临时目录并在完成后删除；V4 `.idsig` 已关闭，不会再
混入最终发布目录。

## 环境要求

- macOS 12 或更高版本
- 使用已打包 App 无需 Xcode；从源码重新构建时需要 Xcode Command Line Tools
- JDK 11 或更高版本
- Android SDK Build Tools（包含 `aapt`、`zipalign`、`apksigner`）
- 项目自身可正常执行的 Gradle/JDK 环境

工具会依次尝试 `ANDROID_SDK_ROOT`、`ANDROID_HOME` 和
`~/Library/Android/sdk`；Finder 启动拿不到终端环境变量时，也可在界面中手动选择 SDK。
需要重新打包时运行 `build-dmg.command`。输出文件始终为 `AutoAppHPD.dmg` 和 `AutoAppHPD.pkg`，
每次打包直接覆盖，不再按版本号生成多个 DMG。

为兼容旧版升级，Bundle ID 和 `~/Library/Application Support/AndroidReleaseTool/` 本地数据路径保持不变。

## 源码构建与测试

```sh
git clone https://github.com/rayvux/AutoAppHPD.git
cd AutoAppHPD
./AutoAppHPD.command --build-only
./build-dmg.command
python3 tests/credentials-test.py
xcrun swiftc -parse-as-library -framework AppKit -framework WebKit \
  BangcleService.swift tests/BangcleClientTest.swift -o /tmp/autoapphpd-bangcle-test
python3 tests/bangcle-client-test.py /tmp/autoapphpd-bangcle-test
python3 tests/native-client-test.py .build/AutoAppHPD.app/Contents/Resources/apkprotect
```

这些协议测试仅使用本机模拟服务和虚拟凭据，不上传用户 APK 或操作真实加固任务。

## 发布与隐私

源码与通用资源提交到主分支，发布安装包放在 `dist/`，通过版本标签自动创建 GitHub Release。
`dist/SHA256SUMS.txt` 用于校验下载文件。发布说明中的实测范围不代表第三方服务始终可用。

本地密码和密钥不是软件的内置数据，发布时禁止上传：

- `.android-release-tool/`、`credentials.json`、`*.signing.json`、用户设置和 `.env`。
- Keystore / 证书 / 私钥、用户 APK、加固产物、任务断点、日志和下载中的 `.part` 文件。
- `.build/`、已安装 App 的运行数据、WebKit 登录 Cookie、系统钥匙串内容。

测试中的 `dummy-*`、`test-only` 等字符串是虚拟测试数据。第三方组件说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
