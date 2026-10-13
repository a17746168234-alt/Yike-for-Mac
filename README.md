# Yike for Mac

最新版：**2.6.3（Build 85）**。[下载安装包](https://github.com/a17746168234-alt/Yike-for-Mac/releases/latest/download/Yike-macOS-arm64.dmg)。本次修复在线朗读的 HTTP 403，中文、英文及男女声的在线合成已实测通过。

简洁高效的 macOS 原生翻译应用：文字翻译、图片翻译、截图翻译、语音输入，菜单栏常驻、划词即译。

## 使用演示

[![Yike for Mac 完整使用演示：1 分 55 秒](docs/screenshots/demo-video.png)](https://github.com/a17746168234-alt/Yike-for-Mac/releases/download/v2.6.3-build85/Yike-macOS-demo.mp4)

**原版录屏 · 1 分 55 秒 · 含实际朗读声音**。点击封面下载原版完整视频，也可[直接下载原版视频](https://github.com/a17746168234-alt/Yike-for-Mac/releases/download/v2.6.3-build85/Yike-macOS-demo.mp4)。

演示支持的 6 种语言与语言交换、文字和图片翻译、原图文字及译文编辑、划词翻译浮窗、外观切换、历史记录与设置页面。

## 界面预览

### 主界面

![主界面](docs/screenshots/01-main-window.jpg)

### 翻译引擎切换（Apple 系统翻译 / DeepL）

![引擎切换](docs/screenshots/02-engine-switch.jpg)

### 划词翻译弹窗

![划词翻译](docs/screenshots/03-popup-translation.jpg)

### 图片翻译（译文自然融入原图）

![图片翻译](docs/screenshots/04-image-translation.jpg)

### 账号与安全

![账号与安全](docs/screenshots/05-account-settings.jpg)

## 功能

- **双翻译引擎**：DeepL 高质量翻译（需自填 API Free 密钥）+ Apple 系统翻译（macOS 15+，离线可用）
- **划词翻译**：全局快捷键，在任何应用中选中文字即弹窗翻译
- **图片翻译**：拖入图片或截图，OCR 识别后把译文自然融回原图
- **语音输入**：Apple 语音识别 + 内置离线 Whisper 引擎
- **菜单栏常驻**：关闭窗口不退出，随手即用
- **自动更新**：新版下载后校验 SHA-256 与代码签名，失败自动回滚

## 系统要求

- macOS 13 或以上，Apple Silicon（arm64）
- Apple 系统翻译需要 macOS 15 或以上（低版本自动只用 DeepL）

## 安装

从 [Releases](https://github.com/a17746168234-alt/Yike-for-Mac/releases) 下载最新 `.dmg`，
打开后把 Yike 拖进 Applications 即可。

> 应用为 ad-hoc 签名，首次打开如被 Gatekeeper 拦截，
> 请在「系统设置 → 隐私与安全性」中允许打开。

## 从源码构建

需要 Xcode Command Line Tools 与 CMake：

```bash
bash native/build.sh
```

构建产物在 `outputs/Yike-macOS-arm64.dmg`。
首次构建会下载固定版本的 whisper.cpp 源码并编译内置语音引擎。

测试：

```bash
bash native/tests/run_tests.sh
bash native/tests/run_online_tts_tests.sh
```

## 说明

- DeepL 需要用户自行填写 API Free 密钥（设置 → 账号与安全），密钥只保存在本机系统钥匙串。
- 公共体验账号与自动更新接口由自有服务端提供。

## 开源协议

MIT，详见 [LICENSE](LICENSE)。

在线语音 Sec-MS-GEC v2 校验组件参考 edge-tts（LGPLv3）。许可和修改后的源码随安装包附带，详见 [第三方声明](native/ThirdPartyNotices.txt) 和 [EdgeTTS-LICENSE.txt](native/EdgeTTS-LICENSE.txt)。完整 macOS 源码另附在每次发布的 `Yike-macOS-native-source.zip` 中。
