# Mini 用量条

一个使用 Swift 和 AppKit 编写的 macOS 菜单栏小工具，用于查看 Codex 的剩余用量。此项目为非官方工具，与 OpenAI 无隶属关系。

## 功能

- 在菜单栏显示 5 小时（`5h`）和每周（`1w`）的剩余百分比。
- 剩余百分比按 `100% − 已用百分比` 计算，例如已用 20% 时显示 80%。
- 点击菜单栏图标查看剩余用量和重置时间。
- 每 60 秒自动刷新，也可在菜单中选择“立即刷新”。
- 通过菜单中的“退出”关闭应用。

## 运行要求

- macOS 14.0 或更高版本（当前构建的最低版本）。
- 可用于目标 macOS 版本的 Xcode 和 macOS SDK，项目使用 Swift 5 语言模式。
- 本机安装可用的 Codex 命令行组件，并完成登录。程序也会尝试查找 ChatGPT/Codex 应用内附带的组件，具体可用性取决于所安装的版本。
- 当前账号的用量响应需要同时包含短周期和每周用量数据。

## 构建与运行

1. 下载源码，用 Xcode 打开 `MiniUsageBar.xcodeproj`。
2. 选择 **MiniUsageBar > My Mac**。
3. 在目标的 **Signing & Capabilities** 中选择自己的开发团队；如有需要，将 Bundle Identifier 改为自己的唯一标识符。
4. 点击运行，菜单栏中会出现用量图标。

构建产物输出到项目根目录的 `.build/`，该目录已由 `.gitignore` 排除。项目当前使用自动签名和 `Apple Development` 签名身份，并已开启 Hardened Runtime；这些开发配置不代表应用已经完成分发签名或公证。

目标的最低系统版本使用 `$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)`，当前环境解析为 macOS 14.0；`Info.plist` 的 `LSMinimumSystemVersion` 跟随该部署目标。升级 Xcode 后推荐值可能变化，请在构建前确认目标的 **macOS Deployment Target**。

## 数据与隐私

程序启动本机的 `codex app-server`，通过标准输入和输出调用 `account/rateLimits/read` 获取用量，使用的是运行者本机的登录状态。

源码不需要填写 API Key，也不包含开发者的账号、密码或登录令牌。应用代码没有实现自建服务器上传或遥测；Codex 组件自身可能连接其服务获取账号数据。

请勿提交登录凭据、环境文件、签名私钥或包含敏感信息的日志。`.gitignore` 已排除常见本地环境文件、签名文件、构建产物和 Xcode 个人配置，但无法代替发布前的人工检查，也不会移除已经被 Git 跟踪的文件。

## 已知限制

- 依赖本机 Codex 的可执行文件位置和接口响应格式，相关组件更新后可能需要适配。
- 当前按 5 小时和每周标注两个周期；若服务返回其他周期，界面标签需要相应调整。
- 程序会从本机应用目录和常见安装路径查找 Codex，目前仅检查文件是否可执行，未验证其签名。请确保使用可信来源安装的组件。
- 用量刷新失败时显示错误信息；重置时间按系统本地时区显示。

如果提示找不到组件，请确认已安装 Codex 命令行组件；如果读取失败，请确认该组件的登录状态、网络连接和账号用量接口是否可用。

## 自定义

主要代码位于 `MiniUsageBar/main.swift`：

- 字体大小：搜索 `monospacedDigitSystemFont(ofSize: 9`。
- 两行间距和垂直位置：调整 `MenuBarMeter.render` 中两行文字的绘制坐标。
- 状态栏宽度：检查 `statusItem(withLength: 72)` 和 `MenuBarMeter.render` 中的图片尺寸。
- 自动刷新间隔：搜索 `withTimeInterval: 60`，菜单栏逻辑位于 `AppDelegate` 中。
- 菜单栏图标：替换 `MiniUsageBar/MenuBarKnot.png`，建议使用透明背景。图片按模板图像显示，颜色由系统外观和选中状态决定。

## 开发者

[Carl Zhang](https://github.com/carlzhang123)

也可从应用菜单中的“关于 Mini 用量条”查看开发者信息和 GitHub 链接。

## 许可与素材

本项目源码采用 GNU Affero General Public License v3.0（AGPL-3.0-only）许可，完整条款见 [LICENSE](LICENSE)。

第三方商标和图标的权利归各自权利人所有，不因本项目的源码许可证而获得额外授权。
