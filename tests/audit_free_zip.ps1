param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot),
    [string]$ZipPath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $ZipPath) {
    $latest = Get-ChildItem -LiteralPath (Join-Path $Repo "work") -File `
        -Filter "Murong.Display.Enhancement-v*.zip" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        throw "No public module ZIP found below work/."
    }
    $ZipPath = $latest.FullName
}

$ZipPath = (Resolve-Path -LiteralPath $ZipPath).Path
# Keep the public archive audit independent of the private component manifest.
# These are runtime paths excluded by packaging/build_module_zip.ps1, including
# native library variants added by later firmware adaptations.
$privatePaths = @(
    "bin/rmx5200_ltpo_modes.ko",
    "bin/rmx5200_ltpo_activity.ko",
    "bin/surfaceflinger.rmx5200.ltpo-oti",
    "bin/surfaceflinger.rmx5200.ltpo-rise",
    "scripts/rmx5200_ltpo_experiment.sh",
    "scripts/rmx5200_ltpo_activity.sh",
    "scripts/surfaceflinger_vote_patch.sh",
    "scripts/surfaceflinger_ltpo_rise_patch.sh",
    "config/rmx5200_ltpo_modes.sha256",
    "config/rmx5200_ltpo_activity.sha256",
    "scripts/adfr_lock.sh",
    "scripts/generic_adfr_policy.sh",
    "scripts/geometry_density.sh",
    "config/rmx5200_adfr_profile.txt",
    "config/rmx5200_adfr_commands.dtsi",
    "scripts/libpwiris_memc_gate_patch.sh",
    "config/coloros/multimedia_pixelworks_apps.xml",
    "config/iris_page_i7p.stock.sha256",
    "system/odm/etc/iris_page_i7p.json",
    "bin/ltpo.ko",
    "bin/hmbird.ko",
    "bin/libsdmclient.rmx5200.ltpo-timeline.so",
    "scripts/rmx5200_native_adfr.sh",
    "scripts/libsdmclient_timeline_patch.sh",
    "config/ltpo.ko.sha256"
)
$privatePatterns = @(
    "premium/*",
    "packaging/*",
    "src/*",
    "hooks/*",
    "bin/libpwirisservice*.so",
    "system/*/libpwirisservice*.so",
    "bin/*_adfr_lock.ko",
    "bin/rate_daemon_premium*",
    "bin/display_premium_hook.apk*",
    "bin/*.device"
)

function Test-PrivatePath([string]$Path) {
    if ($Path -in $privatePaths) { return $true }
    foreach ($pattern in $privatePatterns) {
        if ($Path -like $pattern) { return $true }
    }
    return $false
}

function Get-EntryBytes([System.IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    $memory = New-Object System.IO.MemoryStream
    try {
        $stream.CopyTo($memory)
        return $memory.ToArray()
    } finally {
        $stream.Dispose()
        $memory.Dispose()
    }
}

function Get-EntryAscii([System.IO.Compression.ZipArchiveEntry]$Entry) {
    $bytes = Get-EntryBytes $Entry
    return [System.Text.Encoding]::ASCII.GetString($bytes)
}

$archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName })
    $requiredFreePaths = @(
        "post-fs-data.sh",
        "bin/process_dts",
        "bin/process_dts.src.sha256",
        "bin/rmx5200_drm_modes.ko",
        "bin/plk110_drm_modes.ko",
        "bin/pjd110_drm_modes.ko",
        "bin/display_settings_hook.apk",
        "bin/display_settings_hook.apk.idsig",
        "config/display_mode_manifest.txt",
        "scripts/display_backend.sh",
        "scripts/hmbird_backend.sh",
        "scripts/mode_manifest.sh",
        "scripts/surfaceflinger_ltps_vote_patch.sh"
    )
    $missingFreePaths = @($requiredFreePaths | Where-Object { $_ -notin $entries })
    if ($missingFreePaths.Count -gt 0) {
        throw "Free package is missing required DRM/HMBIRD runtime files: $($missingFreePaths -join ', ')"
    }
    $pathLeaks = @(
        $entries | Where-Object {
            Test-PrivatePath $_
        }
    )
    $researchLeaks = @(
        $entries | Where-Object {
            $_ -like "bin/*probe*.ko" -or
            $_ -like "bin/*qhd144*.ko" -or
            ($_ -like "bin/process_dts.*" -and $_ -ne "bin/process_dts.src.sha256") -or
            $_ -like "bin/rate_daemon.*"
        }
    )
    $retiredHmbirdLeaks = @(
        $entries | Where-Object { $_ -eq "bin/hmbird.ko" }
    )

    $daemonEntry = $archive.Entries | Where-Object { $_.FullName -eq "bin/rate_daemon" }
    if (-not $daemonEntry) {
        throw "Free package has no bin/rate_daemon."
    }
    $daemonText = Get-EntryAscii $daemonEntry
    $daemonMarkers = @(
        "premium_enabled",
        "premium_features",
        "rmx5200_ltpo_modes",
        "rmx5200_ltpo_activity",
        "video_memc"
    ) | Where-Object { $daemonText.Contains($_) }

    $hookEntry = $archive.Entries | Where-Object {
        $_.FullName -eq "bin/display_settings_hook.apk"
    }
    if (-not $hookEntry) {
        throw "Free package has no bin/display_settings_hook.apk."
    }
    $hookBytes = Get-EntryBytes $hookEntry
    $hookMemory = New-Object System.IO.MemoryStream(, $hookBytes)
    $hookArchive = New-Object System.IO.Compression.ZipArchive(
        $hookMemory,
        [System.IO.Compression.ZipArchiveMode]::Read,
        $false
    )
    try {
        $hookText = ""
        foreach ($dex in $hookArchive.Entries | Where-Object { $_.FullName -match "[.]dex$" }) {
            $hookText += Get-EntryAscii $dex
        }
    } finally {
        $hookArchive.Dispose()
        $hookMemory.Dispose()
    }
    $hookMarkers = @(
        "PremiumDisplayHook",
        "PremiumServiceHooks",
        "NotificationLtpoHooks",
        "VideoMotionHooks",
        "VideoMotionServiceHooks",
        "ColorosVideoPlaybackHooks",
        "BilibiliStoryHooks"
    ) | Where-Object { $hookText.Contains($_) }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$size = (Get-Item $ZipPath).Length
Write-Host "free zip: $ZipPath"
Write-Host "files: $($entries.Count)"
Write-Host "bytes: $size"
Write-Host "sha256: $hash"

$failures = @($pathLeaks) + @($researchLeaks) + @($retiredHmbirdLeaks) + @($daemonMarkers) + @($hookMarkers)
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error "Private/research leak: $_" }
    exit 1
}

Write-Host "assertion: private component paths absent - PASS"
Write-Host "assertion: research artifacts absent - PASS"
Write-Host "assertion: free daemon premium markers absent - PASS"
Write-Host "assertion: free Hook premium classes absent - PASS"
Write-Host "INDEPENDENT FREE ZIP AUDIT PASS"
