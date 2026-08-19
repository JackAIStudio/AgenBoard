# AgenBoard

[![Build](https://github.com/JackAIStudio/AgenBoard/actions/workflows/build.yml/badge.svg)](https://github.com/JackAIStudio/AgenBoard/actions/workflows/build.yml)

一个开源的 iPhone AI 语音输入键盘。在支持第三方键盘的 App 中点击麦克风，使用 Apple 系统识别或火山引擎豆包流式语音识别模型 2.0 转写语音，并将结果自动回填到当前输入框。

> [!IMPORTANT]
> AgenBoard 当前只发布源代码，不提供已签名 App 或 App Store 版本。部分跨 App 唤起、宿主识别和自动返回能力依赖非公开 iOS API，可能随系统更新失效，也可能不符合 App Store 审核要求。

## 核心能力

- **语音输入闭环**：从键盘启动和结束录音，识别完成后自动回填文字。
- **两种日常识别方案**：支持 Apple Speech，以及 JackVoice 同款豆包双向流式优化版；录音时实时上屏，停止后使用二遍识别结果生成终稿。
- **热词增强**：按置顶、启用状态和最近命中时间，从词库中最多激活 100 个热词。
- **完整拼音键盘**：内置 librime 与雾凇拼音，支持候选分页、用户词频学习、拼音联想表情、英文、数字、符号和光标拖动。
- **快捷短语**：在主 App 中管理常用短语，并通过键盘快速输入。
- **数据自主可控**：识别历史、热词、短语、设置和拼音学习数据可导出为开放 ZIP，也可智能合并或完全替换导入；录音和 API Key 仅在用户明确选择时导出。

## 工作原理

受 iOS 键盘扩展限制，录音和语音识别由主 App 完成：

1. 键盘扩展通过 App Group 向主 App 发送录音指令。
2. 主 App 使用画中画维持后台录音；冷启动时会短暂打开 AgenBoard，再尝试返回原 App。
3. 主 App 按当前方案使用 Apple Speech，或在录音期间通过豆包双向流式接口实时转写，再将结果同步回键盘。
4. 键盘确认结果属于本次请求后，将文字写入当前输入框。

因此，语音状态、识别结果和设置同步需要开启键盘的“允许完全访问”。键盘扩展本身不发起网络请求。

## 数据边界与隐私

> [!IMPORTANT]
> AgenBoard 项目维护者不运营后端服务器、账号系统、录音中转或云存储服务。正常使用 AgenBoard 时，项目维护者不会收到、保存或查看你的录音、转写文本、热词或豆包语音 API Key。只有你主动在 Issue、邮件或其他反馈渠道提交内容时，接收方才会看到你提交的信息。

- 每次录音及其识别历史默认保存在当前设备；在 App 中删除对应历史时，本地录音也会被删除。
- 使用 Apple 识别时，录音交由系统语音能力处理：iOS 26 使用设备端 SpeechAnalyzer；iOS 17–25 是否连接 Apple 服务由系统和设备能力决定。
- 使用豆包流式语音识别时，主 App 使用你的 API Key，通过 WebSocket 将 16 kHz 单声道 PCM 和请求级热词直接发送到火山引擎。历史重转写也按录音时长使用同一条流式链路，不上传临时文件；所有请求都不经过项目维护者控制的服务器。
- 开源使上述实现可以被审查，但真正的数据边界来自当前代码中的网络路径和存储设计。本说明适用于本仓库当前源代码；第三方修改或重新分发的版本可能采用不同的数据处理方式。

完整说明及删除、导入和导出规则见 [PRIVACY.md](PRIVACY.md)。

## 识别服务

| 用途 | 方案 | 处理方式 | 第三方云端存储 |
| --- | --- | --- | --- |
| 日常录音 | Apple 系统识别 | iOS 26 使用设备端 SpeechAnalyzer；iOS 17–25 使用 Apple Speech 兼容路径 | iOS 26 不需要；iOS 17–25 联网由 Apple 系统决定 |
| 日常录音 | 豆包流式语音识别模型 2.0 | 录音时通过双向 WebSocket 发送 PCM；实时显示一遍结果，停止后接收二遍终稿 | 不使用临时文件 URL；音频流直接发送给火山引擎处理 |
| 识别历史 | 豆包流式语音识别模型 2.0 | 用户主动选择后，按录音时长重新推入同一条流式链路 | 不上传完整文件或创建临时云端文件 |

豆包实时识别和历史重转写都使用用户自己的火山引擎 API Key 与资源 ID，均不经过项目维护者的服务器。旧版阿里云 provider 值只用于兼容已有历史和导出包，不再作为可调用服务。

### 配置豆包流式语音识别模型 2.0

AgenBoard 使用与 JackVoice 相同的双向流式优化版端点：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`。默认资源 ID 为 `volc.seedasr.sauc.duration`（小时版）。

1. 打开[火山引擎语音控制台](https://console.volcengine.com/speech/new/)，开通豆包流式语音识别模型 2.0。
2. 创建或复制可用于该服务的 API Key。
3. 返回 AgenBoard 的“识别服务”页面粘贴 API Key。
4. 保持默认资源 ID；只有控制台明确提供其他值时才修改。
5. 点击“保存豆包语音配置”，然后点击“测试连接”。

选择豆包实时版后，还可以选择断句方式：默认“自然听写”不按停顿强制判停，只在停止录音后请求二遍终稿；“低延迟”向服务端传入 1300 ms 停顿判停参数，适合短句和即时交互。两种模式都会在停止时发送协议负包，并等待非流式二遍结果稳定后收尾。

> [!IMPORTANT]
> 不要把 API Key 写入源代码、项目配置、Issue、日志或提交到 Git。AgenBoard 默认只将它保存在本机钥匙串。

豆包语音 API Key 在日常配置中只保存在本机钥匙串；仅当用户在数据导出页明确选择时，才会与资源 ID 一起写入导出包。请求级热词会按火山接口规则去除空格和标点，单词最长 32 字符，单次累计最多 100 字符；超出限制的词会在结果信息中提示。

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

仓库包含维护者的公开默认 Team 标识，仅作为开箱即用的构建基线；它不包含签名证书或私钥。模拟器构建不需要 Apple Developer 账号，也无需修改签名配置。

如需安装到真机，请在 Xcode 的 **Signing & Capabilities** 中，分别为 `AgenBoard` 和 `AgenBoardKeyboard` 两个 target 选择同一个自己的 Team。target 级设置会覆盖仓库默认值，项目会自动派生属于该 Team 的 Bundle ID 和 App Group，无需手动修改标识符。

长期参与开发且希望避免 Xcode 将个人 Team 写入 `project.pbxproj` 时，可以选择将 `Config/Local.xcconfig.example` 复制为被 Git 忽略的 `Config/Local.xcconfig` 并填写自己的 Team ID；这是可选优化，不是构建前置步骤。

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
