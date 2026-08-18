param(
    [string]$Serial = "192.168.2.4:5555",
    [string]$OutputDir = "work/rmx5200-memc-120-vs-144-compare"
)

$ErrorActionPreference = "Stop"
$Package = "com.ss.android.ugc.aweme"
$TargetKey = "murong_video_motion_target_rate"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Output = Join-Path $Root $OutputDir
New-Item -ItemType Directory -Force -Path $Output | Out-Null

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & adb -s $Serial @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed: $($Arguments -join ' ')"
    }
}

function Capture-State {
    param([string]$Name)
    Invoke-Adb shell "settings get secure $TargetKey" |
        Set-Content -Encoding ascii (Join-Path $Output "$Name-target.txt")
    $ProbeOutput = foreach ($Parameter in (Invoke-Adb shell "ls /sys/module/rmx5200_iris_memc_probe/parameters")) {
        $Parameter = $Parameter.Trim()
        if ($Parameter) {
            $Value = (Invoke-Adb shell "cat /sys/module/rmx5200_iris_memc_probe/parameters/$Parameter").Trim()
            "$Parameter=$Value"
        }
    }
    $ProbeOutput | Set-Content -Encoding ascii (Join-Path $Output "$Name-probe.txt")
    Invoke-Adb shell su -c "dmesg | grep rmx5200_iris_memc_probe" |
        Set-Content -Encoding ascii (Join-Path $Output "$Name-dmesg.txt")
    Invoke-Adb shell "logcat -d -v threadtime | grep -E 'OplusFeatureMEMC|IrisService|IRIS_SERVICE_MODE|MEMC_CTRL|MemcMode|SingleMemc|ratio-' | tail -n 2000" |
        Set-Content -Encoding utf8 (Join-Path $Output "$Name-logcat.txt")
    Invoke-Adb shell "dumpsys SurfaceFlinger | grep -E 'activeMode|fps=|refreshRate|Iris7|Memc' | head -n 500" |
        Set-Content -Encoding utf8 (Join-Path $Output "$Name-surfaceflinger.txt")
}

$OriginalTarget = (Invoke-Adb shell "settings get secure $TargetKey").Trim()
if ($OriginalTarget -notmatch '^[0-9]+$') {
    $OriginalTarget = "120"
}

try {
    Capture-State "120-baseline"
    Invoke-Adb logcat -c
    Invoke-Adb shell "settings put secure $TargetKey 144"
    Invoke-Adb shell "am force-stop $Package"
    Invoke-Adb shell "monkey -p $Package -c android.intent.category.LAUNCHER 1" | Out-Null
    Start-Sleep -Seconds 7
    Capture-State "144-observed"
}
finally {
    Invoke-Adb shell "am force-stop $Package"
    Invoke-Adb shell "settings put secure $TargetKey $OriginalTarget"
    Invoke-Adb shell "monkey -p $Package -c android.intent.category.LAUNCHER 1" | Out-Null
    Start-Sleep -Seconds 2
    Capture-State "restored-$OriginalTarget"
}

Get-ChildItem -LiteralPath $Output | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash.ToLowerInvariant())  $($_.Path.Substring($Output.Length + 1))" } |
    Set-Content -Encoding ascii (Join-Path $Output "SHA256SUMS.txt")

Write-Output $Output
