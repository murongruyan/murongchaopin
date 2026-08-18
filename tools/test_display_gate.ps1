# test_display_gate.ps1 - build gate fixtures and run the on-device gate test.
# Requires: adb (device 192.168.2.4:5555), node, WSL (python3 for zip variants).
param(
    [string]$Device = "192.168.2.4:5555",
    # Avoid a hard-coded non-ASCII path: Windows PowerShell 5.1 reads UTF-8
    # scripts without a BOM as ANSI, while $PSScriptRoot is supplied by the host.
    [string]$Repo = ([System.IO.Directory]::GetParent($PSScriptRoot).FullName),
    [string]$LeaseSeedPath = $env:DISPLAY_LEASE_PRIVATE_KEY_FILE,
    [string]$PackageSeedPath = $env:DISPLAY_PACKAGE_PRIVATE_KEY_FILE,
    [string]$LeaseKeyId = $env:DISPLAY_LEASE_KEY_ID,
    [string]$PackageKeyId = $env:DISPLAY_PACKAGE_KEY_ID
)
$ErrorActionPreference = "Stop"
$adb = "C:\android-ndk-r27d-windows\huanjing\platform-tools\adb.exe"
$work = Join-Path $Repo "work\gatetest-20260816"
$cases = Join-Path $work "cases"
$chunks = Join-Path $work "chunks"
$payload = Join-Path $work "payload"
$staging = Join-Path $work "staging"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $cases, $chunks, $payload, $staging | Out-Null

if ([string]::IsNullOrWhiteSpace($LeaseSeedPath)) {
    $LeaseSeedPath = Join-Path $Repo "tools\keys\dev-lease-private.hex"
}
if ([string]::IsNullOrWhiteSpace($PackageSeedPath)) {
    $PackageSeedPath = Join-Path $Repo "tools\keys\dev-package-private.hex"
}
if (-not (Test-Path -LiteralPath $LeaseSeedPath -PathType Leaf)) { throw "lease signing key not found: $LeaseSeedPath" }
if (-not (Test-Path -LiteralPath $PackageSeedPath -PathType Leaf)) { throw "package signing key not found: $PackageSeedPath" }

function Derive-PublicKey([string]$SeedPath) {
    $seed = (Get-Content -LiteralPath $SeedPath -Raw).Trim()
    if ($seed -notmatch '^[0-9a-fA-F]{64}$') { throw "invalid Ed25519 seed: $SeedPath" }
    $script = @'
const {createPrivateKey,createPublicKey}=require('node:crypto');
const seed=Buffer.from(process.argv[1],'hex');
const prefix=Buffer.from('302e020100300506032b657004220420','hex');
const key=createPrivateKey({key:Buffer.concat([prefix,seed]),format:'der',type:'pkcs8'});
process.stdout.write(createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32).toString('hex'));
'@
    return (& node -e $script $seed).Trim()
}
if ([string]::IsNullOrWhiteSpace($LeaseKeyId)) { $LeaseKeyId = 'dev-lease-2026-08' }
if ([string]::IsNullOrWhiteSpace($PackageKeyId)) { $PackageKeyId = 'dev-package-2026-08' }
$leasePublicKey = Derive-PublicKey $LeaseSeedPath
$packagePublicKey = Derive-PublicKey $PackageSeedPath

# 1. device hash for this device (SN resolved by the gate itself; compute the
#    expected hash from the SN the gate will read)
$sn = (& $adb -s $Device shell "getprop ro.serialno").Trim()
$deviceHash = (& node -e "const c=require('crypto');process.stdout.write(c.createHash('sha256').update(process.argv[1].toLowerCase()).digest('hex'))" $sn)
Write-Host "device SN=$sn hash=$deviceHash"

# 2. test leases
$seed = (Get-Content -LiteralPath $LeaseSeedPath -Raw).Trim()
foreach ($case in @("valid", "grace", "expired", "tampered", "wrong-device", "noltpo")) {
    $out = Join-Path $cases "lease-$case.json"
    $b64 = (& node (Join-Path $Repo "tools\keys\gen_test_lease.mjs") $seed $deviceHash $case $out $LeaseKeyId).Trim()
    if ($case -eq "valid") {
        [System.IO.File]::WriteAllText((Join-Path $cases "lease-valid.b64"), $b64 + "`n")
    }
}

# 3. test payload + signed packages
New-Item -ItemType Directory -Force -Path (Join-Path $payload "scripts"), (Join-Path $payload "bin"), (Join-Path $payload "ko"), (Join-Path $payload "hooks") | Out-Null
Set-Content -Path (Join-Path $payload "scripts\premium_test.sh") -Value "#!/system/bin/sh`n# dummy premium payload for gate tests`n" -Encoding ascii
Set-Content -Path (Join-Path $payload "bin\premium_dummy") -Value "premium-bin" -Encoding ascii
Set-Content -Path (Join-Path $payload "ko\premium.ko") -Value "premium-ko" -Encoding ascii
Set-Content -Path (Join-Path $payload "hooks\premium.apk") -Value "premium-apk" -Encoding ascii

$pkgSeed = (Get-Content -LiteralPath $PackageSeedPath -Raw).Trim()
$manifestArgs = @(
    (Join-Path $Repo "tools\build_package.mjs"),
    "--payload", $payload,
    "--out", $staging,
    "--version", "1.0.0",
    "--version-code", "1",
    "--feature-code", "display_premium",
    "--min-base", "2.8",
    "--models", "RMX5200",
    "--socs", "SM8850",
    "--kernels", "6.12",
    "--backends", "drm",
    "--channel", "stable",
    "--key-seed", $pkgSeed,
    "--key-id", $PackageKeyId
)
& node @manifestArgs | Out-Host
if ($LASTEXITCODE -ne 0) { throw "manifest build failed" }

# 4. zip variants via WSL python3 (handles symlinks deterministically)
$wslStaging = ($staging -replace '\\', '/' -replace '^C:', '/mnt/c')
$wslWork = ($work -replace '\\', '/' -replace '^C:', '/mnt/c')
$wslRepo = ($Repo -replace '\\', '/' -replace '^C:', '/mnt/c')
$okZip = Join-Path $cases "pkg-ok.zip"
$badZip = Join-Path $cases "pkg-badfile.zip"
$symZip = Join-Path $cases "pkg-symlink.zip"
$extraZip = Join-Path $cases "pkg-extra.zip"
$badStaging = Join-Path $work "staging-bad"
$extraStaging = Join-Path $work "staging-extra"
$extraTarget = Join-Path $work "extra"

$wslScript = @"
set -e
cd '$wslWork'
python3 '$wslRepo/tools/make_package_zip.py' '$wslStaging' '$($okZip -replace '\\','/' -replace '^C:','/mnt/c')'
rm -rf staging-bad staging-extra extra
cp -r staging staging-bad
cp -r staging staging-extra
printf 'TAMPERED' >> staging-bad/payload/scripts/premium_test.sh
mkdir extra
printf 'not-in-manifest' > extra/undeclared.txt
python3 '$wslRepo/tools/make_package_zip.py' staging-bad '$($badZip -replace '\\','/' -replace '^C:','/mnt/c')'
python3 '$wslRepo/tools/make_package_zip.py' staging '$($symZip -replace '\\','/' -replace '^C:','/mnt/c')' --symlink payload/evil-link /data
python3 '$wslRepo/tools/make_package_zip.py' staging '$($extraZip -replace '\\','/' -replace '^C:','/mnt/c')'
(cd staging && python3 -c "import zipfile; z=zipfile.ZipFile('$($extraZip -replace '\\','/' -replace '^C:','/mnt/c')', 'a'); z.write('../extra/undeclared.txt', 'payload/undeclared.txt'); z.close()")
"@
$wslScriptBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($wslScript))
# Keep paths with spaces, ampersands, and Chinese characters out of the Windows
# command-line parser. The decoded script still quotes every WSL path itself.
wsl -d Ubuntu -- bash -lc "printf '%s' '$wslScriptBase64' | base64 -d | bash"
if ($LASTEXITCODE -ne 0) { throw "zip variants failed" }

# 5. (chunks are now split on-device from the pushed zips - no chunk push needed)

# 6. sha256 values for commits
function ShaOf($path) { (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() }
[System.IO.File]::WriteAllText((Join-Path $cases "pkg-ok.sha256"), (ShaOf (Join-Path $cases "pkg-ok.zip")) + "`n")
[System.IO.File]::WriteAllText((Join-Path $cases "pkg-badfile.sha256"), (ShaOf $badZip) + "`n")
[System.IO.File]::WriteAllText((Join-Path $cases "pkg-symlink.sha256"), (ShaOf $symZip) + "`n")
[System.IO.File]::WriteAllText((Join-Path $cases "pkg-extra.sha256"), (ShaOf $extraZip) + "`n")

# 6. build one push tree (single directory push avoids name truncation)
$pushMod = Join-Path $work "pushtree\mod"
New-Item -ItemType Directory -Force -Path (Join-Path $pushMod "bin"), (Join-Path $pushMod "config"), (Join-Path $pushMod "scripts") | Out-Null
Copy-Item (Join-Path $Repo "bin\verify_lease_sig") (Join-Path $pushMod "bin\") -Force
Copy-Item (Join-Path $Repo "module.prop") $pushMod -Force
Copy-Item (Join-Path $Repo "config\auth") (Join-Path $pushMod "config\") -Recurse -Force
Copy-Item (Join-Path $Repo "scripts\*.sh") (Join-Path $pushMod "scripts\") -Force
Set-Content -Path (Join-Path $pushMod "config\dts_backend.txt") -Value "drm" -NoNewline -Encoding ascii
Set-Content -LiteralPath (Join-Path $pushMod "config\auth\lease_public_key.hex") -Value $leasePublicKey -NoNewline -Encoding ascii
Set-Content -LiteralPath (Join-Path $pushMod "config\auth\lease_key_id.txt") -Value $LeaseKeyId -NoNewline -Encoding ascii
Set-Content -LiteralPath (Join-Path $pushMod "config\auth\package_public_key.hex") -Value $packagePublicKey -NoNewline -Encoding ascii
Set-Content -LiteralPath (Join-Path $pushMod "config\auth\package_key_id.txt") -Value $PackageKeyId -NoNewline -Encoding ascii

& $adb -s $Device shell "rm -rf /data/local/tmp/gatetest; mkdir -p /data/local/tmp/gatetest"
& $adb -s $Device push $pushMod /data/local/tmp/gatetest/ | Out-Null
& $adb -s $Device push $cases /data/local/tmp/gatetest/ | Out-Null
& $adb -s $Device push (Join-Path $Repo "tests") /data/local/tmp/gatetest/ | Out-Null

# 7. run the test
& $adb -s $Device shell "sh /data/local/tmp/gatetest/tests/check_display_license_gate.sh" 2>&1
Write-Host "device test exit: $LASTEXITCODE"
