# 贡献指南

感谢你改进 AgenBoard。提交代码即表示你同意按仓库根目录的 GPL-3.0-only 许可证提供该贡献。

## 本地开发

1. 使用 Xcode 26.4 或更高版本，推荐 Apple Silicon Mac。
2. 克隆仓库后运行 `./scripts/fetch-rime-data.sh`，下载并校验锁定的 Rime 预编译数据。
3. 使用 Xcode 打开 `AgenBoard.xcodeproj`，或执行 README 中无需签名的模拟器构建命令。
4. 真机调试时，将两个 Bundle ID 和 App Group 改成自己账号下的唯一值，并为两个 target 选择自己的开发团队。不要提交个人 Team ID 或签名配置。

## 提交变更

- 一个 Pull Request 聚焦一个问题，说明行为变化、验证方式和隐私影响。
- UI 变更请附截图或短视频；数据格式变更请说明兼容和迁移策略。
- 不要提交 API Key、录音、真实转写、个人路径、签名证书、Provisioning Profile 或用户词典。
- 不要把 `AgenBoardKeyboard/RimeData/Prebuilt/` 加回 Git。词库更新应固定上游版本与校验值，并通过 Release 资源发布二进制包和对应源码包。
- 新增网络请求、数据收集或 Required Reason API 时，必须同步更新 `PRIVACY.md` 和相应 `PrivacyInfo.xcprivacy`。
- 新增第三方依赖时，必须固定版本、记录来源，并补齐 `THIRD_PARTY_NOTICES.md` 和许可证文本。

提交前至少运行：

```sh
bash -n scripts/*.sh
plutil -lint AgenBoard/PrivacyInfo.xcprivacy AgenBoardKeyboard/PrivacyInfo.xcprivacy rime-data.lock.plist
./scripts/fetch-rime-data.sh
xcodebuild -project AgenBoard.xcodeproj -scheme AgenBoard \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
