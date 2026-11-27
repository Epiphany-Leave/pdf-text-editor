# PDF 文字修改工具

一款基于 Flutter 与 PDFium 构建的跨平台文字型 PDF 本地修改工具，使用 `pdfrx` 渲染页面并通过 FFI 实现底层编辑。

[v1.0.9 发布页](https://github.com/Epiphany-Leave/pdf-text-editor/releases/tag/v1.0.9) 提供 Android arm64 APK 与 Windows x64 便携版。

## 下载与运行

- **Windows x64** 下载 [pdf_text_editor-Windows-v1.0.9-x64.zip](https://github.com/Epiphany-Leave/pdf-text-editor/releases/download/v1.0.9/pdf_text_editor-Windows-v1.0.9-x64.zip)。请将压缩包内的所有文件完整解压后，双击 `pdf_text_editor.exe` 运行，并保留 `pdf_text_editor.exe` 同级的 DLL 文件与 `data/` 目录。
- **Android arm64** 下载 [pdf_text_editor-Android-v1.0.9-arm64.apk](https://github.com/Epiphany-Leave/pdf-text-editor/releases/download/v1.0.9/pdf_text_editor-Android-v1.0.9-arm64.apk)。本版沿用原有 debug 签名，已安装 v1.0.6、v1.0.7 或 v1.0.8 的用户可直接覆盖更新。

## 核心功能

- 打开文字型 PDF 后可直接点击页面文字进行修改
- Windows 可从资源管理器把 PDF 拖入首页或编辑窗口。已有文档时，新文件会另开一页，返回可继续编辑原文档。
- Android 与 Windows 共用新版首页与阅读界面。宽屏采用右侧编辑面板，窄屏采用可滚动的底部编辑面板。
- 尽量保留原字号、颜色、粗体、文字矩阵与基线，优先复用原文档字体
- 修改文字宽度变化时，同行紧邻的后文自动让位
- 支持修改预览与撤销操作
- 导出默认使用原文件名。安卓会选中文件名主体，输入即可改名。`.pdf` 后缀固定，改好后再选择保存位置。同目录重名时，安卓可能加数字区分，Windows 会在覆盖前询问。

## 字体管理

Android 与 Windows 均支持以下字体匹配与管理方式。

- 优先查找当前设备系统中的同款字体
- 从内置字体目录按需下载有授权的同款字体并本地缓存
- 支持手动导入本地 TrueType `.ttf` 与 `.ttc` 字体文件
- 缺少同款字体时，在实际 PDF 页面中预览近似字体并经用户确认后应用

## 本地处理

- 所有 PDF 解析、编辑与导出均在设备本地完成
- 仅在按需下载目录字体时需要联网

## 已知限制

- 仅支持文字型 PDF，不支持扫描件 OCR 识别
- 不支持旋转页面、整段自动换行、跨行重排及自动分页
- 行内可用空间不足时，界面会提示缩短文字
- 部分局部改写采用白色遮盖呈现，原文字仍可能被提取，不可用作敏感信息抹除手段
- 编辑时嵌入完整字体可能增大导出的 PDF 文件体积
- 内置字体目录覆盖有限，手动导入字体需由用户自行确保合法使用权
- 当前 Android release 构建的 APK 使用 debug 签名

## 测试状态

v1.0.9 的 38 项 `flutter test` 自动化测试全部通过，覆盖文字编辑、格式保留、拖拽打开和导出文件名等流程。手机和桌面上的实际操作仍需手测。

## 构建环境

Android 和 Windows 共用 `pubspec.yaml` 中的版本号。

- Flutter `3.50.1`
- Dart SDK `^3.14.0`
- Android `API 36`、NDK `28.2.13676358`、Gradle `9.5.0`
- Windows 需安装 `Visual Studio 2022 Desktop C++ workload`

## 构建与测试

```bash
# 获取依赖
flutter pub get

# 运行自动化测试
flutter test

# 构建 Android arm64 APK（debug 签名）
flutter build apk --target-platform android-arm64 --release

# 构建 Windows x64 发布版本
flutter build windows --release
```

## 许可说明

本项目源代码使用 MIT 许可证（© 2026 Epiphany-Leave），完整条款见仓库根目录的 [LICENSE](LICENSE)。

随附的 Noto Sans SC 字体遵循 SIL OFL 1.1 许可证，许可文件见 [assets/fonts/OFL.txt](assets/fonts/OFL.txt)。
