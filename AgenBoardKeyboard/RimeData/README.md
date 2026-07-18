# AgenBoard Rime 数据

这里包含键盘扩展离线使用的 Rime 配置。预编译词典作为 GitHub Release 资源发布，不直接写入 Git 历史。

- 输入方案：`agenboard_pinyin`
- 基础词库：雾凇拼音（Rime Ice）
- Rime Ice 固定版本：`07eca7256d0bae6948dcf3838e14910dbe3b00be`
- librime 版本：`1.16.1`
- 用户词典：运行时保存在 App Group 容器，不写入应用包

预编译数据避免键盘扩展首次启动时编译大型词典：

- 普通开发者运行 `scripts/fetch-rime-data.sh` 下载锁定版本并校验 SHA-256。
- 维护者运行 `scripts/build-rime-data.sh` 重新生成数据。
- 发布时运行 `scripts/package-rime-data-release.sh` 制作二进制包和对应源码包。

下载只发生在开发或 CI 构建阶段；最终 App 仍完整包含离线词典。
