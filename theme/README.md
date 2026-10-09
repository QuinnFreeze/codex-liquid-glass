# Codex Liquid Glass · macOS 主题

为 macOS Codex 桌面应用提供黑白壁纸、玻璃输入框、浮层和连续背景。主题跟随应用的浅色／深色外观，保留原生细滚动条、按钮状态色与字体，并适配“减少透明度”和“减少动态效果”。

通过外置运行脚本和本机调试接口加载样式；安装过程不修改官方应用包及其签名文件。

## 环境要求

- macOS 13 或更高版本；已有官方 Codex 桌面应用。
- Node.js 22 或更高版本，支持内置 `WebSocket`；脚本优先使用 `PATH` 中的 `node`，否则尝试应用内置运行时。
- `python3` 可用；无需额外 Python 包或 npm 依赖。
- Xcode Command Line Tools：安装脚本使用 `/usr/bin/clang` 编译 Objective-C 启动器和观察器。

尚未安装 Command Line Tools 时，可先运行 `xcode-select --install` 并完成系统安装流程。应用查找支持 `/Applications/Codex.app`、`/Applications/ChatGPT.app`，并核对 bundle ID `com.openai.codex`。

## 安装与启动

在仓库根目录打开终端，执行：

```zsh
cd theme
./scripts/install
```

默认安装会先备份，再完成以下操作：

1. 将主题复制到 `$HOME/Library/Application Support/CodexTheme`。
2. 创建独立启动器 `$HOME/Applications/Codex Liquid Glass.app`。
3. 安装并加载 LaunchAgent `local.wynn.codex-liquid-glass`，观察应用启动及窗口变化。
4. 将 Dock 中的官方 Codex 入口替换为主题入口；没有对应入口时添加主题入口，并保存恢复记录。

完成当前聊天后，正常退出 Codex，再从 Dock 的 **Codex Liquid Glass** 启动。主题入口会带本机调试参数打开官方应用，观察器自动接入窗口。

已运行且未启用调试端口的应用无法追加启动参数；安装器不会强制结束当前聊天。直接打开官方应用时，如需主题，应正常退出后改用主题入口。

## 配置与重新应用

安装后编辑正式目录的 `settings.json` 和 `styles/`。仓库中的副本用于维护源码，修改副本不会自动覆盖已安装文件。

```zsh
open -e "$HOME/Library/Application Support/CodexTheme/settings.json"
"$HOME/Library/Application Support/CodexTheme/scripts/reapply"
```

| 配置项 | 默认值 | 作用 |
|---|---|---|
| `wallpaper` | `wallpaper/current.jpg` | 相对主题目录的 JPG、PNG 或 WebP 路径 |
| `position` | `60% 42%` | 壁纸 cover 定位，两个百分比 |
| `mainAlpha` | `0.08` | 浅色主界面底层浓度 |
| `sidebarAlpha` | `0.72` | 浅色侧栏底层浓度 |
| `scrimAlpha` | `0.22` | 从左到右递减的阅读遮罩 |
| `messageAlpha` | `0.90` | 正文阅读底层浓度 |
| `activityAlpha` | `0.78` | 工具活动阅读底层浓度 |
| `floatingAlpha` | `0.86` | 浅色输入框和菜单底层浓度 |
| `floatingBlur` | `7` | 小浮层模糊半径，单位 px |
| `sidebarBlur` | `4` | 兼容旧设置保留，当前侧栏关闭动态模糊 |
| `refraction` | `false` | 小菜单边缘折射开关 |

浓度取值为 `0–1`，模糊半径为 `0–24`。深色模式有独立浓度覆盖；辅助功能设置优先。缺少 `scrimAlpha` 或 `activityAlpha` 时使用默认值。

更换壁纸时，将图片放入正式目录的 `wallpaper/`，修改 `wallpaper` 字段后重新应用。`original.jpg` 是保留原图，当前使用 `current.jpg`。

## 卸载与备份

执行正式安装目录的卸载入口：

```zsh
"$HOME/Library/Application Support/CodexTheme/scripts/uninstall"
```

卸载会停止主题服务、移除自动接入、恢复主题管理的 Dock 项，并移除主题启动器；设置、主题文件、壁纸和备份保留。随后正常退出 Codex，再从官方应用入口打开，以关闭主题启动时启用的调试端口。

安装及卸载的集成备份位于 `$HOME/Library/Application Support/CodexThemeBackups/`；手动重新应用的文件备份位于正式主题目录的 `backups/`。不要删除需要恢复的备份。

## 验证范围与兼容性

历史验收环境为 **Codex 26.930.61225、macOS Intel**。已记录浅色／深色及系统外观切换、窗口重载、新窗口、隔离实例冷启动、服务恢复、侧栏滚动、输入框和提示文字等检查。部分视口及辅助功能检查使用 Chromium 模拟。

本次 GitHub 上传整理仅检查文档和现有文件，未重新安装、卸载或进行正式应用的完整退出重启测试。未验收 Apple Silicon、后续 Codex 版本或系统重启；原生 DOM 变化可能需要调整 CSS。

主题使用本机 `127.0.0.1:9236` 调试接口，并核对监听进程的官方应用身份。请仅在可信本机环境使用，不转发或公开该端口。

## 来源说明

样式思路参考 [Fei-Away/Codex-Dream-Skin](https://github.com/Fei-Away/Codex-Dream-Skin)，参考提交 `6f72d849e8de36aa7eef6bca9f2634e96b5706f7`，主要包括方向遮罩、输入框单层绘制及明暗底色分离；未运行该项目安装器。

现有壁纸的来源和再分发授权尚未记录，本仓库未声明壁纸许可。使用或再分发图片前，请自行确认相应权利。
