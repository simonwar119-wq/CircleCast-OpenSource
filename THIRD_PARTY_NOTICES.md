# 依赖、素材与许可证声明

## 本仓库的原创内容

`Sources/`、`Tests/`、构建/审查脚本、说明文档以及 `scripts/make-icon.swift` 的图标绘图代码，是本项目开发过程中编写的内容，按根目录 `LICENSE` 中的 MIT 条款提供。图标使用基本几何图形绘制，没有导入人物照片、商标图、付费图标库或第三方字体文件。

测试画面为程序生成的纯色色块，测试声音为程序生成的正弦音调。仓库保留生成和验证代码，不包含生成媒体、真实人像、录制、用户讲稿或本机日志。

## Apple 平台依赖

应用链接 Apple 系统提供的 AppKit、AVFoundation、ScreenCaptureKit、Core Image、Core Media、Core Video、Core Graphics、UniformTypeIdentifiers 和 Foundation 等框架。测试使用 XCTest。字体使用系统字体 API。

Apple SDK、系统框架、系统字体及 Xcode 工具并不复制或分发在本仓库内；使用它们仍遵循 Apple 的相应许可条款。本项目的 MIT 许可证不授予 Apple 材料的额外权利，也不表示 Apple 认可或支持本项目。

`Package.swift` 没有远程 Swift Package 依赖；未复制第三方示例代码、开源库源码或外部素材。构建脚本使用系统工具生成图标并做 ad-hoc 本机签名，不包含开发者证书、私钥或公证配置。

## 文档参考

实现时参考 Apple 的公开 API 文档和本机 SDK 声明。文档链接列在 `docs/ARCHITECTURE.md`；引用链接不等于把 Apple 文档或样例代码纳入 MIT 分发。

如果后续贡献引入第三方代码或素材，应在此文件补充来源、准确版本、许可证与必要声明后再合入。
