# sunshine-encoder-patcher

让 Sunshine（及其 fork）在**老 Intel 核显**上真正用起 Media Foundation 硬件编码（`h264_mf`），
并在客户端请求的分辨率超出硬件能力时**自动降级**，而不是一直失败。

本仓库是这台机器（ThinkPad E531 / Intel HD Graphics 4000 / Windows 10）上完整排查与修复的产物：
三处小改动 + 一份实测数据 + 两个工具（锚点式补丁脚本、编码器检查器）。

一句话结论：修复前 Intel 核显基本用不上（探测失败就回退 libx264 软编，手机端 2400x1080 会一直连不上）；
修复后 720p / 1080p / 手机端 2400x1080 都能用 Intel QSV 硬编实际出画面。

---

## 症状

在 Intel HD Graphics 4000（Ivy Bridge，驱动 10.18.10.5161）上把 Sunshine 的编码器设为
mediafoundation（即 ffmpeg 的 `h264_mf`）后：

1. 创建编码器经常失败，日志反复出现：

   ```
   Error: [h264_mf @ ...] MFT name: 'Intel® Quick Sync Video H.264 Encoder MFT'
   Error: [h264_mf @ ...] could not set output type (MF_E_INVALIDMEDIATYPE)
   ```

   探测阶段连续失败两次就会放弃，回退到软件编码：

   ```
   [21:15:08] Creating encoder [h264_mf] → could not set output type
   [21:15:08] Creating encoder [h264_mf] → could not set output type
   [21:15:09] Found H.264 encoder: libx264 [software]
   ```

2. 如果客户端按手机屏幕原生分辨率请求 **2400x1080**，这个错误会一直重复：
   实测每 0.2 秒失败一次、连续失败到客户端断开（约 **199 次**），画面完全出不来。

但同一台机器上，**ffmpeg 命令行直接调用 `h264_mf` 是正常的**（1080p60 High 都能编）。
所以硬件和驱动本身能编，问题出在编码器的打开流程。

---

## 根因（三处，互相独立）

### 1. Intel MFT 的"打火" + MF 平台生命周期

Intel 的 QSV MFT 在**同一 MFStartup 纪元内，前几次 `SetOutputType` 会失败**
（`MF_E_INVALIDMEDIATYPE`），失败几次数不固定（实测 1–3 次），失败之后同一纪元的后续实例就正常。
看起来是驱动需要先"打火"一次。

而 ffmpeg 的 `mfenc` 每次打开编码器都会走一遍 `MFStartup` / `MFShutdown`。
`MFShutdown` 把平台引用计数清到 0 后平台被拆掉，"打火"状态随之丢失 —— 于是每次打开都像第一次，
永远卡在首败。（独立 C#/COM 探针矩阵验证：同实例重试无效；换新实例几次后成功；
`MFShutdown` 后重新 `MFStartup` 一定回到首败。）

Sunshine 的探测对每个编码器只给 **2 次**尝试，而 `*_mf` 编解码器没有 fallback 选项
（原代码只在有 fallback 选项时才重试），所以连续失败两次就直接放弃 → 回退软编。

### 2. 硬件能力上限：每条边 ≤ 1920

MFT 对宽或高超过 **1920** 的输出类型直接拒收（下表为实测）。Sunshine 会把客户端请求的
分辨率原样传给编码器，所以手机端 2400x1080 的请求必然失败，且会一直重试。

| 请求分辨率（1 Mbps / 60fps / High） | 结果 |
|---|---|
| 1280x720、1366x768、1600x900、**1920x1080**、**1920x1200** | ✅ 接受 |
| 2048x1080、2048x1152、**2400x1080**（30fps 也一样）、2560x1440、3840x2160 | ❌ `MF_E_INVALIDMEDIATYPE` |
| 宽 1920 时的高度：1088 / 1200 / 1280 / 1440 / 1536 / 1600 / 1920 | ✅ 接受（2048 ❌） |

码率与帧率不是问题：1920x1080@60 下 1 / 10 / 20 / 40 / 47 / 60 / 80 / 120 Mbps **全部接受**。
（之前看到的 47 Mbps 失败，是被 2400x1080 的分辨率拖累的。）

### 3. Sunshine 的能力白名单把 `h264_mf` 挡在门外

`src/platform/windows/display_vram.cpp` 的 `is_codec_supported()` 对 Intel 显卡只放行
名字以 `*_qsv` 结尾的编码器，`h264_mf` 在能力判定阶段就被丢掉（现象是日志里
`Trying encoder [...]` 之后**没有** `Creating encoder`）。这一行不改，上面两处修复都不会被触发。

---

## 三处修改

| # | 文件 | 改动 | 为什么 |
|---|---|---|---|
| 1 | `src/platform/windows/display_vram.cpp` | Intel 分支的白名单加 `*_mf`（1 行） | 让 `h264_mf` 通过能力判定 |
| 2 | `src/main.cpp` | 进程启动时保留一个 MF 平台引用（`MFStartup` 一次，不配对 `MFShutdown`） | 让 `mfenc` 自己的 `MFStartup`/`MFShutdown` 不会拆掉平台，"打火"状态得以保留 |
| 3 | `src/video.cpp` | `*_mf` 编解码器：请求超过 1920 时按比例钳制重试；最多尝试 6 次、失败间隔 250ms | 把硬件的能力上限变成"自动降级"，并把"打火"失败吸收在重试里 |
| 4 | `src/video.cpp` | 给**删掉了 MF 编码器的 fork**（如 foundation-sunshine）补回 `mediafoundation` 编码器定义并注册进编码器列表 | 那些 fork 里根本不存在 `*_mf`，前 3 处无从生效 |

第 3 处只在 `*_mf` 上生效，且**只在真实打开失败后**才钳制，其他编码器（NVENC / AMF / QSV / 软编）行为完全不变。

---

## 效果（实测）

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 1280x720 会话 | 探测失败 → libx264 软编 | 第 1–3 次失败后成功，`h264_mf` + Intel QSV MFT 实际出帧，全程无软编回退 |
| 1920x1080 会话（20 Mbps） | 探测失败 → 软编 | `h264_mf` 成功；桌面 1366x768 由 GPU 放大到 1080p 后编码 |
| **2400x1080（手机端）** | **连续失败 ~199 次，会话起不来** | 自动降级为 **1920x864** 后正常出画面，日志：<br>`Warning: h264_mf: requested 2400x1080 exceeds the 1920 pixel Media Foundation encoder limit, using 1920x864 instead` |

钳制后的分辨率保持客户端的长宽比（2400x1080 → 1920x864），且取偶数。

### foundation-sunshine 上的额外一步，以及一个坑

**额外一步（第 4 处补丁）**：foundation-sunshine（AlkaidLab）把 Media Foundation 编码器**整块删掉了**
（全仓库搜不到 `h264_mf`），探测会直接落到 libx264。所以对它必须先补回 `mediafoundation` 编码器，
前 3 处才有作用对象。脚本会自动检测：缺就补，已有（上游 Sunshine、Apollo）就跳过。

**一个坑（他们的新功能）**：foundation-sunshine 增加了「按客户端分辨率自动切换宿主显示」。
当目标模式在虚拟显示器上不存在时（例如手机端请求 2400x1080，而 VDD 默认只提供
800x600 / 1366x768 / 1920x1080 / 2560x1440 / 3840x2160），模式切换失败后会把 Intel MFT
拖进坏状态——随后的编码器探测出现**连续 12 次** `MF_E_INVALIDMEDIATYPE`（平时"打火"只需 1–2 次），
最终整块探测失败、回退软件编码。

规避二选一：

- 把 `display_device_prep` 改为 `disabled`（宿主保持当前分辨率，由 GPU 放大后编码）；或
- 在 `vdd_settings.xml` 的 `<resolutions>` 里给虚拟显示器补上该分辨率。

1920x1080 不受影响（VDD 有该模式，切换成功 → 硬编正常）。

**实测（foundation-sunshine，安装版）**：

```
Trying encoder [mediafoundation]
Creating encoder [h264_mf] → MFT name: 'Intel QSV Video H.264 Encoder MFT'
Error: could not set output type (MF_E_INVALIDMEDIATYPE)     ← 打火
Retrying h264_mf (attempt 2/6) after error                   ← 重试补丁
MFT name: 'Intel QSV Video H.264 Encoder MFT'（成功）
Found H.264 encoder: h264_mf [mediafoundation]               ← 选定硬编
```

---

## 用法

仓库里的补丁面向 **Sunshine 及其 fork 的源码树**（不是二进制补丁）。

### 方式一：锚点式脚本（推荐，抗上游漂移）

```powershell
# 只检查，不改文件
pwsh -File patches/apply-mf-fixes.ps1 -Repo C:\src\sunshine -Check

# 应用
pwsh -File patches/apply-mf-fixes.ps1 -Repo C:\src\sunshine
```

输出每行一个状态：`applied` / `already-applied` / `anchor-missing`。脚本是**幂等**的，
锚点找不到时会直接报错而不是打错位置。

为什么不用现成的 `.patch`：同一份 diff 在 Apollo、foundation-sunshine 上都会因为上下文漂移而冲突
（锚点函数都在，周边行不同）。脚本按函数级锚点插入、保持原缩进与原换行（LF），
已在两个 fork 的当前代码上验证：三处全部 `applied`，重跑全部 `already-applied`。

`patches/000N-*.patch` 是针对本项目基线的精确 diff，可以直接 `git apply -p1`。

### 方式二：一键查看当前是否硬编

```
tools\check-encoder.cmd      # 双击即可（读取 sunshine.log，不需要停服务）
```

它会列出最近若干次会话用的编码器，并给出"硬编 / 软编"判定与统计：

```
近 2 次会话：硬编 1 / 软编 1
2026-09-29 21:15:09  libx264   software          软编
2026-09-29 21:15:28  h264_mf   mediafoundation   硬编 (MF)

最近一次（2026-09-29 21:15:28）：h264_mf — 硬编 (MF)
```

判据是日志里的 `Found H.264 encoder: <name> [<platform>]`（每次串流前都会写一条）。
如果最近一次是软编，脚本会提示"断开重连即可重新探测"。

---

## 随上游更新维护

1. `git fetch upstream && git rebase upstream/master`（或 merge）。
2. 重跑 `apply-mf-fixes.ps1 -Check`：
   - 三个文件都 `already-applied` → 上游已含修复（或已合并），可以停用本仓库；
   - 出现 `anchor-missing` → 上游改动了那三处结构，需要人工看一眼再调锚点。
3. CI 里跑一次构建（本项目用 `.github/workflows/ci-windows-mf.yml` 包装上游 reusable workflow），确保产物可用。

三处改动都很小（1 行 + 20 行 + 30 行），冲突概率低。

---

## 已知限制

- **每条边 > 1920 无法编码**，这是 Intel Ivy Bridge 一代的硬件上限，任何显示方案（虚拟显示器、自定义分辨率）都改变不了；超出时只能降级。
- "打火"的确切机制没有完全定量：重试次数（6）与间隔（250ms）是可调参数，依据是实测（日志里失败→成功约 300ms；探测阶段见过连续 2 次失败）。
- 第 2 处是**进程级 workaround**（持有 MF 引用），不是上游式的最小改动；如果上游后来修了 mfenc 的 `MFStartup` 用法，这一处可以删掉。
- ffmpeg 命令行为什么首调就能成功，还没找到逐位解释；不影响上述结论。

---

## NVIDIA / NVENC 的边界（为什么本仓库只改 Intel）

在**混合显卡（muxless Optimus）笔记本**上实测（原始数据见 `docs/measurements.md` §10）：

- **NVENC 硬件本身可用**：ffmpeg 走 **D3D11 直通**路径可以正常硬编
  （`-init_hw_device d3d11va=<设备名>:<显卡索引> -filter_hw_device <设备名>` +
  `-vf "format=nv12,hwupload" -c:v h264_nvenc`）。默认的 CUDA 路径在部分老驱动上初始化失败，
  换 D3D11 直通即可（实测 1280x720@30 完整编码出帧）。
- **NVIDIA 的 H.264 Encoder MFT 在这类机器上无法实例化**：`IClassFactory.CreateInstance`
  恒返回 `0x8000FFFF`（E_UNEXPECTED）。把虚拟显示器（VDD）绑到 NVIDIA、点亮它、
  甚至把它设为「主显示器」后实测，全部依然失败——原因是结构性的：DXGI 枚举下
  **NVIDIA 适配器没有任何显示输出**（0 个 output），物理屏与虚拟屏都在 Intel 的合成路径上，
  MFT 的已知前置条件（显示器接在 NVIDIA 上）在这类机器上无法满足。
- 因此本仓库**不给 NVIDIA 分支放行 `*_mf`**：`h264_mf` 到不了 NVIDIA MFT，放行只会带来
  无谓的失败重试。三处补丁只针对 Intel 分支。
- 让 Sunshine 用上 NVENC 需要替换为放宽 NVENC API 版本校验的定制 ffmpeg
  （新版要求 API ≥ 11.0，而本机 / Kepler 移动版驱动上限是 9.x），不在本仓库范围内。

需要 NVENC 时用上面的 ffmpeg D3D11 命令即可；串流维持 Intel QSV（`h264_mf` + 本仓库补丁）。

---

## 验证环境

| 项 | 值 |
|---|---|
| 机器 | ThinkPad E531（muxless Optimus） |
| CPU / 核显 | i7-3740QM / Intel HD Graphics 4000，驱动 10.18.10.5161（独占所有显示输出） |
| 独显 | NVIDIA GT 740M（驱动 418.91 → NVENC API 9.0；Sunshine 内不可用，边界与实测见「NVIDIA / NVENC 的边界」） |
| 系统 | Windows 10 专业版 22H2（19045.7725） |
| 服务端 | Sunshine `master`（基线 4429acd0）+ 本仓库三处补丁，自编译 |
| 客户端 | Moonlight（安卓端，2400x1080 屏） |

## English summary

This repo documents and fixes Media Foundation hardware encoding (`h264_mf`) on legacy Intel
integrated GPUs (Ivy Bridge / HD 4000 and similar) in Sunshine and its forks.

Three small changes: allow `*_mf` codecs for Intel adapters in `is_codec_supported()`;
hold one MF platform reference for the process lifetime so `mfenc`'s
`MFStartup`/`MFShutdown` cycle cannot reset the MFT's armed state; and, for `*_mf` codecs,
retry a failed open with the client's resolution clamped to the 1920-pixel limit
(up to 6 attempts, 250 ms apart, aspect ratio preserved).

Measured on an HD 4000 (driver 10.18.10.5161): requests wider or taller than 1920 px are
rejected with `MF_E_INVALIDMEDIATYPE` regardless of frame rate; bitrate is not a factor
(1–120 Mbps accepted at 1080p60). After the fix, 720p / 1080p sessions encode with Intel QSV
and a phone's 2400x1080 request is downgraded to 1920x864 instead of failing ~199 times.

On the NVIDIA side (see docs/measurements.md §10): NVENC works through ffmpeg's D3D11
device path, but NVIDIA's H.264 encoder MFT cannot be instantiated on muxless/hybrid
laptops (the NVIDIA adapter exposes no display outputs), so the patches deliberately
stay Intel-only.

## 许可

补丁面向 [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)（GPL-3.0）的源码；
本仓库的脚本与文档随补丁一并以 GPL-3.0 提供。
