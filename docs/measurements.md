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
| 独显 | NVIDIA GT 740M，驱动 418.91（NVENC API 9.0，Sunshine 要求 ≥11.0，不可用） |
| 系统 | Windows 10 专业版 22H2（19045.7725） |
| 服务端 | Sunshine `master` 基线 4429acd0 + 本仓库三处补丁 |
| 客户端 | Moonlight 安卓端（2400x1080 屏） |
| 对照 | ffmpeg CLI 直调 `h264_mf`（同机、同分辨率可正常编码） |

## 8. 检查工具输出样例

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