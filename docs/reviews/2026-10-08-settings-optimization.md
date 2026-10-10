# 设置页方案二实现与验证

## 实现依据

- 只实现 `design/settings.pen` 的 `jNug5 / AAfT7`，未改设计文件。
- 采用节点中的 18pt 分组间距、白色档位选中胶囊、7pt 搜索圆角、11.5pt 保存状态文字、标题行「恢复默认」。规格正文仍有 28pt 分组间距等差异，按已确认的画板优先规则处理。
- 字体统一 Noto Sans SC；字体和 9 个 Lucide 矢量图标随应用打包，保留上游源文件、许可证及 SHA256。
- 预计体积按用户确认显示「—」，悬停说明影响因素。版本号读取应用包，目录、字数和开关读取真实状态。

## 修改范围

- `SettingsWindow.swift`：现有设置窗口布局、搜索、重置、画质指标、水印预览及自适应高度；分组顺序为搜索与重置、输出、画质、快捷键、启动与提示音、水印、保存状态。
- `SettingsStyle.swift`：颜色、字体、卡片、Lucide、按钮与开关样式；原生焦点及辅助功能状态。
- `AppPreferences.swift`：恢复既有默认值、40 个字符限制覆盖写入及旧值读取，保留原持久化键和录制快照。
- `HotKeys.swift`：允许注入存储及关闭全局注册，正式应用默认仍使用原系统热键注册路径。验证不占用用户全局快捷键。
- 构建和测试脚本打包所需资源；`preview-settings.sh` 使用相同窗口和视图、内存偏好及模拟登录项进行验证。

## 已验证

- `npm run test:native`：22 项通过。新增覆盖全局偏好重置、快捷键持久化/禁用/恢复、旧水印超长值、组合 emoji、键帽录入状态尺寸、字体家族、Lucide 资源及非实心弧线路径。
- `./native/build.sh`：成功；`codesign --verify --deep --strict` 通过。
- 实际运行的 660 × 720 原生隔离验证窗口：检查截图、滚动至页尾及分组顺序；操作画质切换、搜索、快捷键无修饰键提示、Esc 取消、Delete 禁用、恢复默认、水印开关、45 个组合 emoji 截至 40 个、全局重置。状态可见，检查范围内未发现控件溢出或标签截断。
- 最终视图离屏渲染检查：默认开启状态、全关状态、长目录、长快捷键、登录项错误、40 字水印。路径完整换行，长键帽不挤压行标题，预览在关闭时收起且输入保留。
- `screenshots/settings-optimized.png` 是原生视图的完整离屏渲染，不是屏幕截图；不包含系统窗口控制按钮。

## 验证边界

- 560pt 矮窗口已启动并读取辅助功能树；随后 Mac 锁屏，未完成该高度的最终实窗截图检查。
- 未触碰用户真实偏好、全局快捷键或登录项；真实登录项授权和目录选择系统弹窗没有在本轮重新操作。未重新进行真实屏幕录制或 GIF 导出。

## 复现

```sh
npm run test:native
./native/build.sh
sh native/preview-settings.sh --height 720
sh native/preview-settings.sh --long --height 560
sh native/preview-settings.sh --off
```

只编译验证窗口用 `sh native/preview-settings.sh --build-only`。该独立应用不会写真实设置。
