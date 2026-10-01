# Media Foundation / Intel QSV 修复补丁集

面向 Sunshine 及其 fork（Apollo、foundation-sunshine 等）的三处小改动，用于让**老 Intel 核显（Ivy Bridge / HD 4000 等）通过 Media Foundation（`h264_mf`）真正跑起硬件编码**。

## 三处改动

| # | 文件 | 内容 | 性质 |
|---|---|---|---|
| 1 | `src/video.cpp` | `*_mf` 编解码器：请求超过 **1920 px** 时按比例钳制；最多尝试 **6** 次、失败间隔 **250ms**（吸收 MFT"打火"） | 平台无关，通用 |
| 2 | `src/main.cpp` | 进程启动时持有一个 MF 平台引用，使 mfenc 的 `MFStartup`/`MFShutdown` 循环不会重置 MFT 的"已打火"状态 | Windows，通用 |
| 3 | `src/platform/windows/display_vram.cpp` | Intel adapter 的能力白名单放行 `*_mf`（1 行） | Intel 特例 |
| 4 | `src/video.cpp` | 给**删掉了 MF 编码器的 fork**（如 foundation-sunshine）补回 `mediafoundation` 编码器定义并注册进编码器列表；已有它的 fork（上游、Apollo）会自动跳过 | 仅对缺 MF 的 fork 生效 |

## 本机实测结论（ThinkPad E531 / HD 4000 / 驱动 10.18.10.5161）

- **每条边 ≤ 1920 是硬上限**：1280x720…1920x1200 通过；2048x1080、2400x1080（含 30fps）、2560x1440、3840x2160 全部被 `MF_E_INVALIDMEDIATYPE` 拒收。
- **码率无语义限制**：1920x1080@60 下 1–120 Mbps 全部接受（此前 47 Mbps 失败是分辨率导致）。
- 每纪元前几次 `SetOutputType` 会失败（"打火"），需要 1–3 次重试；持有 MF 引用后重试可成功（720p/1080p 会话实测出帧）。
- **"打火"失败非确定**：新构建实测 7 次打开 / 5 次失败，探测阶段出现过**连续 2 次失败**（原 2 次上限因此回退软编）。所以把 `*_mf` 的上限提到 **6** 次并在失败间加 **250ms** 间隔（日志显示失败→成功间隔约 300ms，像是"忙/清理"窗口）。

## 用法

```powershell
# 只检查（不改文件）
pwsh -File apply-mf-fixes.ps1 -Repo C:\src\sunshine -Check

# 应用
pwsh -File apply-mf-fixes.ps1 -Repo C:\src\sunshine
```

输出示例（每个文件一行：`applied` / `already-applied` / `anchor-missing`）：

```
src/video.cpp                                  applied
src/main.cpp                                   applied
src/platform/windows/display_vram.cpp          applied
```

脚本**幂等**（重复运行报 `already-applied`），并在锚点缺失时**大声失败**而不是打错位置。

### 为什么不用 unified diff

同一份 `.patch` 在 Apollo / foundation-sunshine 上都会因上下文漂移冲突（锚点函数都在，但周边行已变）。实测：

```
0001-video-clamp-mf-resolution.patch -> ap : CONFLICT
0002-main-hold-mf-platform.patch     -> ap : CONFLICT
0003-display-vram-allow-mf-codec.patch -> ap : APPLIES CLEAN
0001/0002/0003 -> foundation-sunshine : CONFLICT / CONFLICT / CONFLICT
```

`apply-mf-fixes.ps1` 改为**锚点匹配 + 原缩进/原换行（LF）插入**，已在两个 fork 上验证：三处全部 `applied`，重跑全部 `already-applied`，生成结果与手工补丁逐行等价（仅注释措辞不同）。

目录里的 `000N-*.patch` 仍保留，它们是针对 `Ginsengyard/Sunshine` 基线的精确 diff，可直接 `git apply -p1`。

## 随上游更新维护

1. **同步上游**：`git fetch upstream && git rebase upstream/master`（或 merge）。
2. **重新应用**：`pwsh -File apply-mf-fixes.ps1 -Repo . -Check` → 若三个文件都是 `already-applied`，说明上游已合并（到此可删本目录）；若出现 `anchor-missing`，说明上游改了那三处结构，需人工确认后再改锚点。
3. **自动构建**：CI 里跑一次 Windows 构建（本仓库用 `.github/workflows/ci-windows-mf.yml` 包装上游 reusable workflow），确保可发布产物始终存在。
4. **长期方案**：把改动 #1/#2 提回上游（见 `UPSTREAM-PR.md`），则所有 fork 自动继承，维护成本归零。

## 目录内容

- `apply-mf-fixes.ps1` — 锚点式应用脚本（推荐入口）
- `0001-video-clamp-mf-resolution.patch` / `0002-main-hold-mf-platform.patch` / `0003-display-vram-allow-mf-codec.patch` — 针对本项目基线的精确 diff
- `UPSTREAM-PR.md` — 上游 PR 描述草稿（含实测证据链）
- `tree/` — 生成 patch 时使用的 base/new 源文件树（可删）