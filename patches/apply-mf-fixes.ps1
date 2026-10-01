# Apply the Media Foundation / Intel QSV fixes to any Sunshine fork tree.
#
#   pwsh -File apply-mf-fixes.ps1 -Repo C:\src\sunshine -Check   # report only
#   pwsh -File apply-mf-fixes.ps1 -Repo C:\src\sunshine          # apply
#
# Why anchor-based instead of a unified diff: the three changes sit inside code
# that forks keep editing (Apollo and foundation-sunshine both drift around the
# anchors), so a line-based patch conflicts.  The anchors below are stable
# function-level text; the script fails loudly when one is missing instead of
# applying a wrong change.  Inserted text uses the file's existing indentation
# and LF line endings (the upstream repos are LF).
#
# Fixes:
#   1. src/video.cpp           clamp *_mf encoder requests to the 1920 px MFT
#                              limit (one retry after a failed open, aspect kept)
#   2. src/main.cpp            hold one MF platform reference for the process
#                              lifetime (mfenc's MFStartup/MFShutdown cycles must
#                              not reset the MFT's armed state)
#   3. src/platform/windows/display_vram.cpp
#                              let the Intel adapter accept *_mf codecs (1 line)
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'

function Read-Text([string]$p) { [IO.File]::ReadAllText($p) }
function Write-Text([string]$p, [string]$t) { [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($false))) }
function Count-Of([string]$t, [string]$s) { ([regex]::Matches($t, [regex]::Escape($s))).Count }
function Indent([string]$ind, [string[]]$lines) { ($lines | ForEach-Object { if ($_ -eq '') { '' } else { $ind + $_ } }) -join "`n" }
function Say([string]$file, [string]$status, [string]$detail) { "{0,-46} {1,-16} {2}" -f $file, $status, $detail }

$results = @()

# ---------------------------------------------------------------------------
# 1. src/video.cpp - clamp oversized *_mf requests to the MFT dimension limit
# ---------------------------------------------------------------------------
$f = Join-Path $Repo 'src/video.cpp'
$t = Read-Text $f
if ($t.Contains('mf_dimension_limit')) {
    $results += Say 'src/video.cpp' 'already-applied' ''
}
else {
    $rxLoop = [regex]'(?m)^(?<i>[ \t]*)for \(int retries = 0; retries < 2; retries\+\+\) \{\r?\n'
    $oldPair = "(?m)^(?<i1>[ \t]*)ctx->width = config\.width;\r?\n(?<i2>[ \t]*)ctx->height = config\.height;"
    $oldIf = 'if (!video_format.fallback_options.empty() && retries == 0) {'
    $oldLog = '<< "Retrying with fallback configuration options for ["sv << video_format.name << "] after error: "sv'
    $loop = [regex]::Match($t, $rxLoop)
    $pair = [regex]::Match($t, $oldPair)
    $anchorCounts = "loop=$([regex]::Matches($t, $rxLoop).Count) pair=$([regex]::Matches($t, $oldPair).Count) if=$(Count-Of $t $oldIf) log=$(Count-Of $t $oldLog)"
    if ($loop.Success -and $pair.Success -and (Count-Of $t $oldIf) -eq 1 -and (Count-Of $t $oldLog) -eq 1) {
        $declBlock = Indent $loop.Groups['i'].Value @(
            '// Media Foundation encoders on legacy Intel GPUs (Ivy Bridge / HD 4000 and',
            '// similar) cannot encode frames wider than 1920 pixels or taller than 1920',
            '// pixels: the MFT rejects such an output type with MF_E_INVALIDMEDIATYPE and',
            '// the encoder can never be opened.  A client asking for more (phones often',
            '// request 2400x1080) would then fail every session attempt.  When opening an',
            '// *_mf codec fails, retry with the request scaled down to the limit,',
            '// preserving the client''s aspect ratio.  The retry only engages after a real',
            '// failure, so encoders whose MFT supports larger frames are unaffected.',
            '//',
            '// MF encoders also get extra attempts: the Intel QSV MFT fails the first',
            '// SetOutputType() calls of an epoch while it arms the driver (up to three',
            '// consecutive failures were observed in a fresh process), and MF codecs',
            '// carry no fallback options that would otherwise trigger a retry.  Retries',
            '// are spaced out because the MFT is briefly unavailable right after a failed',
            '// open (back-to-back attempts fail where a short gap succeeds).',
            'constexpr int mf_dimension_limit = 1920;',
            'const bool mf_codec = video_format.name.size() > 3 && video_format.name.substr(video_format.name.size() - 3) == "_mf";',
            'const bool mf_clamp_available = mf_codec && (config.width > mf_dimension_limit || config.height > mf_dimension_limit);',
            'const int max_retries = mf_codec ? 6 : 2;',
            '',
            '// Allow up to 1 retry to apply the set of fallback options (MF encoders get',
            '// the extra attempts allocated in max_retries above).',
            '//',
            '// Note: If we later end up needing multiple sets of',
            '// fallback options, we may need to allow more retries',
            '// to try applying each set.'
        )
        $replacement = $declBlock + "`n" + $loop.Groups['i'].Value + 'for (int retries = 0; retries < max_retries; retries++) {' + "`n"
        $t2 = $t.Remove($loop.Index, $loop.Length).Insert($loop.Index, $replacement)
        $i1 = $pair.Groups['i1'].Value
        $pairBlock = Indent $i1 @(
            'if (retries > 0 && mf_clamp_available) {',
            '  const auto scale = std::min(static_cast<double>(mf_dimension_limit) / config.width, static_cast<double>(mf_dimension_limit) / config.height);',
            '  ctx->width = static_cast<int>(config.width * scale) & ~1;',
            '  ctx->height = static_cast<int>(config.height * scale) & ~1;',
            '  BOOST_LOG(warning) << video_format.name << ": requested "sv << config.width << ''x'' << config.height',
            '                     << " exceeds the "sv << mf_dimension_limit << " pixel Media Foundation encoder limit, using "sv',
            '                     << ctx->width << ''x'' << ctx->height << " instead"sv;',
            '} else {',
            '  ctx->width = config.width;',
            '  ctx->height = config.height;',
            '}'
        )
        $m2 = [regex]::Match($t2, $oldPair)
        $t2 = $t2.Remove($m2.Index, $m2.Length).Insert($m2.Index, $pairBlock)
        $rxRetry = [regex]'(?s)(?<i>[ \t]*)if \(!video_format\.fallback_options\.empty\(\) && retries == 0\) \{\r?\n.*?\r?\n(?<j>[ \t]*)continue;\r?\n(?<k>[ \t]*)\}'
        $mR = [regex]::Match($t2, $rxRetry)
        if ($mR.Success) {
            $ri = $mR.Groups['i'].Value
            $retryLines = @(
                ($ri + 'if (retries + 1 < max_retries && (!video_format.fallback_options.empty() || mf_codec)) {'),
                ($ri + '  BOOST_LOG(info)'),
                ($ri + '    << "Retrying "sv << video_format.name << " (attempt "sv << (retries + 2) << ''/'' << max_retries'),
                ($ri + '    << ") after error: "sv'),
                ($ri + '    << av_make_error_string(err_str, AV_ERROR_MAX_STRING_SIZE, status);'),
                '',
                ($ri + '  // The MFT is briefly unavailable right after a failed open: wait a'),
                ($ri + '  // moment instead of retrying back-to-back.'),
                ($ri + '  std::this_thread::sleep_for(250ms);'),
                '',
                ($mR.Groups['j'].Value + 'continue;'),
                ($mR.Groups['k'].Value + '}')
            )
            $t2 = $t2.Remove($mR.Index, $mR.Length).Insert($mR.Index, [string]::Join([string][char]10, $retryLines))
        }
        else {
            $results += Say 'src/video.cpp' 'warn' 'retry branch not rewritten'
        }
        if (-not $Check) { Write-Text $f $t2 }
        $results += Say 'src/video.cpp' $(if ($Check) { 'would-apply' } else { 'applied' }) ''
    }
    else {
        $results += Say 'src/video.cpp' 'anchor-missing' $anchorCounts
    }
}

# ---------------------------------------------------------------------------
# 2. src/main.cpp - hold one MF platform reference for the process lifetime
# ---------------------------------------------------------------------------
$f = Join-Path $Repo 'src/main.cpp'
$t = Read-Text $f
if ($t.Contains('mf_platform_held')) {
    $results += Say 'src/main.cpp' 'already-applied' ''
}
else {
    $rxMain = [regex]'(?m)^(?<i>[ \t]*)(?:int[ \t]+)?main\(int argc, char \*argv\[\]\) \{\r?\n'
    $m = [regex]::Match($t, $rxMain)
    if (-not $m.Success) {
        $results += Say 'src/main.cpp' 'anchor-missing' 'main() entry not found'
    }
    else {
        $bodyIndent = $m.Groups['i'].Value + '  '
        $block = "#ifdef _WIN32`n" + (Indent $bodyIndent @(
            '// Hold a Media Foundation platform reference for the lifetime of the process.',
            '//',
            '// The Intel QSV H.264 encoder MFT (Ivy Bridge and similar) fails the first',
            '// IMFTransform::SetOutputType() calls of every MFStartup() epoch with',
            '// MF_E_INVALIDMEDIATYPE; those calls only arm the driver.  FFmpeg''s mfenc',
            '// wraps every encoder open in MFStartup()/MFShutdown(), so every open would',
            '// otherwise start a fresh epoch and the hardware encoder could never open.',
            '{',
            '  static bool mf_platform_held = false;',
            '  if (!mf_platform_held) {',
            '    mf_platform_held = true;',
            '    if (auto mfplat = LoadLibraryW(L"mfplat.dll")) {',
            '      using mf_startup_t = long(__stdcall *)(unsigned long, unsigned long);',
            '      if (auto mf_startup = reinterpret_cast<mf_startup_t>(GetProcAddress(mfplat, "MFStartup"))) {',
            '        mf_startup(0x20070 /* MF_VERSION */, 0 /* MFSTARTUP_FULL */);',
            '      }',
            '    }',
            '  }',
            '}'
        )) + "`n#endif`n"
        $t2 = $t.Insert($m.Index + $m.Length, $block + "`n")
        if (-not $Check) { Write-Text $f $t2 }
        $results += Say 'src/main.cpp' $(if ($Check) { 'would-apply' } else { 'applied' }) ''
    }
}

# ---------------------------------------------------------------------------
# 3. src/platform/windows/display_vram.cpp - Intel adapter accepts *_mf codecs
# ---------------------------------------------------------------------------
$f = Join-Path $Repo 'src/platform/windows/display_vram.cpp'
$t = Read-Text $f
$old = 'if (!boost::algorithm::ends_with(name, "_qsv")) {'
if ($t.Contains('ends_with(name, "_mf")')) {
    $results += Say 'src/platform/windows/display_vram.cpp' 'already-applied' ''
}
elseif ((Count-Of $t $old) -ne 1) {
    $results += Say 'src/platform/windows/display_vram.cpp' 'anchor-missing' "qsv check x$((Count-Of $t $old))"
}
else {
    $t2 = $t.Replace($old, 'if (!boost::algorithm::ends_with(name, "_qsv") && !boost::algorithm::ends_with(name, "_mf")) {')
    if (-not $Check) { Write-Text $f $t2 }
    $results += Say 'src/platform/windows/display_vram.cpp' $(if ($Check) { 'would-apply' } else { 'applied' }) ''
}

# ---------------------------------------------------------------------------
# 4. src/video.cpp - add the Media Foundation encoder entry (forks that dropped it)
#
# Some forks removed the MF encoder entirely (foundation-sunshine ships without a
# single *_mf codec), so fixes 1-3 would have nothing to drive.  This inserts the
# encoder definition and registers it in the encoder list.  Forks that still have
# it (upstream Sunshine, Apollo) are detected and skipped.
# ---------------------------------------------------------------------------
$f = Join-Path $Repo 'src/video.cpp'
$t = Read-Text $f
if ($t.Contains('mediafoundation')) {
    $results += Say 'src/video.cpp (MF encoder)' 'already-applied' ''
}
else {
    $listOld = "#ifdef _WIN32`n    &quicksync,`n    &amdvce,`n#endif"
    $defAnchor = '  encoder_t software {'
    if ((Count-Of $t $listOld) -ne 1 -or (Count-Of $t $defAnchor) -ne 1) {
        $results += Say 'src/video.cpp (MF encoder)' 'anchor-missing' "list=$(Count-Of $t $listOld) def=$(Count-Of $t $defAnchor)"
    }
    else {
        $def = @(
            '#ifdef _WIN32',
            '  /**',
            '   * @brief Media Foundation (Windows).',
            '   *',
            '   * On legacy Intel GPUs (Ivy Bridge / HD 4000 and similar) this is the only',
            '   * working hardware path: oneVPL refuses those generations, while the Intel',
            '   * Media Foundation H.264 MFT is still shipped by the driver.',
            '   */',
            '  encoder_t mediafoundation {',
            '    "mediafoundation"sv,',
            '    std::make_unique<encoder_platform_formats_avcodec>(',
            '      AV_HWDEVICE_TYPE_D3D11VA,',
            '      AV_HWDEVICE_TYPE_NONE,',
            '      AV_PIX_FMT_D3D11,',
            '      AV_PIX_FMT_NV12,  // SDR 4:2:0 8-bit',
            '      AV_PIX_FMT_NONE,  // No HDR - the MF MFT only takes 8-bit',
            '      AV_PIX_FMT_NONE,  // No YUV444 SDR',
            '      AV_PIX_FMT_NONE,  // No YUV444 HDR',
            '      dxgi_init_avcodec_hardware_input_buffer',
            '    ),',
            '    {',
            '      // Common options for AV1',
            '      {',
            '        {"hw_encoding"s, 1},',
            '        {"rate_control"s, "cbr"s},',
            '        {"scenario"s, "display_remoting"s},',
            '      },',
            '      {},  // SDR-specific options',
            '      {},  // HDR-specific options',
            '      {},  // YUV444 SDR-specific options',
            '      {},  // YUV444 HDR-specific options',
            '      {},  // Fallback options',
            '      "av1_mf"s,',
            '      {},  // capabilities',
            '    },',
            '    {',
            '      // Common options for HEVC',
            '      {',
            '        {"hw_encoding"s, 1},',
            '        {"rate_control"s, "cbr"s},',
            '        {"scenario"s, "display_remoting"s},',
            '      },',
            '      {},  // SDR-specific options',
            '      {},  // HDR-specific options',
            '      {},  // YUV444 SDR-specific options',
            '      {},  // YUV444 HDR-specific options',
            '      {},  // Fallback options',
            '      "hevc_mf"s,',
            '      {},  // capabilities',
            '    },',
            '    {',
            '      // Common options for H.264',
            '      {',
            '        {"hw_encoding"s, 1},',
            '        {"rate_control"s, "cbr"s},',
            '        {"scenario"s, "display_remoting"s},',
            '      },',
            '      {},  // SDR-specific options',
            '      {},  // HDR-specific options',
            '      {},  // YUV444 SDR-specific options',
            '      {},  // YUV444 HDR-specific options',
            '      {},  // Fallback options',
            '      "h264_mf"s,',
            '      {},  // capabilities',
            '    },',
            '    PARALLEL_ENCODING',
            '  };',
            '#endif',
            ''
        ) -join "`n"
        $t2 = $t.Replace($defAnchor, $def + $defAnchor)
        $t2 = $t2.Replace($listOld, $listOld.Replace('#endif', "    &mediafoundation,`n#endif"))
        if (-not $Check) { Write-Text $f $t2 }
        $results += Say 'src/video.cpp (MF encoder)' $(if ($Check) { 'would-apply' } else { 'applied' }) ''
    }
}

$results
''
"repo: $Repo   mode: $(if ($Check) { 'check only' } else { 'applied' })"
if ($Check) { ''; 're-run without -Check to apply' }