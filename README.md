# Lumina

把**本地视频**当作 macOS 桌面壁纸。

原生 Swift 实现，不依赖任何第三方库。壁纸渲染在桌面层窗口上 ——
位于系统壁纸之上、桌面图标之下，**不会遮挡任何应用窗口，也不响应鼠标事件**。

```
┌─ 菜单栏 ✨ ─────────────┐
│ ✓ 启用壁纸              │
│   暂停播放         ⌘P   │
│   下一幅           ⌘N   │
│   选择视频…        ⌘O   │
│   当前：5 个视频轮播（随机）│
│   随机播放         ⌘R   │
│   清空视频              │
│   ───────────────       │
│   设置…            ⌘,   │
│   打开日志              │
│   关于 Lumina           │
│   退出             ⌘Q   │
└─────────────────────────┘
```

## 特性

- **视频壁纸** —— 循环播放，或整个文件夹轮播（播完自动切下一个）
- **随机播放** —— 每轮打乱一次，保证一轮内每个视频都播到
- **下一幅** —— 手动跳到下一个，菜单栏 `⌘N` 或设置里的按钮
- **倍速播放** —— 0.5× / 1× / 1.5× / 2× / 3× / 5×
- **自动暂停** —— 全屏应用、电池供电、窗口遮挡、锁屏时自动停止播放
- **多屏支持** —— 每块屏幕一个独立窗口，插拔显示器自动重建
- **不复制文件** —— 只记录路径，不动你的原视频
- **开机自启** —— 可选，写入 LaunchAgent

## 系统要求

- macOS 13 或更高（在 macOS 26.6.2 上验证）
- Apple Silicon（arm64）

## 安装

### 方式一：下载预编译包

从 [Releases](../../releases) 下载 `Lumina-x.y.z.zip`，解压后把 `Lumina.app` 拖进「应用程序」。

> 应用使用 ad-hoc 签名（没有 Apple 开发者证书）。首次打开如果被 Gatekeeper 拦下，
> 在「系统设置 → 隐私与安全性」里点「仍要打开」，或执行：
> ```bash
> xattr -dr com.apple.quarantine /Applications/Lumina.app
> ```

### 方式二：从源码构建

```bash
git clone https://github.com/4choor3/Lumina.git
cd Lumina
bash build/build.sh          # 编译并安装到 /Applications
```

只需 Xcode Command Line Tools，**不需要完整 Xcode**：

```bash
xcode-select --install
```

## 使用

### 放视频

三种方式，任选一种：

**1. 菜单栏** —— 点 ✨ → **选择视频…**

- 选 **1 个视频文件** → 循环播放这一个
- 选 **一个文件夹** → 轮播其中所有视频
- 菜单里会显示「当前：xxx」，一眼看到在放什么

**2. 拖拽** —— 把视频文件或文件夹拖到设置窗口上松手

**3. 命令行**

```bash
# 单个视频
/Applications/Lumina.app/Contents/MacOS/Lumina --video ~/Movies/wallpaper.mp4

# 整个文件夹轮播
/Applications/Lumina.app/Contents/MacOS/Lumina --video ~/Movies/我的壁纸/

# 随机播放
/Applications/Lumina.app/Contents/MacOS/Lumina --video ~/Movies/壁纸 --shuffle

# 2 倍速 + 压暗一点（让桌面图标更清楚）
/Applications/Lumina.app/Contents/MacOS/Lumina --video ~/Movies/a.mp4 --speed 2 --dim 0.2
```

首次运行会自动选用 macOS 自带的 Aerial 航拍素材
（`~/Library/Application Support/com.apple.wallpaper/aerials/videos/`）。

### 命令行参数

| 参数 | 说明 | 取值 |
|---|---|---|
| `--video <路径…>` | 视频文件，或包含视频的文件夹 | 可给多个 |
| `--shuffle` | 随机播放 | — |
| `--fill <模式>` | 画面填充 | `fill` 裁切铺满（默认）/ `fit` 留黑边 / `stretch` 拉伸 |
| `--volume <0-1>` | 音量，默认 0（静音） | 0–1 |
| `--speed <倍率>` | 播放速度（固定档位，非档位值会吸附到最近的档） | `0.5` `1` `1.5` `2` `3` `5` |
| `--dim <0-0.8>` | 压暗视频 | 0–0.8 |
| `--reset` | 清除全部设置后退出 | — |
| `--dump` | 打印当前设置的实际值后退出 | — |

## 常见问题

| 现象 | 处理 |
|---|---|
| 壁纸一片黑，屏幕中间有文字提示 | 按提示操作。提示分「还没有选择视频」和「视频文件找不到了」两种 |
| 视频不动 | 检查「全屏应用时暂停」「使用电池时暂停」是否触发；或看日志有没有 `⏸ 暂停播放` |
| 有画面没声音 | 默认静音，在设置里调音量 |
| 画面被裁掉了 | 设置 → 画面填充 → 改成「适应」 |
| 壁纸被桌面图标挡住 | 正常行为（等同系统壁纸）。想盖住图标：设置 → 通用 → 「壁纸盖住桌面图标」 |
| 高倍速发卡 | 素材帧率过高。设置界面会标出该素材的最高无损倍速 |
| 想重置设置 | `/Applications/Lumina.app/Contents/MacOS/Lumina --reset` |

日志在 `~/Library/Logs/Lumina.log`（菜单栏 → 打开日志）。

## 实现要点

开发过程中踩过的坑都记在 [CHANGELOG.md](CHANGELOG.md)，这里列几个值得说的：

- **窗口层级**：桌面图标在 `-2147483603`，系统壁纸在 `-2147483624`。
  壁纸窗口取 `-2147483610` —— 高于系统壁纸、低于桌面图标。
  ⚠️ 判断"窗口有没有被系统接纳"时，`CGWindowListCopyWindowInfo` 的
  `.excludeDesktopElements` 会把低层级窗口当桌面元素过滤掉，
  必须用 `.optionAll`，否则会把正常显示误判成"被丢弃"。
- **>2× 倍速**：`AVPlayer` 对 >2× 有硬上限（实测某素材 2.2× 就完全停摆）。
  解法是把倍速**烘焙进时间轴**（`scaleTimeRange`），播放器只跑 1×。
- **高倍速发卡**：解码器按「源帧率 × 倍速」产帧，而 macOS 的 AppKit 窗口
  **默认不跑满 ProMotion 的 120Hz，必须用 `NSView.displayLink` 显式申请**。
- **切换不闪黑**：`replaceCurrentItem` 会清空图层缓冲。
  解法是**双缓冲** —— 常备两个 `(AVPlayer, AVPlayerLayer)`，
  在不可见那个上预载新内容，等它出帧后再交换可见性。

## 项目结构

```
Sources/Lumina/
├── main.swift          入口、命令行参数解析
├── Model.swift         设置模型（容错解码，绝不静默清空用户设置）
├── Controller.swift    壁纸窗口管理、多屏、暂停策略
├── Views.swift         视频渲染（双缓冲、倍速烘焙、轮播切换）
├── Importer.swift      文件/文件夹选择与素材探测
├── MenuBar.swift       菜单栏与登录项
├── SettingsView.swift  SwiftUI 设置界面
├── Environment.swift   电池/全屏/遮挡检测
└── Log.swift           日志

build/
├── build.sh            构建脚本（编译 + 签名 + 打包 + 安装）
└── make_icon.swift     生成应用图标（纯 CoreGraphics，无依赖）
```

## 许可证

[MIT](LICENSE)