# packaging/build_module_zip.ps1
# Assemble the one public Magisk/KSU module ZIP from the workspace. Licensed
# runtime payloads remain server-side and are excluded from this release.

param(
    [string]$Repo = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$work = Join-Path $Repo "work"
$staging = Join-Path $work "module-staging"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$moduleVersion = (Get-Content -LiteralPath (Join-Path $Repo "module.prop") |
    Where-Object { $_ -like "version=*" } |
    Select-Object -First 1).Substring("version=".Length).Trim()
if (-not $moduleVersion) { throw "module.prop is missing version" }
$zipName = "Murong.Display.Enhancement-v$moduleVersion-$stamp.zip"
$zipPath = Join-Path $work $zipName

# ---- premium / research exclusions (relative paths, forward slashes) ----
$exactExcludes = @(
    # premium_ltpo
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
    # premium_adfr
    "bin/rmx5200_adfr_lock.ko",
    "bin/pjd110_adfr_lock.ko",
    "scripts/adfr_lock.sh",
    "scripts/generic_adfr_policy.sh",
    "config/rmx5200_adfr_profile.txt",
    "config/rmx5200_adfr_commands.dtsi",
    # premium_memc
    "bin/libpwirisservicei7p.rmx5200.memc-gate.so",
    "scripts/libpwiris_memc_gate_patch.sh",
    "config/coloros/multimedia_pixelworks_apps.xml",
    "config/iris_page_i7p.stock.sha256",
    "system/odm/etc/iris_page_i7p.json",
    # stale/optional Android V4 sidecar; the installer consumes only the APK
    "bin/display_settings_hook.apk.idsig",
    # research_only
    "bin/ltpo.ko",
    # HMBIRD is DTBO-only in the current release; never ship the retired sidecar.
    "bin/hmbird.ko",
    "bin/libsdmclient.rmx5200.ltpo-timeline.so",
    "scripts/rmx5200_native_adfr.sh",
    "scripts/libsdmclient_timeline_patch.sh",
    "config/ltpo.ko.sha256"
)

$globExcludes = @(
    "bin/*probe*.ko",                       # research probes
    "bin/*qhd144*.ko",                      # rejected QHD144 experiments
    "bin/process_dts.*",                    # dev/test process_dts variants
    "bin/rate_daemon.*"                     # dev/test daemon variants
)

function Test-Excluded([string]$rel) {
    foreach ($e in $exactExcludes) { if ($rel -eq $e) { return $true } }
    foreach ($g in $globExcludes) { if ($rel -like $g) { return $true } }
    return $false
}

# ---- clean + stage module content ----
Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $staging | Out-Null

foreach ($f in @("action.sh", "customize.sh", "post-fs-data.sh", "post-mount.sh", "late-load.sh", "service.sh", "uninstall.sh", "module.prop", "KsuWebUI.apk")) {
    Copy-Item (Join-Path $Repo $f) $staging -Force
}
foreach ($d in @("META-INF", "webroot", "bin", "config", "scripts", "system")) {
    $source = Join-Path $Repo $d
    if (Test-Path -LiteralPath $source) {
        Copy-Item $source (Join-Path $staging $d) -Recurse -Force
    }
}

# ---- prune premium/research files from staging ----
$base = (Resolve-Path $staging).Path
Get-ChildItem $staging -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($base.Length + 1).Replace('\', '/')
    if (Test-Excluded $rel) { Remove-Item $_.FullName -Force }
}

# ---- zip with forward-slash entry names ----
Remove-Item $zipPath -ErrorAction SilentlyContinue
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
$count = 0
Get-ChildItem $staging -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($base.Length + 1).Replace('\', '/')
    $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
    $es = $entry.Open()
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $es.Write($bytes, 0, $bytes.Length)
    $es.Close()
    $count++
}
$zip.Dispose()

# ---- assert: no premium/research file leaked into the ZIP ----
$leaked = @()
$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
foreach ($entry in $check.Entries) {
    if (Test-Excluded $entry.FullName) { $leaked += $entry.FullName }
}
$check.Dispose()

if ($leaked.Count -gt 0) {
    throw "PUBLIC MODULE ASSERTION FAILED - private/research files leaked: $($leaked -join ', ')"
}

# ---- assert: the public Hook APK must not contain licensed hook classes ----
$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
$hookEntry = $check.Entries | Where-Object { $_.FullName -eq 'bin/display_settings_hook.apk' }
if ($hookEntry) {
    $tmpApk = Join-Path $env:TEMP "display_settings_hook.check.apk"
    $stream = $hookEntry.Open()
    $fileStream = [System.IO.File]::Create($tmpApk)
    $stream.CopyTo($fileStream)
    $fileStream.Close(); $stream.Close()
    $dexListing = ""
    try {
        $apk = [System.IO.Compression.ZipFile]::OpenRead($tmpApk)
        $dexEntries = $apk.Entries | Where-Object { $_.FullName -match '\.dex$' }
        foreach ($dex in $dexEntries) {
            $dexBytes = New-Object byte[] $dex.Length
            $s = $dex.Open(); $s.Read($dexBytes, 0, $dexBytes.Length) | Out-Null; $s.Close()
            $dexListing += [System.Text.Encoding]::ASCII.GetString($dexBytes)
        }
        $apk.Dispose()
    } catch { }
    Remove-Item $tmpApk -Force -ErrorAction SilentlyContinue
    foreach ($probe in @('NotificationLtpoHooks', 'VideoMotion', 'ColorosVideoPlayback', 'BilibiliStory')) {
        if ($dexListing.Contains($probe)) {
            throw "PUBLIC MODULE ASSERTION FAILED - licensed hook class leaked into public Hook APK: $probe"
        }
    }
}
$check.Dispose()
Write-Host "assertion: public Hook APK contains no licensed classes - PASS"

$size = (Get-Item $zipPath).Length
Write-Host "module zip: $zipPath"
Write-Host ("files staged: {0}  size: {1:N0} bytes ({2:N2} MB)" -f $count, $size, ($size / 1MB))
Write-Host "assertion: no private/research file present - PASS"
