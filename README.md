# AgenBoard

[![Build](https://github.com/JackAIStudio/AgenBoard/actions/workflows/build.yml/badge.svg)](https://github.com/JackAIStudio/AgenBoard/actions/workflows/build.yml)

iPhone 语音转文字 MVP，支持在 Apple 系统识别与阿里云 Fun-ASR 录音文件识别之间切换。

## 项目状态

这是一个面向开发者和个人自用场景的实验性项目，目前发布源代码，不提供已签名 App 或 App Store 版本。键盘扩展为实现从第三方键盘唤起主 App 和识别当前宿主，使用了运行时发现的非公开系统类、选择器与 KVC 键；这些实现可能随 iOS 更新失效，也可能不符合 App Store 审核要求。

- 隐私与数据处理见 [`PRIVACY.md`](PRIVACY.md)。
- 安全问题请按 [`SECURITY.md`](SECURITY.md) 私密报告。
- 贡献方式见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。
- 第三方依赖与二进制分发前的合规事项见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 当前版本

- 主 App 负责录音，并可选择 Apple Speech 或阿里云 Fun-ASR。
- 点击“开始录音”录音。
- 点击“停止并识别”后，按“识别服务”中的当前选项转写整段录音。
- 热词词库可保存数百个词；每次识别按置顶、启用状态和最近命中时间最多激活 100 个。
- 阿里云模式会创建或复用 `fun-asr` 定制热词表，词表变化时自动更新；关闭热词的对照识别不会传入词表 ID。
- 阿里云结果中的字词级时间戳会随识别历史一起保存。
- 键盘右上角提供紧凑的模块切换器，从左到右依次为语音、AgenBoard 内嵌键盘和快捷短语；快捷短语入口可在主 App 中隐藏。进入内嵌键盘后，顶部左侧会直接显示由 librime 与雾凇拼音词库生成的候选，点选和空格确认都会写入 App Group 中的持久化用户词典，候选顺序会随长期使用逐渐适应个人习惯。四排按键使用无死区触摸平面覆盖键帽间隙与两侧空白；未确认拼音会作为标记文本实时显示在宿主输入框中，选择候选词后原位替换，按回车则保留英文字符。键盘还支持英文大小写、大写锁定、数字、符号、连续删除和空格长按拖动光标；键盘切换统一使用 iPhone 底栏的系统地球键，避免重复入口。
- 语音模块以麦克风为主操作，录音中、处理中和完成回填使用精简状态反馈；辅助区只保留删除、`@`、明确标注的空格和换行。AgenBoard 已声明自带语音输入，因此不会再额外显示系统听写按钮。
- 主 App 提供“键盘触感反馈”开关，默认开启，并通过 App Group 同步到键盘扩展。
- 在语音或快捷短语模块点击左上角的 “AgenBoard” 标题可直接打开主 App；键盘模块会把同一位置让给拼音候选。主 App 的“快捷短语库”支持新增、编辑、启用、排序和删除短语，并通过 App Group 与键盘同步。
- 主 App 提供完整用户数据导出与导入：标准 ZIP 内包含可读 JSON、JSONL、Markdown、Rime 拼音学习快照和可选 M4A，支持导入预览、智能合并与完全替换。

## 导入与导出

首页进入“导入与导出”后，可以一键生成标准 ZIP。数据包不包含二进制 plist 或 `UserDefaults` 内部键，目录结构如下：

```text
manifest.json
README.md
preferences.json
hotwords.json
quick-phrases.json
credentials.json          # 仅在用户明确开启时存在
recognition-history.jsonl
pinyin/rime_ice.userdb.txt  # 有可用的拼音学习快照时存在
recordings/*.m4a            # 仅在用户明确开启时存在
```

- JSON 字段使用可读英文名称和 `snake_case`，时间使用 ISO 8601，实体 ID 使用 UUID。
- `recognition-history.jsonl` 每行一条记录，便于 AI、脚本和其他 App 流式读取；转写文本始终导出。
- `pinyin/rime_ice.userdb.txt` 是 Rime 原生 UTF-8 文本快照，包含用户实际学习出的拼音编码、候选文字、使用次数、动态权重和时间数据。候选提交后会自动防抖刷新，键盘宿主进入后台或键盘隐藏时还会再次兜底刷新；导入后在下次打开键盘时由 Rime 安全恢复。
- 原始录音默认不导出。开启“包含原始录音”后才会写入 `recordings/`；未附录音的历史仍可作为纯文本历史导入 AgenBoard。
- `manifest.json` 提供格式版本、内容数量、文件大小和 SHA-256；用户或 AI 编辑文件后即使未重新计算校验值，导入页也只会提示修改并继续做结构校验。
- 智能合并按稳定 ID 更新同一条数据；没有相同 ID 时，热词按规范化文字去重，快捷短语按内容去重，拼音学习记录由 Rime 原生合并。完全替换则以数据包覆盖当前热词、短语、偏好、历史、录音和包内拼音学习记录；旧数据包未包含拼音快照时会保留当前设备的拼音偏好。
- API Key 默认不导出。用户可以明确开启“包含阿里云 API Key”，此时它会以明文写入 `credentials.json`，导入后重新保存到目标设备钥匙串。
- 缓存、临时文件、画中画状态和键盘运行状态不会进入数据包。

## 如何选择识别服务

| | Apple 系统识别 | 阿里云 Fun-ASR |
| --- | --- | --- |
| 更适合 | 日常聊天、随手记录、快速回填 | 中文长录音、专业词较多、准确度优先 |
| 处理方式 | iOS 26 使用设备端 SpeechAnalyzer；iOS 17–25 使用 Apple Speech 兼容路径 | 主 App 上传完整录音并提交云端异步识别 |
| 速度 | 通常更快 | 受上传、排队和网络状况影响，通常更慢 |
| 账号与费用 | 无需第三方 API Key，没有单独的 API 调用费用 | 使用用户自己的百炼 API Key，费用计入用户自己的阿里云账号 |
| 数据说明 | AgenBoard 不会把录音发送到项目维护者的服务器 | 录音和已启用热词会发送到阿里云百炼；当前没有 AgenBoard 中转服务器 |
| 主要取舍 | 方言、噪声和专业词场景下结果可能不如云端服务稳定 | 需要联网并上传音频，同时需要用户自行配置和保管 API Key |

首次打开 App 会显示完整使用向导，帮助用户添加键盘、理解“允许完全访问”的用途、验证键盘状态并选择识别服务。完成后也可以随时从首页“使用指南”重新查看和切换。

> iOS 26 的 Apple 路径使用设备端语音模型，首次识别可能需要下载由系统管理的中文模型。iOS 17–25 的兼容路径是否需要联网由系统和设备能力决定，项目不在这些系统上承诺完全离线。

## 配置阿里云识别

1. 在 App 首页打开“识别服务”。
2. 选择“阿里云 Fun-ASR”。
3. 粘贴在华北 2（北京）创建的阿里云百炼 API Key。
4. 点击“保存阿里云配置”，然后点击“测试连接”。

API Key 只保存在本机钥匙串，不会写入项目文件或 `UserDefaults`；配置页可以按需显示、隐藏或复制已保存的 Key。个人版固定使用华北 2（北京）的 DashScope 接入点，不需要填写 Workspace ID。阿里云模式先把本地 `m4a` 上传到百炼临时存储，再提交 `fun-asr` 异步录音文件识别任务。当前采用 BYOK（用户自带 API Key）模式，项目方不提供中转服务器；如果未来改为由项目方统一提供托管识别服务，则应由服务端保管项目方凭证并向客户端签发短期凭证。

## 启用键盘

真机安装后：

1. 打开 iPhone “设置”
2. 进入 “通用” -> “键盘” -> “键盘”
3. 点击 “添加新键盘”
4. 在第三方键盘里选择 “AgenBoard”
5. 再次进入 “AgenBoard”，打开“允许完全访问”，以便语音状态、识别结果和快捷短语通过 App Group 与主 App 同步

键盘的“语音”页会把识别结果自动回填到当前输入框；“快捷短语”页默认提供“你好”和“稍后回复”两条日常示例，也可以在主 App 的快捷短语库中自行维护；“键盘”页默认使用中文拼音，点底行的“英/中”可切换英文。拼音字母会实时显示在当前输入框中，候选词显示在顶部左侧，点候选词或按空格可原位替换为中文，按回车则保留字母并换行或提交。语音和快捷短语页左上角的 “AgenBoard” 标题可直接打开主 App。

## 拼音引擎

- 核心使用固定版本的 LibrimeKit `0.1.0`（librime `1.16.1`）。
- 基础词库来自雾凇拼音提交 `07eca7256d0bae6948dcf3838e14910dbe3b00be`。
- 大型静态词典在构建前从固定的 GitHub Release 下载并校验，最终仍会随键盘离线打包，运行时不会联网下载或现场部署词库。
- 获得“允许完全访问”后，用户词典存放在所配置 App Group 的 `RimeUserData` 目录，升级应用不会清空；此前产生的键盘私有学习数据会在共享容器可用后自动复制迁移。
- 如果 Rime 资源损坏或初始化失败，旧的轻量拼音引擎仍会作为故障回退。

普通开发者运行 `scripts/fetch-rime-data.sh` 获取锁定版本的预编译数据。维护者更新词库时运行 `scripts/build-rime-data.sh`，脚本会下载固定版本、生成预编译数据，并自动检查常用候选和用户学习；随后可用 `scripts/package-rime-data-release.sh` 制作发布资源。

## 构建

### 环境要求

- macOS 与 Xcode 26.4 或更高版本
- Apple Silicon Mac（LibrimeKit 0.1.0 的模拟器二进制仅包含 arm64）
- iOS 17.0 或更高版本

首次检出代码后，先下载并校验预编译 Rime 数据：

```sh
./scripts/fetch-rime-data.sh
```

然后无需签名即可构建模拟器版本：

```sh
xcodebuild \
  -project AgenBoard.xcodeproj \
  -scheme AgenBoard \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

如需安装到真机，请在 Xcode 中打开项目，进入 “Signing & Capabilities”，分别为 `AgenBoard` 和 `AgenBoardKeyboard` 两个 target 选择自己的 Team。项目会自动根据 Team 生成唯一的主 App Bundle ID、键盘扩展 Bundle ID 和 App Group，无需手动填写其他签名标识符。

如需直接调试键盘扩展，请选择 `AgenBoardKeyboard` scheme。该 scheme 默认使用系统 Safari 作为调试宿主；如果 Xcode 询问要运行哪个 App，请选择 Safari。安装并按上文启用 AgenBoard 键盘后，在 Safari 文本框中切换到 AgenBoard 即可触发扩展断点。

## 许可证

AgenBoard 以 [GPL-3.0-only](LICENSE) 开源。第三方代码、库和词典仍适用其各自许可证，详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 与 [`LICENSES`](LICENSES/)。
