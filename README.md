# AgenBoard

[![Build](https://github.com/JackAIStudio/AgenBoard/actions/workflows/build.yml/badge.svg)](https://github.com/JackAIStudio/AgenBoard/actions/workflows/build.yml)

一个开源的 iPhone AI 语音输入键盘。在支持第三方键盘的 App 中点击麦克风，使用 Apple 系统识别或阿里云 Fun-ASR 转写语音，并将结果自动回填到当前输入框。

> [!IMPORTANT]
> AgenBoard 当前只发布源代码，不提供已签名 App 或 App Store 版本。部分跨 App 唤起、宿主识别和自动返回能力依赖非公开 iOS API，可能随系统更新失效，也可能不符合 App Store 审核要求。

## 核心能力

- **语音输入闭环**：从键盘启动和结束录音，识别完成后自动回填文字。
- **双识别服务**：支持 Apple Speech，以及用户自带 API Key 的阿里云 Fun-ASR。
- **热词增强**：按置顶、启用状态和最近命中时间，从词库中最多激活 100 个热词。
- **完整拼音键盘**：内置 librime 与雾凇拼音，支持候选分页、用户词频学习、英文、数字、符号和光标拖动。
- **快捷短语**：在主 App 中管理常用短语，并通过键盘快速输入。
- **数据自主可控**：识别历史、热词、短语、设置和拼音学习数据可导出为开放 ZIP，也可智能合并或完全替换导入；录音和 API Key 仅在用户明确选择时导出。

## 工作原理

受 iOS 键盘扩展限制，录音和语音识别由主 App 完成：

1. 键盘扩展通过 App Group 向主 App 发送录音指令。
2. 主 App 使用画中画维持后台录音；冷启动时会短暂打开 AgenBoard，再尝试返回原 App。
3. 录音结束后，主 App 调用当前识别服务，并将结果同步回键盘。
4. 键盘确认结果属于本次请求后，将文字写入当前输入框。

因此，语音状态、识别结果和设置同步需要开启键盘的“允许完全访问”。键盘扩展本身不发起网络请求。

## 数据边界与隐私

> [!IMPORTANT]
> AgenBoard 项目维护者不运营后端服务器、账号系统、录音中转或云存储服务。正常使用 AgenBoard 时，项目维护者不会收到、保存或查看你的录音、转写文本、热词或阿里云 API Key。只有你主动在 Issue、邮件或其他反馈渠道提交内容时，接收方才会看到你提交的信息。

- 每次录音及其识别历史默认保存在当前设备；在 App 中删除对应历史时，本地录音也会被删除。
- 使用 Apple 识别时，录音交由系统语音能力处理：iOS 26 使用设备端 SpeechAnalyzer；iOS 17–25 是否连接 Apple 服务由系统和设备能力决定。
- 使用阿里云 Fun-ASR 时，主 App 使用你的 API Key 将录音和已启用热词直接发送到阿里云百炼，不经过项目维护者控制的服务器。录音进入百炼托管的私有临时存储，并在 48 小时后自动清理；无需另行开通 OSS。
- 开源使上述实现可以被审查，但真正的数据边界来自当前代码中的网络路径和存储设计。本说明适用于本仓库当前源代码；第三方修改或重新分发的版本可能采用不同的数据处理方式。

完整说明及删除、导入和导出规则见 [PRIVACY.md](PRIVACY.md)。

## 识别服务

| | Apple 系统识别 | 阿里云 Fun-ASR |
| --- | --- | --- |
| 适合场景 | 日常聊天、随手记录、快速回填 | 中文长录音、专业词和准确度优先场景 |
| 处理方式 | iOS 26 使用设备端 SpeechAnalyzer；iOS 17–25 使用 Apple Speech 兼容路径 | 主 App 上传整段录音并提交云端异步识别 |
| 配置 | 无需第三方 API Key | 使用用户自己的华北 2（北京）百炼 API Key |
| 数据去向 | iOS 26 在设备端处理；iOS 17–25 可能由 Apple 服务处理；均不经过项目维护者的服务器 | 录音和启用的热词由主 App 直接发送至阿里云百炼，不经过项目维护者的服务器 |
| 项目方服务器与存储 | 不使用 | 不使用 |
| 第三方云端存储 | iOS 26 不需要；iOS 17–25 联网由 Apple 系统决定 | 使用百炼托管的私有临时存储，48 小时后自动清理，无需另开 OSS |

### 配置阿里云 Fun-ASR

AgenBoard 当前版本固定连接阿里云百炼华北 2（北京）地域，因此必须使用在该地域创建的 API Key，其他地域的 Key 不能混用。

1. 打开[阿里云百炼 API Key 页面](https://bailian.console.aliyun.com/cn-beijing?tab=model#/api-key)。
2. 确认页面右上角地域为“华北 2（北京）”。
3. 点击“创建 API Key”，建议选择默认业务空间。
4. 创建后立即复制 Key，返回 AgenBoard 的“识别服务”页面粘贴。
5. 点击“保存阿里云配置”，然后点击“测试连接”。

> [!IMPORTANT]
> 新创建的 API Key 明文只显示一次，请立即妥善保存。不要把 API Key 写入源代码、配置文件、Issue、日志或提交到 Git。

更多信息请参阅阿里云官方的[获取 API Key 教程](https://help.aliyun.com/zh/model-studio/get-api-key)和[地域与接入域名说明](https://help.aliyun.com/zh/model-studio/regions/)。

阿里云 API Key 在日常配置中只保存在本机钥匙串；仅当用户在数据导出页明确选择时，才会写入导出包。当前链路使用百炼提供的临时存储，用户不需要创建 OSS Bucket；阿里云明确不建议将该临时存储用于生产、高并发或压测场景，相关限制见[上传本地文件获取临时 URL](https://help.aliyun.com/zh/model-studio/get-temporary-file-url/)。

## 构建

### 环境要求

- macOS 与 Xcode 26.4 或更高版本
- Apple Silicon Mac
- iOS 17.0 或更高版本

克隆仓库后，先下载并校验锁定版本的预编译 Rime 数据：

```sh
./scripts/fetch-rime-data.sh
```

构建无需签名的模拟器版本：

```sh
xcodebuild \
  -project AgenBoard.xcodeproj \
  -scheme AgenBoard \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

如需安装到真机，请在 Xcode 的 **Signing & Capabilities** 中，分别为 `AgenBoard` 和 `AgenBoardKeyboard` 两个 target 选择自己的 Team。项目会自动派生对应的 Bundle ID 和 App Group。

## 启用键盘

真机安装后：

1. 打开 AgenBoard，按照首次使用向导完成权限和识别服务设置。
2. 前往 **设置 → 通用 → 键盘 → 键盘 → 添加新键盘**，选择 **AgenBoard**。
3. 再次进入 AgenBoard 键盘设置并开启 **允许完全访问**。
4. 在任意支持第三方键盘的输入框中，通过系统地球键切换到 AgenBoard。

## 文档与贡献

- [贡献指南](CONTRIBUTING.md)
- [隐私说明](PRIVACY.md)
- [安全政策](SECURITY.md)
- [第三方软件与数据声明](THIRD_PARTY_NOTICES.md)
- [Rime 数据与维护说明](AgenBoardKeyboard/RimeData/README.md)

欢迎通过 Issue 报告问题或提出建议。提交代码前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；安全问题请按 [SECURITY.md](SECURITY.md) 私密报告。

## 许可证

AgenBoard 以 [GPL-3.0-only](LICENSE) 开源。第三方代码、库和词典仍适用其各自许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [LICENSES](LICENSES/)。
