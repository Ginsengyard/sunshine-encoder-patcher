# 技术细节：为什么这样改

这份文档记录排查过程、每一处修改的理由，以及被排除的其他方案。
想直接看结论和用法，看仓库根目录的 `README.md`。

## 1. 调查方法

结论不是靠猜的，来源有三类证据：

1. **独立探针**：一个自写的 C# + COM 小程序，复刻 `mfenc` 的调用形态
   （`MFStartup` → 枚举/激活 Intel MFT → 设置输入/输出类型 → 打开 → 关闭 → `MFShutdown`），
   但把每个变量变成命令行参数：分辨率、帧率、profile、码率、是否复用实例、是否持有 MF 引用、
   是否先"热身"一个 dummy 编码器、是否新纪元…… 每个用例在**独立进程**里跑 4–6 轮，记录每轮的返回码。
2. **ffmpeg CLI 对照**：同一台机器上用 `ffmpeg -c:v h264_mf` 直接编码（临时改名
   `nvEncMFTH264.dll` 把枚举指向 Intel），确认"硬件本身能编"。
3. **Sunshine 会话实测**：把补丁编进 Sunshine，用 Moonlight 真实串流，开 `min_log_level = verbose`
   抓 `setting output type` 的完整 `MF_MT_*` 属性。

第 3 类里有一步很关键：verbose 下 `mfenc` 会把每次 `SetOutputType` 的**全部媒体类型属性**打出来，
把"失败的会话属性"和"成功的探测属性"逐字段对比，才发现差异在 `MF_MT_FRAME_SIZE`
（2400x1080 vs 1920x1080），而不是码率或 profile。

## 2. 观察到的四个事实

### 2.1 "打火"：同一纪元内前几次 SetOutputType 必败

探针序列（1920x1080@60 High 1 Mbps，4–6 轮，同一进程内换新实例）：

```
round1 FAIL  MF_E_INVALIDMEDIATYPE
round2 OK    S_OK
round3 FAIL
round4 OK
round5 OK
```

- **同一实例上重试没用**（立刻重试还是同样的错）；
- **换新实例**（同进程、同纪元）几次之后会成功；
- `MFShutdown` 之后重新 `MFStartup`（新纪元）→ 又回到首败；
- 进程启动时**额外持有一个 MF 引用** → 跨 `MFShutdown` 循环仍保持成功（平台没被拆掉）。

失败个数不固定：探测里见过 1 次、2 次、3 次才成功的都有。日志里最高记录是**连续 2 次失败**
（这正是原来 2 次上限被击穿、回退软编的原因）。

### 2.2 mfenc 的平台生命周期与它对不上的地方

ffmpeg 的 `libavcodec/mfenc.c` 每次打开编码器都 `MFStartup`，关闭时 `MFShutdown`。
Sunshine 用固定版本的 ffmpeg 构建，所以问题不在 ffmpeg 用错 API，而是**两边的假设不同**：
mfenc 认为"每次打开都是干净环境"，而 Intel 这代 MFT 需要**同一个持续存活的平台纪元**来保持"打火"状态。

这就是第 2 处修改（进程内持有 MF 引用）的理由：它不去改 ffmpeg，而是让整个进程共享一个纪元。
`MFStartup`/`MFShutdown` 本身是引用计数的，多持有一个引用只是让平台不归零，没有其它副作用。

### 2.3 分辨率上限：每条边 ≤ 1920

完整数据见 `measurements.md`。要点：

- 宽或高 > 1920 → 拒收，**与帧率无关**（2400x1080 在 30fps 下同样被拒）；
- 码率 1–120 Mbps 全部接受 → 码率不是原因；
- 高度上限在 1920 附近（1920x1920 过、1920x2048 拒）。

这属于硬件能力，不是配置问题。Sunshine 原来把客户端请求的分辨率**原样**交给编码器，
遇到手机端 2400x1080 就变成了"必定失败 + 无限重试"。

### 2.4 能力判定白名单

`display_vram.cpp::is_codec_supported()` 对 Intel 适配器只放行 `*_qsv`。
所以即使前两处都修好，`h264_mf` 也进不了候选列表（日志特征：`Trying encoder [h264_mf]` 之后
没有任何 `Creating encoder`）。这是本次改动的第 1 处，也是"最小的一行"。

## 3. 三处修改的细节与边界

### 3.1 `display_vram.cpp`：Intel 放行 `*_mf`

```diff
-      if (!boost::algorithm::ends_with(name, "_qsv")) {
+      if (!boost::algorithm::ends_with(name, "_qsv") && !boost::algorithm::ends_with(name, "_mf")) {
         return false;
       }
```

边界：只是让 `h264_mf`/`hevc_mf`/`av1_mf` 进入候选；实际能不能开，由后面两处负责。

### 3.2 `main.cpp`：进程生命周期内持有 MF 引用

在 `main()` 入口 `LoadLibraryW("mfplat.dll")` + `MFStartup(MF_VERSION, MFSTARTUP_FULL)` 一次，不配对 `MFShutdown`。

边界：Windows 专属；对不使用 MF 的编码器没有任何影响；进程退出时由系统回收。
如果将来 ffmpeg 改成在编码器生命周期外保持平台，这一处可以删。

### 3.3 `video.cpp`：钳制 + 更宽的重试

在 `make_avcodec_encode_session()` 里：

```cpp
constexpr int mf_dimension_limit = 1920;
const bool mf_codec = video_format.name.size() > 3 && video_format.name.substr(video_format.name.size() - 3) == "_mf";
const bool mf_clamp_available = mf_codec && (config.width > mf_dimension_limit || config.height > mf_dimension_limit);
const int max_retries = mf_codec ? 6 : 2;
```

- 第一次尝试用客户端请求的原始尺寸；
- 之后的尝试（若请求超限）按比例缩到 1920 以内，**保持长宽比**、宽高都取偶数；

  ```
  Warning: h264_mf: requested 2400x1080 exceeds the 1920 pixel Media Foundation encoder limit, using 1920x864 instead
  ```

- 失败之间等待 250ms（日志显示失败→成功间隔约 300ms，像是"忙/清理"窗口；背靠背重试容易连续失败）；
- 失败重试条件放宽为"还有剩余尝试 && （有 fallback 选项 || 是 MF 编码器）"——原逻辑只在前者成立时重试，
  而 MF 编码器的 fallback 选项为空，所以原来会立刻放弃。

边界：非 `*_mf` 编码器完全不受影响（尝试次数仍为 2，尺寸不改）；
钳制**只在真实打开失败之后**发生，所以支持大分辨率的 MFT（NVIDIA / Qualcomm 的 MF 编码器）不受牵连；
钳制会改变实际发出的流分辨率（2400x1080 → 1920x864），这是"可用的降级"而不是"静默错误"——日志里有 warning。

## 4. 被排除的方案

| 方案 | 为什么不选 |
|---|---|
| 改 ffmpeg（让 mfenc 在进程内长期持有平台） | Sunshine 用固定版本的 ffmpeg 构建，改它意味着维护一个 ffmpeg fork；在应用侧持有引用等价且更小 |
| 启动时"预热"一个 dummy 编码器 | 实测会话期仍会失败（预热不覆盖后续实例），且失败次数不固定，不能保证 |
| 无限重试直到成功 | 用户可能长时间看不到画面；且 2400x1080 属于**永久性**拒绝，重试再多也没用 |
| 直接把客户端分辨率限制在探测阶段拒绝 | 手机端不知道宿主能力，体验上应是"服务端降级"而不是"直接报错" |
| 用虚拟显示器/自定义分辨率绕开 1920 上限 | 上限在编码器，不在显示端；换显示器、加虚拟显示器都改变不了 |

## 5. 还没搞清楚的地方

- "打火"的确切机制（是驱动的一次性初始化？还是硬件会话的清理窗口？）没有定论；
  现在的 6 次 / 250ms 是实测调出来的参数，不是从原理推导的。
- ffmpeg CLI 首次调用就能成功，和探针/Sunshine 的表现不同，还没有逐位解释。
  可能与其他组件先创建过 MF 对象有关，但它不影响本次修复的有效性。
- 长时间稳定性（连续几十次会话的软编回退率）还在观察中。