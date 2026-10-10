# 设置页优化 · 方案二 实现交接

给 codex 的交接说明。设计源在 `design/settings.pen`，界面实现目标是原生 macOS（SwiftUI/AppKit），**不是网页**——不要用 `html-tailwind` / `html-css` 导出。

## 采用范围

- 采用：根 frame **`2. 设置页优化方案`（id `jNug5`）**，其中要实现的界面是 **`优化后设置窗口`（id `AAfT7`）**；同一根帧里的 `优化点列` 只是评审说明，不实现。
- 备选、不采用：`1. 侧边栏导航重构（备选 · 未采用）`（id `GRBjK`），已移到主画布下方归档。
- 视觉基准：`design/previews/jNug5.png`（整块评审板）、`design/previews/AAfT7.png`（设置窗口单体）。

## 落点文件

- `native/Sources/SettingsWindow.swift` — 设置界面主体
- `native/Sources/AppPreferences.swift` — 偏好持久化
- `native/Sources/LaunchAtLogin.swift`、`OutputDirectory.swift`、`TextWatermark.swift`、`HotKeys.swift` — 各分区对应行为

## 结构（自上而下，单页纵向滚动）

1. **搜索与重置行** — 搜索框（占满）+「恢复全部默认」按钮
2. **输出位置** — 输出文件夹行 +「更改…」；「导出后在访达中显示 GIF」开关
3. **画质与体积** — 三档分段（清晰优先 / 均衡 / 体积优先）+ 档位说明 + 量化指标（最大宽度 / 帧率上限 / 预计体积）
4. **快捷键** — 标题行右上角「恢复默认快捷键」胶囊按钮；卡片内三行（录制全屏 `⇧⌘6` / 框选区域录制 `⇧⌘7` / 停止录制 `⇧⌘8`）+ 帮助文案「点击输入框录入组合键；Delete 禁用，Esc 取消。组合需包含 Command / Control / Option。」
5. **启动与提示音** — 开机自启动开关 + 开始和结束时播放提示音开关
6. **文本水印** — 开关 + 文本输入（含字数 `9 / 40`）+ 效果预览 + 帮助
7. **保存状态** —「所有更改已自动保存」+ 版本号

> 本轮已把 `启动与提示音` 排到 `文本水印` 之前。

## 颜色 Token（沿用 pen 变量）

| 变量 | 值 | 用途 |
| --- | --- | --- |
| `$s2gBg` | `#FAFAFA` | 窗口底色 |
| `$s2gPanel` | `#F0F0F2` | 分段控件底 / 次级面 |
| `$s2gText` | `#232428` | 主文字 / 图标 |
| `$s2gSecondary` | `#71747A` | 次级文字 / 图标 |
| `$s2gAccent` | `#007AFF` | 开关选中 / 强调 |
| `$s2gBorder` | `#D9DADF` | 输入框、按钮描边 |
| `$s2gFont` | `Noto Sans SC` | 全局字体 |

补充色：卡片描边 `#E7E8EC`，分隔线 `#EFF0F3`，行说明文字 `#5F6268`，键帽底 `#F3F4F6` / 描边 `#E3E4E8`，水印预览渐变 `#3B414E → #20242C`。

## 控件规格

- 窗口：宽 **660**，标题栏高 44，内容 padding 20，分组间距 28。
- 分组标题：lucide 图标 15px + 标题 13pt / 600；标题行与卡片间距 7。
- 卡片：描边卡片 `#FFFFFF`、圆角 10、1px `#E7E8EC`。
- 设置行：padding `[11,14]`、行标题 13pt + 说明 11pt（`#5F6268`，lineHeight 1.45）；快捷键帮助 11pt / lineHeight 1.5（`#5F6268`）；行间 1px `#EFF0F3` 分隔线。
- 开关：34 × 20、圆角 10，开启 `#007AFF`，滑块 16。
- 搜索框：高 32、圆角 7、`#FFFFFF`、描边 `#D9DADF`，lucide `search`；「恢复全部默认」按钮圆角 7、描边 `#D9DADF`。
- 画质分段：外框 `#F0F0F2` 圆角 8 / padding 3；**选中档位是白色胶囊 `#FFFFFF` 圆角 6（不是蓝色）**，选中文字 `$s2gText` / 600、未选中 `$s2gSecondary` / normal，均 12.5pt。
- 「恢复默认快捷键」胶囊：`#EAF2FF`、圆角 20、padding `[3,10]`、文字 12pt。
- 快捷键键帽：`#F3F4F6`、描边 `#E3E4E8`、圆角 6、padding `[4,10]`。
- 水印输入框：圆角 7、描边 `#D9DADF`，lucide `pencil`。
- 水印预览：深色渐变、圆角 8、padding 12。
- 保存状态：lucide `circle-check` + 11.5pt（`$s2gSecondary`）。

## 图标（lucide）

`folder`、`sliders-horizontal`、`keyboard`、`power`、`type`、`search`、`rotate-ccw`、`pencil`、`circle-check`。

## 行为

- 单页纵向滚动；窗口高度适配屏幕可用高度。
- 设置自动保存（脚注「所有更改已自动保存」）；录制设置下次录制生效，快捷键即时生效。
- 水印关闭时收起效果预览，保留文本输入。
- 控件间距、文字标签以 `design/settings.pen` 为准，不要自行改写文案。
