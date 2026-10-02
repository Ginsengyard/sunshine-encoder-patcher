# 实测数据

数据都在同一台机器上采集（环境见文末）。表格里"接受/拒收"指编码器
`SetOutputType` 是否成功——这是能不能用硬编的第一道门。

## 1. 分辨率 × 帧率

探针用例：1 Mbps、High profile、独立进程、4 轮（"接受"= 至少一轮 `S_OK`）。

| 分辨率 | 帧率 | 结果 |
|---|---|---|
| 1280x720 | 60 | ✅ 接受 |
| 1366x768 | 60 | ✅ 接受 |
| 1600x900 | 60 | ✅ 接受 |
| 1920x1080 | 60 | ✅ 接受 |
| 1920x1200 | 60 | ✅ 接受 |
| 2048x1080 | 60 | ❌ `MF_E_INVALIDMEDIATYPE` |
| 2048x1080 | 30 | ❌ 拒收（说明不是吞吐/帧率问题） |
| 2048x1152 | 60 | ❌ 拒收 |
| 2400x1080 | 60 | ❌ 拒收 |
| 2400x1080 | 30 | ❌ 拒收 |
| 2560x1440 | 60 | ❌ 拒收 |
| 3840x2160 | 60 | ❌ 拒收 |

## 2. 高度扫描（宽度固定 1920）

| 分辨率 | 帧率 | 结果 |
|---|---|---|
| 1920x1088 | 60 | ✅ |
| 1920x1200 | 60 | ✅ |
| 1920x1280 | 60 | ✅ |
| 1920x1440 | 60 | ✅ |
| 1920x1536 | 30 | ✅ |
| 1920x1600 | 30 | ✅ |
| 1920x1920 | 30 | ✅ |
| 1920x2048 | 30 | ❌ |

结论：**每条边 ≤ 1920** 是可用范围；超过就拒。

## 3. 码率扫描（1920x1080@60，High）

| 码率 | 结果 |
|---|---|
| 1 Mbps | ✅ |
| 10 Mbps | ✅ |
| 20 Mbps | ✅ |
| 40 Mbps | ✅ |
| 47 Mbps | ✅ |
| 60 Mbps | ✅ |
| 80 Mbps | ✅ |
| 120 Mbps | ✅ |

码率不是拒收原因。早前观察到"47 Mbps 失败"的那次，同一批日志里分辨率是 2400x1080——
用 1920x1080 复测就通过了。

## 4. "打火"轮次序列（探针原始输出）

同一进程、同一分辨率、每次换新实例，4–6 轮：

```
# 1920x1080@60 High 1 Mbps
round1 FAIL  real=MF_E_INVALIDMEDIATYPE(0xC00D36B4)
round2 OK    real=S_OK
round3 FAIL
round4 OK
round5 OK
```

- 同一实例上立刻重试：仍然是同样的错（不是瞬时抖动）；
- 换实例后总会成功，但"第几轮成功"不固定；
- `MFShutdown` 之后重新 `MFStartup`：回到 round1 的状态（首败）；
- 进程启动时多持有一个 `MFStartup` 引用：`MFShutdown` 循环不再重置这个状态。

## 5. 会话实测（Sunshine + Moonlight）

### 5.1 修复过程中看到的两种探测结局

```
# 探测成功
[21:14:55.769] Creating encoder [h264_mf]
[21:14:55.973] could not set output type (MF_E_INVALIDMEDIATYPE)      ← 第 1 次失败
[21:14:55.974] Creating encoder [h264_mf]                            ← 第 2 次
[21:14:57.580] Found H.264 encoder: h264_mf [mediafoundation]

# 探测失败（两次上限被击穿）→ 回退软编
[21:15:08.717] Creating encoder [h264_mf]
[21:15:08.776] could not set output type (MF_E_INVALIDMEDIATYPE)
[21:15:08.983] Creating encoder [h264_mf]
[21:15:09.094] could not set output type (MF_E_INVALIDMEDIATYPE)
[21:15:09.566] Found H.264 encoder: libx264 [software]
```

这是把重试上限从 2 提到 6、并加 250ms 间隔的直接依据。

### 5.2 客户端 2400x1080（修复前：连续失败）

同一配置下编码器创建失败一直重复，每 ~0.2 秒一次，直到客户端断开（一次记录里数到 **199 次**），
画面始终不出来。

### 5.3 客户端 2400x1080（修复后：自动降级并出画面）

```
[21:15:29.446] Creating encoder [h264_mf]
[21:15:29.550] could not set output type (MF_E_INVALIDMEDIATYPE)      ← 原始尺寸（2400x1080）被拒
[21:15:29.749] Warning: h264_mf: requested 2400x1080 exceeds the 1920 pixel Media Foundation
                encoder limit, using 1920x864 instead                 ← 自动降级
[21:15:29.842] MFT name: 'Intel® Quick Sync Video H.264 Encoder MFT' ← 打开成功
[21:15:29.346] CLIENT CONNECTED … [21:15:38.764] CLIENT DISCONNECTED ← 正常出画面
```

### 5.4 会话汇总

| 客户端请求 | 修复前 | 修复后 |
|---|---|---|
| 1280x720 / ~7 Mbps | 软编（libx264） | 硬编（h264_mf，前 1–3 次失败后成功），连续两次会话都成功 |
| 1920x1080 / 20 Mbps | 软编 | 硬编；编码器输入/输出均为 1920x1080（桌面 1366x768 被放大后编码） |
| 2400x1080 / 47 Mbps | 连败 199 次，无法开始 | 降级为 1920x864，硬编出画面 |

## 6. 口径与局限

- 每个探针用例只跑 4–6 轮，"第几轮成功"是观测值，不是统计量；样本有限。
- "打火"失败模式被观察到**非确定性**（1 次、2 次、3 次才成功都出现过），
  所以 6 次 / 250ms 是工程折中，不是保证。
- 会话统计来自人工连的若干次会话（个位数），长时间回退率还在观察。
- 所有结论只覆盖这台机器（HD 4000 / 驱动 10.18.10.5161 / Windows 10 22H2）；
  其他 Ivy Bridge 机型可能相同，也可能不同，待更多样本。

## 7. 环境

| 项 | 值 |
|---|---|
| 机器 | ThinkPad E531（muxless Optimus） |
| CPU / 核显 | i7-3740QM / Intel HD Graphics 4000，驱动 10.18.10.5161 |
| 独显 | NVIDIA GT 740M，驱动 418.91（NVENC API 9.0；Sunshine 内不可用，边界见 §10） |
| 系统 | Windows 10 专业版 22H2（19045.7725） |
| 服务端 | Sunshine `master` 基线 4429acd0 + 本仓库三处补丁 |
| 客户端 | Moonlight 安卓端（2400x1080 屏） |
| 对照 | ffmpeg CLI 直调 `h264_mf`（同机、同分辨率可正常编码） |

## 8. foundation-sunshine 安装版实测

服务端换成 foundation-sunshine（AlkaidLab）`manual-20261001-111805-dev`（= 分支 commit `02774b0`：
补回 MF 编码器 + 三处补丁），用 Inno Setup 安装包升级安装；`SunshineService` 自启，配置保留。

### 8.1 补丁前：探测直接落到软件编码

```
Trying encoder [nvenc] → [vulkan] → [quicksync]（h264_qsv 失败：gen7）
Trying encoder [amdvce] → [software] → Found H.264 encoder: libx264 [software]
```

他们的编码器列表里没有 `mediafoundation`，所以连尝试都不会发生。

### 8.2 补丁后：1920x1080 会话走硬编

```
Trying encoder [mediafoundation]
Creating encoder [h264_mf] → MFT name: 'Intel QSV Video H.264 Encoder MFT'
Error: could not set output type (MF_E_INVALIDMEDIATYPE)   ← 第 1 次：打火
Retrying h264_mf (attempt 2/6) after error                 ← 第 2 次：成功
…
Found H.264 encoder: h264_mf [mediafoundation]
```

### 8.3 2400x1080 会话：显示自动切换失败 → MFT 被拖坏 → 软编

```
21:44:41  Failed to set new display modes (resolution + refresh rate)   ← VDD 没有 2400x1080 模式
21:44:42  Creating encoder [h264_mf] → MF_E_INVALIDMEDIATYPE
          Retrying h264_mf (attempt 2/6 … 6/6)   —— 6 次全败
21:44:45  第二轮（Color range: MPEG）同样 6/6 全败
21:44:48  Encoder [mediafoundation] failed → Found H.264 encoder: libx264 [software]
21:44:48  Client requested stream resolution (clientViewport): 2400x1080
21:44:48  Initial display: 1366x768, encoding: 2400x1080, scale: 1.75695x1.40625   ← 软编 2400x1080
```

对照 1920x1080：VDD 有该模式 → 显示切换成功 → 探测第 2 次通过 → 硬编。

规避见 `mf-hwenc-fix.md` §6.2（`display_device_prep = disabled`，或给 VDD 补该分辨率）。

## 9. 检查工具输出样例

```
$ tools\check-encoder.cmd

Sunshine 编码器检查   2026-09-29 21:50:50
日志：...\Sunshine\config\sunshine.log

近 2 次会话：硬编 1 / 软编 1

时间                 编码器      平台              判定       会话
2026-09-29 21:15:09  libx264     software          软编       连接 21:15:10
2026-09-29 21:15:28  h264_mf     mediafoundation   硬编 (MF)  连接 21:15:29

最近一次（2026-09-29 21:15:28）：h264_mf — 硬编 (MF)
```

## 10. NVIDIA 侧：NVENC 与 Media Foundation（边界实测）

同机采集（环境见 §7）。这一节回答两个问题：NVIDIA 的 NVENC 在这台机器上到底能不能用、
为什么 Sunshine 的两条 NVIDIA 路线（`h264_nvenc` / `h264_mf`）都走不通。

### 10.1 NVENC 可用：ffmpeg 的 D3D11 直通路径

ffmpeg 默认用 **CUDA 设备**打开 nvenc，在这台机器上初始化失败：

```
[h264_nvenc @ …] Cannot init CUDA
Error initializing output stream 0:0
```

换用**不经过 CUDA 的 D3D11 直通**（在 NVIDIA 适配器上创建 D3D11 设备，帧经 `hwupload`
变成 D3D11 纹理直接喂给 nvenc）则可以正常硬编（ffmpeg 4.1.4，该版本尚未强制 NVENC API ≥ 11）：

```bash
# <name> 为设备别名，<nvidia-adapter-index> 为该机上 NVIDIA 适配器的序号
ffmpeg -init_hw_device d3d11va=<name>:<nvidia-adapter-index> -filter_hw_device <name> \
  -f lavfi -i color=c=black:s=1280x720:r=30:d=1 \
  -vf "format=nv12,hwupload" -c:v h264_nvenc -y out.mp4
```

实测输出 `frame= 30 … speed=2.93x`，成功产出视频文件。**NVENC 硬件与驱动正常。**

### 10.2 NVIDIA H.264 Encoder MFT：在所有条件下都无法实例化

- 枚举正常：`MFTEnumEx`（HARDWARE + H264）能拿到 `NVIDIA H.264 Encoder MFT`
  （CLSID `{60F44560-5A20-4857-BFEF-D29773CB8040}`）；
- 实例化恒失败：`ActivateObject` / `IClassFactory.CreateInstance` 一律
  `0x8000FFFF`（E_UNEXPECTED）。独立 PowerShell、提权脚本、独立探针进程结论一致。

按「给它补一块显示器」这一已知方向逐级加条件（虚拟显示器绑定到 NVIDIA）：

| 条件 | CreateInstance |
|---|---|
| 虚拟显示设备重启（配置已切到 NVIDIA） | ❌ `0x8000FFFF` |
| 再用 `DisplaySwitch /extend` 点亮虚拟屏（活动显示器） | ❌ `0x8000FFFF` |
| 再把虚拟屏设为**主显示器**（已确认 `Primary=True`） | ❌ `0x8000FFFF` |

### 10.3 结构性原因：NVIDIA 适配器没有任何显示输出

DXGI 逐适配器枚举输出：

| 适配器 | 输出数 |
|---|---|
| Intel HD Graphics 4000 | 2（物理屏 + 虚拟屏） |
| NVIDIA GT 740M | **0**（`DXGI_ERROR_NOT_FOUND`） |

muxless Optimus 机型上，显示器（包括虚拟显示器）在显示子系统里都挂在 Intel 的合成路径上，
**不可能出现在 NVIDIA 适配器上**。NVIDIA MFT 的已知前置条件（显示器接在 NVIDIA 上）
在这类机器上无法满足——失败是结构性的，与 VDD 绑定、桌面拓扑无关。

### 10.4 结论（对 Sunshine 的影响）

- `h264_mf` 永远选不到 NVIDIA MFT → 给 NVIDIA 分支放行 `*_mf` 没有意义，本仓库只改 Intel 分支。
- `h264_nvenc` 被 ffmpeg 的 NVENC API 版本下限挡住（要求 ≥ 11.0；本机 9.0），
  除非自制补丁版 ffmpeg——不在本仓库范围。
- 串流继续用 Intel QSV（`h264_mf` + 本仓库三处补丁）；单独用 NVENC 时使用 §10.1 的命令。
