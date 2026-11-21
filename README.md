# PDF 文字修改工具(pdf_text_editor)

给非技术用户用的 PDF 文字修改工具(Windows / Android):打开 PDF → 点击文字直接改 → 导出新文件。替代"PDF 转 Word 改完再转回 PDF"的流程,且不会出现格式转换导致的排版错乱。

## 功能

- 打开文字版 PDF,滚动浏览,点击任意文字段(自动按空隙切分为词/数字段)
- 弹窗预填原文,直接改为新文字;可整段删除(盖白不写新字);可选粗体
- 页面实时预览修改效果(蓝框标出已改处),修改记录可逐条撤销
- 导出为新 PDF,原文件不动;安卓走系统保存界面,Windows 走另存为对话框
- 扫描件图片页自动提示"无文字层,不支持修改"

## 原理

读取与写出都用 PDFium 引擎(pdfrx 渲染 + 直接 FFI 调 PDFium 编辑 API):
每条修改 = 在原文字位置盖白色矩形 + 用内置思源黑体(按原字号自动校准)在原位绘制新文字,字号经测量校准与原文高度一致,最后另存新文件。

## 已知限制

- 替换文字的字体是内置思源黑体(GB2312 常用字子集,两字重各约 2.3MB),与原文字体外观可能不完全一致;生僻字(子集外)在编辑时会提示,导出后可能显示为空白
- 被盖白的原文字仍可能被"复制文本"操作选中(视觉与打印正确,这是该类方案的通行行为)
- 旋转页面、OCR 扫描件编辑暂不支持
- 导出文件因内嵌中文字体约增大 2~3 MB

## 错误排查

首页有"错误日志"入口:应用启动、打开文件、导出的关键节点和所有未捕获异常都记录在应用数据目录 `error_log.txt`(可复制)。导出闪退这类原生层错误无法被 Dart 捕获,但可以结合日志定位到发生在哪一步。

体积说明(arm64 包约 28MB):Flutter 运行时 ≈11MB、PDFium 引擎 ≈7MB、Dart 代码 ≈6MB、两字重字体 ≈4.5MB。只发 `--target-platform android-arm64` 的包;老式 32 位手机需另打 armeabi-v7a 包。

## 字体子集重建

```bash
pip install fonttools
# 生成 GB2312+ASCII+全角字符集后:
pyftsubset 原字体.ttf --text-file=charset.txt --no-hinting --output-file=assets/fonts/NotoSansSC-Regular.ttf
# lib/engine/font_charset.dart 需同步重新生成(编辑时的生僻字提示用)
```

## 开发

```bash
flutter pub get
flutter test        # 7 个测试:文字段切分纯逻辑 + 引擎端到端(改字/删字/坐标校验)
flutter run         # 需连接设备或模拟器
```

### 构建

```bash
flutter build apk --target-platform android-arm64 --release  # 约 28MB
flutter build windows --release                               # Windows,需在 Windows 机器上构建
```

本机(Linux)首次构建需注意:

- pdfium_dart 的构建钩子会编译一个 C 垫片,需要 clang:`~/clang-root/usr/lib/llvm-18/bin` 加入 PATH,`LD_LIBRARY_PATH` 加 `~/clang-root/usr/lib/llvm-18/lib`
- Android SDK 在 `~/android-sdk`(NDK 已装),完整 JDK 在 `~/jdk-root/...`(设 JAVA_HOME)
- Gradle 代理已写入 `~/.gradle/gradle.properties`(127.0.0.1:7890,本机专属)

## 目录

- `lib/engine/runs.dart` 文字段切分(纯逻辑)
- `lib/engine/pdfium_extra.dart` PDFium 编辑 API 补充绑定(2 个函数)
- `lib/engine/pdf_edit_engine.dart` 导出引擎(盖白 + 写新字 + 字号校准)
- `lib/edit_session.dart` 会话状态(文档、文字段缓存、修改记录)
- `lib/viewer_page.dart` 查看器(点击编辑、预览、修改记录、导出)
- `test/` 纯逻辑测试 + 端到端测试(fixture 构造 → 修改 → 重新提取验证)
