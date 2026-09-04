param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,
    [string]$KeystorePath = $env:MURONG_HOOK_KEYSTORE,
    [string]$KeyAlias = $env:MURONG_HOOK_KEY_ALIAS,
    [string]$ExpectedCertSha256 = "7776d8cf8ca3482e9ea902032e402e9d9310a9b20f0a6bb91f408cc22a07e90e",
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"

function Resolve-ApkSigner {
    $candidates = @()
    $sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    foreach ($sdkRoot in $sdkRoots) {
        $buildToolsRoot = Join-Path $sdkRoot "build-tools"
        if (-not (Test-Path -LiteralPath $buildToolsRoot -PathType Container)) {
            continue
        }
        $buildTools = Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending
        foreach ($buildTool in $buildTools) {
            $candidates += Join-Path $buildTool.FullName "apksigner.exe"
            $candidates += Join-Path $buildTool.FullName "apksigner.bat"
            $candidates += Join-Path $buildTool.FullName "apksigner"
        }
    }
    $fromPath = Get-Command apksigner, apksigner.bat -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($fromPath) {
        $candidates += $fromPath.Source
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "Android SDK apksigner was not found in the configured SDK or PATH"
}

$apk = (Resolve-Path -LiteralPath $ApkPath).Path
$idsig = "$apk.idsig"
$apkSigner = Resolve-ApkSigner

if (-not $VerifyOnly) {
    foreach ($required in @(
        @{ Name = "MURONG_HOOK_STORE_PASSWORD"; Value = $env:MURONG_HOOK_STORE_PASSWORD },
        @{ Name = "MURONG_HOOK_KEY_PASSWORD"; Value = $env:MURONG_HOOK_KEY_PASSWORD },
        @{ Name = "KeystorePath"; Value = $KeystorePath },
        @{ Name = "KeyAlias"; Value = $KeyAlias }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
            throw "Hook signing requires $($required.Name)"
        }
    }
    $keystore = (Resolve-Path -LiteralPath $KeystorePath).Path
    Remove-Item -LiteralPath $idsig -Force -ErrorAction SilentlyContinue
    $signArguments = @(
        "sign",
        "--v1-signing-enabled", "true",
        "--v2-signing-enabled", "true",
        "--v3-signing-enabled", "true",
        "--v4-signing-enabled", "true",
        "--ks", $keystore,
        "--ks-key-alias", $KeyAlias,
        "--ks-pass", "env:MURONG_HOOK_STORE_PASSWORD",
        "--key-pass", "env:MURONG_HOOK_KEY_PASSWORD",
        $apk
    )
    $signOutput = @(& $apkSigner @signArguments 2>&1)
    $signExitCode = $LASTEXITCODE
    $signOutput | ForEach-Object { Write-Host $_ }
    if ($signExitCode -ne 0) {
        throw "apksigner sign failed with exit code $signExitCode"
    }
}

if (-not (Test-Path -LiteralPath $idsig -PathType Leaf) -or
    (Get-Item -LiteralPath $idsig).Length -eq 0) {
    throw "Android v4 signature sidecar is missing: $idsig"
}

function Invoke-SchemeVerification([int]$Scheme, [string[]]$ExtraArguments) {
    $arguments = @("verify", "--verbose", "--print-certs") + $ExtraArguments + @($apk)
    $output = @(& $apkSigner @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    Write-Host $text
    if ($exitCode -ne 0) {
        throw "apksigner v$Scheme verification failed with exit code $exitCode"
    }
    if ($text -notmatch "(?im)^Verified using v$Scheme scheme\b.*:\s*true\s*$") {
        throw "Hook APK is missing a valid v$Scheme signature"
    }
    return $text
}

$verificationTexts = @(
    Invoke-SchemeVerification 1 @("--min-sdk-version", "18", "--max-sdk-version", "23")
    Invoke-SchemeVerification 2 @("--min-sdk-version", "24", "--max-sdk-version", "27")
    Invoke-SchemeVerification 3 @("--min-sdk-version", "28", "--max-sdk-version", "29")
    Invoke-SchemeVerification 4 @("--v4-signature-file", $idsig)
)
$normalizedCert = (($verificationTexts -join [Environment]::NewLine) -replace ":", "").ToLowerInvariant()
if (-not $normalizedCert.Contains($ExpectedCertSha256.ToLowerInvariant())) {
    throw "Hook APK certificate SHA-256 does not match the Murong signing identity"
}
Write-Host "Hook APK v1/v2/v3/v4 signatures and certificate - PASS"
