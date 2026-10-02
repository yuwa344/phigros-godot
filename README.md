# Phigros Godot 复刻

Godot 4.7 (GDScript) 实现的 Phigros 玩法复刻，完整支持 RPE (formatVersion 3) 谱面格式。
横屏 1920×1080（与原版手游一致）。谱面/素材来自公开仓库 zmz2333/phigros-html5（仅供个人学习研究，素材版权归 Pigeon Games 所有，勿商用）。

## 运行

用 Godot 4.7+ 打开本目录直接 F5，或命令行：

```
Godot_v4.7.2-stable_mono_win64_console.exe --path . 
```

## 操作

| 输入 | 作用 |
|---|---|
| 点击 / 触摸 | 打 Tap、起 Hold 头（多点触控支持） |
| 按住 | 维持 Hold |
| 按住拖动 | Flick |
| Drag | 过线自动判定，无需操作 |
| Esc | 暂停菜单 |
| P | 自动演示 (autoplay) 开关 |
| R | 重新开始 |

## 判定与计分（与原版公式一致）

- 窗口：Perfect ±80ms，Good ±160ms，Bad ±200ms；过线 0.16s 后未判 Miss
- 击打音效（HitSong0/1/2.ogg，与原版绑定一致）：Tap/Hold头=0，Drag=1，Flick=2；8 路复用防密集和弦切断
- 分数 `1e6*(P*0.9 + G*0.585 + maxCombo*0.1) / 总note数`
- 准确率 `(P + G*0.65) / 总数`；评级 φ / V / S / A / B / C / F

## 谱面格式实现要点（RPE v3 公开数学）

- 时间换算：`秒 = beats / bpm * 1.875`
- 判定线三事件（move/rotate/disappear）按 startRealTime→endRealTime 线性插值
- move 的 x 取 `start..end`（0..1 乘屏宽），y 取 `1 - (start2..end2)` 乘屏高
- 线流速：`posY = (t - startRealTime) * value + floorPosition`
- note 屏幕坐标：`x = ox + dx*cosr + dy*sinr`，`y = oy + dx*sinr - dy*cosr`
  - above：`dx = W/18 * positionX`；below：dx 取反且 cosr/sinr 取反（镜像）
  - `dy = (noteFP - linePosY) * speed`；hold 按住期间头钉线：`dy = (noteTime - t) * speed`
- 流速基准 `HLEN2 = H*0.6`，note 素材 989px 宽 × `noteScale = W/8000`

## 添加歌曲

在 `songs/<曲名>/` 放入：`meta.json`（字段同 phigros-html5）、RPE json 谱面、`musicFile` 音频（ogg/mp3/wav）、曲绘 png、可选 `line.json` 自定义判定线贴图。启动时自动扫描。

## 命令行工具

```
--selftest   headless 自动演示整首谱面并输出判定统计（Engine.time_scale=20 快进，可加 EZ/HD/AT 参数）
--shot       窗口模式自动演示，截图到项目上级目录
--inputtest  合成点击测试启动页→选曲链路
```

## 打包 iOS unsigned IPA

1. 把整个项目（含 `.github/workflows/ios-unsigned-ipa.yml` 和 `export_presets.cfg`）推到 GitHub 仓库
2. Actions → Build unsigned iOS IPA → Run（macos-15 runner：装 Godot 4.7.2 + 模板 → 导出 Xcode 工程 → `xcodebuild CODE_SIGNING_ALLOWED=NO` 出未签名 IPA）
3. Artifacts 下载 `PhigrosGodot-unsigned.ipa` → 全能签重签 / Sideloadly 安装

本地手动打包（需 macOS + Xcode）：`godot --headless --path . --export-release "iOS" build/ios_xcode`，然后同上 xcodebuild → Payload → zip。

## 已知限制 / 踩坑

- 横屏标定：`lineScale = H/18.75`（W>H*0.75 分支）、`noteScale = W/8000`、判定半径 `W*0.117775`，与原版引擎对横屏的处理一致
- v1/v2 谱面事件坐标换算按公开规格实现，未大量验证；.pec 文本谱面暂不支持（ouroVoros 只有 pec 版，未收录）
- 音符不显示先查两层 CanvasLayer：背景必须放 layer=-1，否则盖住整个世界层（z_index 救不了）
- headless 下 Dummy 音频驱动不走混音，`get_playback_position()` 恒 0，自测需增量时钟兜底
- Godot mono 版启动时报 ".NET Sdk not found (9.0.20)" 可忽略——纯 GDScript 工程不需要
- 长 Hold (速度×时值×HLEN2 px) 贯穿全屏是谱面本身特征（Spasmodic 开头即如此），不是渲染 bug
- 多点触控在 Windows 上依赖触摸屏；鼠标只能单点（project.godot 已开 emulate_touch_from_mouse）
- Godot 编辑器会往 project.godot 写乱码键（GBK 路径问题），若再见到直接重写该文件
