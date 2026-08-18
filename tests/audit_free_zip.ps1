param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot),
    [string]$ZipPath = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $ZipPath) {
    $latest = Get-ChildItem (Join-Path $Repo "work\murongchaopin-free-*.zip") |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        throw "No free package found below work/."
    }
    $ZipPath = $latest.FullName
}

$ZipPath = (Resolve-Path $ZipPath).Path
$manifestPath = Join-Path $Repo "packaging\feature-components.json"
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$allowedPublicPolicyFiles = @("config/rmx5200_adfr_mode.txt")
$privatePaths = @(
    $manifest.categories |
        Where-Object { -not $_.public_package -and $_.id -ne "split_required" } |
        ForEach-Object { $_.components.path } |
        Where-Object { $_ -notin $allowedPublicPolicyFiles }
)

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
        "bin/rmx5200_drm_modes.ko",
        "bin/plk110_drm_modes.ko",
        "bin/pjd110_drm_modes.ko",
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
            $_ -in $privatePaths -or
            $_ -like "premium/*" -or
            $_ -like "packaging/*" -or
            $_ -like "src/*"
        }
    )
    $researchLeaks = @(
        $entries | Where-Object {
            $_ -like "bin/*probe*.ko" -or
            $_ -like "bin/*qhd144*.ko" -or
            $_ -like "bin/process_dts.*" -or
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
