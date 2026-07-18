# 第三方软件与数据声明

AgenBoard 使用下列第三方项目。各项目仍由其各自许可证约束；本文件不是对第三方许可证的替代。

| 项目 | 固定版本 | 用途 | 许可证 |
| --- | --- | --- | --- |
| [Rime Ice](https://github.com/iDvel/rime-ice) | `07eca7256d0bae6948dcf3838e14910dbe3b00be` | 拼音词典与预编译词典数据 | GPL-3.0-only |
| [LibrimeKit](https://github.com/zhanggenlove/LibrimeKit) | `0.1.0` (`7daa9974308b716883c12f16ffec40a607e903c1`) | librime 的 Swift 封装及预编译依赖 | BSD-3-Clause |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | `0.9.20` (`22787ffb59de99e5dc1fbfe80b19c97a904ad48d`) | 用户数据 ZIP 导入与导出 | MIT |
| [KeyboardHostBundleID](https://github.com/editorss/KeyboardHostBundleID) 衍生实现 | 源文件内保留版权声明 | 兼容旧系统的键盘宿主识别 | MIT |

直接依赖的许可证文本位于 [`LICENSES`](LICENSES/)；KeyboardHostBundleID 的 MIT 声明保留在使用该实现的源文件顶部。Rime 预编译数据的 GitHub Release 同时提供二进制包、对应源码包、固定版本信息和 GPL-3.0 文本。

LibrimeKit 0.1.0 的二进制包还包含 librime 1.16.1、Boost.Atomic、Boost.Filesystem、Boost.Regex、Boost.System、LevelDB、marisa-trie、OpenCC 和 yaml-cpp。其上游 `THIRD_PARTY_LICENSES.md` 目前只提供依赖与许可证摘要，并明确标注完整上游许可文本尚未嵌入。因此：

- 本仓库当前发布的是源代码和带完整对应源码的 Rime 数据，不发布已编译的 AgenBoard App。
- 在独立分发已编译 App 前，维护者必须核对 LibrimeKit 所含二进制的确切来源，并随分发物补齐所有上游版权、许可证和 NOTICE 文本。

这项限制不影响阅读、克隆和构建本仓库，但它是发布可安装二进制文件前必须完成的合规检查。
