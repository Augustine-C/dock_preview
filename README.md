# Dock Preview

采用 [MIT License](LICENSE)。

面向 macOS 27.0 和 Apple Silicon 的原生 Dock 窗口预览工具。Swift + AppKit，设置页使用 SwiftUI，无第三方依赖，无网络请求。

## 构建与运行

```sh
./scripts/build.sh
open "build/Dock Preview.app"
```

成品位于 `build/Dock Preview.app`。应用常驻菜单栏，不添加自己的 Dock 图标。

首次启动会显示设置页，不会自动申请权限。点击“辅助功能 → 授权”以允许识别、恢复和关闭窗口；点击“屏幕录制 → 授权”以启用缩略图。系统设置中的权限需要用户自行确认。屏幕录制未授权时可使用标题列表。授权后若系统要求重新启动，请从菜单栏退出再打开。

构建默认采用本地 ad-hoc 签名。重建或更换签名后系统可能要求重新授权。若有自己的签名证书，使用 `SIGNING_IDENTITY="证书名称" ./scripts/build.sh`。

## 安装包与语言

```sh
./scripts/package-dmg.sh               # 构建并生成可分享的 DMG
./scripts/package-dmg.sh --skip-build  # 使用已经构建的应用
```

成品为 `build/Dock-Preview-<版本>-arm64.dmg`，包含应用、Applications 快捷方式、MIT 许可证和中英文安装指南。打开时使用固定 Finder 布局，中英文背景说明与箭头提示将左侧应用拖到右侧 Applications。打包需要 Python 3，首次运行在忽略的 `build/dmg-tools` 中安装固定版本的 Finder 元数据工具；应用本身不增加依赖。背景由 `scripts/make-dmg-background.swift` 生成，布局由 `scripts/dmg-layout.py` 设置。

打包只对分发副本使用 ad-hoc 签名，不改变本机构建的签名。此分发包未经 Apple 公证；首次打开与权限设置步骤见 [中文指南](docs/Installation-ZH.txt) 或 [English installation guide](docs/Installation-EN.txt)。

界面默认跟随系统首选语言，支持简体中文和英文，不支持的语言回退到英文。“设置 → 语言”可手动切换，立即生效并保留选择。系统弹窗和其他应用的窗口标题使用它们自身的语言。

## GitHub Actions 发布构建

`.github/workflows/release.yml` 在 main 推送、Pull Request 和手动运行时执行测试、构建 arm64 Release 应用并生成可视化 DMG、应用 ZIP 和 SHA-256 校验文件。使用 GitHub 的 `xcode-27` Apple Silicon runner；下载文件位于运行页面的 `Dock-Preview-arm64` artifact，保留 30 天。

推送 `v<版本>` 标签时，构建成功后自动创建 GitHub Release 并上传上述文件。标签必须与 `Resources/Info.plist` 的 `CFBundleShortVersionString` 一致，例如当前版本为 `v0.2.0`。标签发布步骤拥有 contents 写权限，其余构建只读。CI 使用 ad-hoc 签名，无需签名证书或额外 secrets；产物仍未经 Apple 公证。

## 使用

- 悬停正在运行的应用 Dock 图标 250 ms，显示该应用的普通窗口。
- 点击卡片恢复并切换窗口；悬停卡片的 × 请求关闭对应窗口，不退出整个应用。
- 应用没有打开或最小化窗口时显示“退出应用”。点击发送正常退出请求，保留目标应用自己的确认流程；窗口读取失败时不显示该按钮。
- 点击面板背景取得键盘焦点后，可用方向键选择、Enter 切换、Escape 隐藏。
- 鼠标进入面板的通道保持预览；离开 200 ms 后隐藏。Dock 原本的点击不被拦截。
- 菜单栏提供设置、暂停和退出；设置可调延迟、卡片宽度、排除的 Bundle ID 和登录启动。
- 最小化、隐藏、其他桌面窗口由辅助功能枚举。系统未暴露的窗口不能列出；截图不可用时保留图标、标题或明确标记的缓存。
- 全屏/其他桌面的切换由系统处理，其实际效果取决于目标应用和系统的 Spaces 设置。

## 资源策略

没有空闲轮询或持续录屏。鼠标检测限制为每秒 30 次，AX 查询在专用串行队列执行且设置超时。面板打开时每两秒检查窗口并刷新可见卡片；辅助功能通知可提前更新列表。

使用 macOS 当前的 `SCScreenshotManager` + `SCScreenshotConfiguration` 单帧接口，截图并发最多两个，最长边不超过 640 px。32 MiB 是截图缓存预算，不是整个应用的内存上限。缓存使用按字节预算淘汰的 LRU，收到内存压力通知时清空。面板隐藏立即停止调度、取消会话，并丢弃正在完成的旧结果。不会恢复最小化窗口来获取截图，也不保存/上传真实窗口画面。

窗口操作绑定 AX 对象；截图使用 PID、标题和几何匹配。窗口匹配有歧义时不附加猜测的截图。关闭走 AXCloseButton/AXPress，保留应用自己的文档确认对话框；检测到模态窗口时隐藏预览并激活应用。

## 测试与诊断

```sh
./scripts/test.sh
"build/Dock Preview.app/Contents/MacOS/DockPreview" --diagnose
open -n "build/Dock Preview.app" --args --demo
```

`--diagnose` 只读取权限状态，不弹出授权请求。`--demo` 展示六个虚拟窗口，点击和关闭不会作用于真实窗口；请退出演示实例后运行正常应用。演示用于验证布局，不代表真实截图兼容性。

测量正常运行实例的 CPU 和 RSS：

```sh
pgrep -x DockPreview
python3 scripts/measure.py --pid <PID> --seconds 30 --mode idle --output build/idle-performance.json
python3 scripts/measure.py --pid <PID> --seconds 30 --mode six-real-windows --output build/preview-performance.json
```

CPU 采用采样期间累计 CPU 时间差计算，100% 表示占用一个 CPU 核心。`ps` 时间精度有限，低于分辨率的变化会显示为 0。RSS 不等于 Instruments 的 physical footprint。

性能日志不记录窗口标题或截图，只记录耗时和窗口数：

```sh
log stream --style compact --predicate 'subsystem == "local.augustine.DockPreview" AND category == "performance"' --level info
```

`cards_ready_ms` 是开始枚举至卡片显示的时间，不包含设置的悬停延迟；`capture_batch_ms` 单独记录截图批次耗时。暖启动应重复至少 30 次后统计 P95。

验收记录和待验证场景见 [VALIDATION.md](VALIDATION.md)。安装版两项权限已生效；Finder 原始枚举已验证，用户确认 0.1.7 跨桌面预览与点击切换均正常；完整应用矩阵和截图负载尚未完成验收；已测最终空闲 RSS 约 102 MiB，略高于 100 MiB 目标。

## 本机固定签名与窗口诊断

本机已按用户选择在被 Git 忽略的 `.signing-identity` 中配置固定开发证书。正常构建优先读取 `SIGNING_IDENTITY` 环境变量，其次读取该文件；都没有时才使用临时签名。需要访问钥匙串的构建应在用户自己的终端运行，并由用户处理系统确认。首次从临时签名切换为开发证书后，需要重新建立两项授权。

从已授权的安装版生成窗口诊断（只读，不恢复窗口、不截图，不包含窗口标题）：

```sh
open -n -g -W -a "/Applications/Dock Preview.app" \
  --stdout "$PWD/build/finder-report.json" --args --window-report com.apple.finder
```

报告区分 AXWindows 原始列表、分页数组、直接子窗口、保留引用、最终纳入窗口以及 ScreenCaptureKit 可捕获窗口。请在普通桌面和全屏桌面分别保存一次，比较最小化状态、读取错误和数量。运行诊断必须使用已授权的同一签名应用；单独编译的探针没有该应用的授权。

诊断通过 LaunchServices 启动；直接从终端执行二进制可能把辅助功能访问归属到终端或父进程，出现安装版已授权而命令行仍返回 false 的情况。

当 AXWindows 未暴露其他桌面窗口时，应用以公开辅助功能读取 AppKit 窗口菜单项补充标题卡片。点击操作针对该菜单项；没有真实窗口对象时禁用关闭；截图只在应用和窗口标题在两侧列表中均唯一时匹配。目标应用必须暴露对应窗口菜单，无法保证所有应用都具备此回退能力。
