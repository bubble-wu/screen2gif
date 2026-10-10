# screen2gif logo 备选

生成日期：2026-10-07。使用内置 `image_gen`，每个方向单独生成。
用户已选择 A。定稿在 `native/Resources/AppIcon.png`，构建生成多尺寸 `.icns`；菜单栏使用同一取景框的单色模板。下列三款保留为原始概念稿。

| 方案 | 文件 | 意图 | 取舍 |
| --- | --- | --- | --- |
| A 取景框 | `a-focus.png` | 取景角标与录制红点，呼应现有框选交互 | 录屏语义直接；两侧波纹略像广播，定稿时可去掉 |
| B 循环 G | `b-loop.png` | G 形带状循环，强调 GIF | 品牌感较强；首次使用时不如 A/C 容易看懂 |
| C 关键帧 | `c-keyframes.png` | 多帧收拢成一个播放画面 | 最贴近核心管线；菜单栏版本需简化成单色轮廓 |

已采用 A，保留四角取景框、红色录制点和动效弧线。

## 完整提示词

### A 定稿资产编辑

使用内置 image_gen，输入为 `a-focus.png`，启用透明背景。定稿为 `native/Resources/AppIcon.png`；通过 sips/iconutil 生成系统需要的尺寸和 `.icns`，菜单栏模板由 `CaptureIcon.swift` 绘制。

```text
Edit the supplied image A, which the user selected as the final screen2gif macOS app icon. Preserve its exact blue rounded-square tile, four white capture corners, centered coral-red recording dot, subtle motion arcs, proportions and overall identity. Remove ONLY the surrounding white/gray presentation background and external cast shadow, replacing the exterior with genuine alpha transparency, including all corners outside the rounded tile. Center the existing tile on a square canvas, scale it to occupy about 90% of the canvas width for a macOS icon source. No new shapes, no text, no labels, no watermark, no mockup. Keep every interior detail and its polish. Deliver one app icon asset with a transparent background.
```

### A

```text
Use case: logo-brand. Asset type: macOS app icon concept for screen2gif, a minimal menu bar utility that records a selected screen area, removes static frames, crops to movement, and exports a small looping GIF. Create ONE polished original app icon. Direction A: Focus / capture. Bold geometric four capture corners surrounding one compact recording dot and a very restrained motion cue. Clever negative space, immediately legible at 32px, balanced silhouette, high-end calm macOS utility aesthetic, flat vector-like precision with subtle material depth. One centered rounded-square icon fills 80% of a square canvas, plain light neutral presentation background, ample clean margin, no mockup objects. Choose a coherent refined color treatment. No text, letters, captions, watermark, tiny details, camera hardware or collage. This is an alternative logo proposal, not a screenshot.
```

### B

```text
Use case: logo-brand. Asset type: macOS app icon concept for screen2gif, a minimal menu bar utility that records a selected screen area and exports a compact looping GIF. Create ONE polished original app icon. Direction B: Loop / G. A distinctive single continuous geometric ribbon forms a simplified G-like loop and implies an endlessly repeating animation, with a small negative-space frame aperture. Strong readable silhouette, clean thick geometry, restrained dynamic energy, professional contemporary macOS utility aesthetic, vector-like edges with modest tonal depth. One centered rounded-square icon fills 80% of square canvas, plain light neutral presentation background, generous clean margin. Choose a coherent refined color treatment. No written text, captions, watermark, collage, camera, infinity sign, or tiny details. This is an alternative logo proposal, not a screenshot.
```

### C

```text
Use case: logo-brand. Asset type: macOS app icon concept for screen2gif, a screen recorder that compresses long static recordings into a few essential frames and a small looping GIF. Create ONE polished original app icon. Direction C: Keyframes / compression. Three bold offset rounded screen frames compress into one crisp foreground frame; an elegantly integrated small play-shaped negative space suggests the resulting animation. Distinctive compact mark, readable at 32px, very few shapes, strong silhouette, friendly precise macOS utility aesthetic, flat vector-like geometry with subtle layered depth. One centered rounded-square icon fills 80% of square canvas, plain light neutral presentation background, clean ample margin. Choose a coherent refined color treatment. No words, captions, watermark, collage, cameras, complicated film perforations or tiny details. This is an alternative logo proposal, not a screenshot.
```
