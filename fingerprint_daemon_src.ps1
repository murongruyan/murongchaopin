# Emit the SHA-256 of a source file as CI sees it.
#
# tests/check_binary_fingerprint.sh runs on Linux, where the file has LF
# endings, and compares its digest against bin/rate_daemon.src.sha256.  A
# Windows working copy with core.autocrlf=true holds CRLF instead, so hashing
# the file as-is records a digest that can never match on the runner and turns
# a correct build into a failing release gate.  Strip CR first so both sides
# hash the same bytes.
param(
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'

$full = (Resolve-Path -LiteralPath $Path).Path
$text = [System.IO.File]::ReadAllText($full)
$lf = $text -replace "`r`n", "`n"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($lf)

$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $digest = $sha.ComputeHash($bytes)
} finally {
    $sha.Dispose()
}

$hex = ($digest | ForEach-Object { $_.ToString('x2') }) -join ''
Write-Output $hex
