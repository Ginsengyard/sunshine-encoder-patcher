# 查看 Sunshine 最近几次串流实际使用的编码器（硬编 / 软编）。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File check-encoder.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File check-encoder.ps1 -Log <sunshine.log> -Count 15
#
# 也可直接双击同目录的 check-encoder.cmd。
#
# 判据来自日志中的 "Found H.264 encoder: <name> [<platform>]"（每次串流前都会写一条）。
param(
    [string]$Log,
    [int]$Count = 10
)

function Find-SunshineLog {
    $roots = @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent)) | Where-Object { $_ }
    foreach ($r in $roots) {
        $hit = Get-ChildItem (Join-Path $r 'mfb_fix*\Sunshine\config\sunshine.log') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $pf = Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.log'
    if (Test-Path $pf) { return $pf }
    return $null
}

if (-not $Log) { $Log = Find-SunshineLog }
if (-not $Log -or -not (Test-Path $Log)) {
    Write-Host "找不到 sunshine.log，请用 -Log <路径> 指定。" -ForegroundColor Red
    exit 1
}

$rxLine = [regex]'^\[(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+\]:\s*(?<lvl>\w+):\s*(?<msg>.*)$'
$rxFound = [regex]'Found H\.264 encoder: (?<name>\S+) \[(?<plat>\S+)\]'

$events = New-Object System.Collections.ArrayList
$lines = $null
try {
    # Sunshine 运行中会一直持有日志文件，Get-Content 的共享模式可以正常读取。
    $lines = Get-Content -LiteralPath $Log -ErrorAction Stop
}
catch {
    Write-Host "无法读取日志（可能被占用）：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '可以先停掉 Sunshine，或用 -Log 指定 sunshine.log.1 等历史文件。' -ForegroundColor DarkGray
    exit 1
}
foreach ($line in $lines) {
    $m = $rxLine.Match($line)
    if (-not $m.Success) { continue }
    $ts = $m.Groups['ts'].Value
    $msg = $m.Groups['msg'].Value
    $f = $rxFound.Match($msg)
    if ($f.Success) {
        [void]$events.Add([pscustomobject]@{ Ts = $ts; Kind = 'encoder'; Name = $f.Groups['name'].Value; Plat = $f.Groups['plat'].Value })
    }
    elseif ($msg -match '^CLIENT CONNECTED') { [void]$events.Add([pscustomobject]@{ Ts = $ts; Kind = 'connected' }) }
    elseif ($msg -match '^CLIENT DISCONNECTED') { [void]$events.Add([pscustomobject]@{ Ts = $ts; Kind = 'disconnected' }) }
}

$sessions = New-Object System.Collections.ArrayList
$pending = $null
for ($i = 0; $i -lt $events.Count; $i++) {
    $e = $events[$i]
    if ($e.Kind -eq 'encoder') {
        $pending = $e
        continue
    }
    if ($pending) {
        $window = if ($e.Kind -eq 'connected') { "连接 $($e.Ts.Substring(11))" } else { "断开 $($e.Ts.Substring(11))" }
        [void]$sessions.Add([pscustomobject]@{ Ts = $pending.Ts; Name = $pending.Name; Plat = $pending.Plat; Window = $window })
        $pending = $null
    }
}

$last = $events | Select-Object -Last 1
$inSession = $last -and $last.Kind -eq 'connected'

function Verdict($name, $plat) {
    if ($plat -eq 'software' -or $name -match 'libx264|libx265|libsvtav1|libaom') { return @{ Text = '软编'; Color = 'Yellow' } }
    if ($plat -match 'mediafoundation' -and $name -match '_mf$') { return @{ Text = '硬编 (MF)'; Color = 'Green' } }
    if ($plat -match 'nvenc|quicksync|amf|videotoolbox|vaapi|vulkan') { return @{ Text = '硬编'; Color = 'Green' } }
    return @{ Text = '未知'; Color = 'Gray' }
}

Write-Host ''
Write-Host "Sunshine 编码器检查   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "日志：$Log"
if ($inSession) { Write-Host "状态：当前有会话进行中（$($last.Ts.Substring(11)) 起）" -ForegroundColor Cyan }
Write-Host ''

if (-not $sessions.Count) {
    Write-Host '日志里还没有串流记录（每次串流开始时会写一行 "Found H.264 encoder: ..."）。' -ForegroundColor DarkGray
    exit 0
}

$recent = @($sessions | Select-Object -Last $Count)
$hw = @($recent | Where-Object { (Verdict $_.Name $_.Plat).Text -like '硬编*' }).Count
$sw = $recent.Count - $hw

Write-Host ("近 {0} 次会话：硬编 {1} / 软编 {2}" -f $recent.Count, $hw, $sw) -ForegroundColor $(if ($sw -eq 0) { 'Green' } else { 'Yellow' })
if ($sessions.Count -gt $recent.Count) {
    Write-Host ("（本文件里共有 {0} 次会话记录；Sunshine 会轮转日志，更早的看 sunshine.log.1 / .2）" -f $sessions.Count) -ForegroundColor DarkGray
}
Write-Host ''

'{0,-20} {1,-10} {2,-17} {3,-8} {4}' -f '时间', '编码器', '平台', '判定', '会话' | Write-Host -ForegroundColor DarkGray
foreach ($s in $recent) {
    $v = Verdict $s.Name $s.Plat
    Write-Host ('{0,-20} {1,-10} {2,-17} ' -f $s.Ts, $s.Name, $s.Plat) -NoNewline
    Write-Host ('{0,-8} ' -f $v.Text) -NoNewline -ForegroundColor $v.Color
    Write-Host $s.Window
}

$lastSession = $sessions | Select-Object -Last 1
$lastVerdict = Verdict $lastSession.Name $lastSession.Plat
Write-Host ''
Write-Host ("最近一次（{0}）：{1} — {2}" -f $lastSession.Ts, $lastSession.Name, $lastVerdict.Text) -ForegroundColor $lastVerdict.Color
if ($lastVerdict.Text -like '软编*') {
    Write-Host '提示：断开重连即可让 Sunshine 重新探测编码器（多数情况下第二次会拿到硬件编码器）。' -ForegroundColor Yellow
}
Write-Host ''