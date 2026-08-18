param(
    [Parameter(Mandatory = $true)]
    [string]$DtsPath,

    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

function Find-MatchingBrace {
    param(
        [string]$Text,
        [int]$OpenIndex
    )

    $depth = 0
    $inString = $false
    $escaped = $false
    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($ch -eq '\') {
                $escaped = $true
            } elseif ($ch -eq '"') {
                $inString = $false
            }
            continue
        }
        if ($ch -eq '"') {
            $inString = $true
        } elseif ($ch -eq '{') {
            $depth++
        } elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $i
            }
        }
    }
    throw "Unmatched brace at offset $OpenIndex"
}

function Convert-PropertyBytes {
    param([string]$Value)

    $bytes = [System.Collections.Generic.List[byte]]::new()
    if ($Value.StartsWith('[')) {
        foreach ($match in [regex]::Matches($Value, '(?i)\b[0-9a-f]{2}\b')) {
            $bytes.Add([Convert]::ToByte($match.Value, 16))
        }
        return $bytes.ToArray()
    }
    if ($Value.StartsWith('<')) {
        foreach ($match in [regex]::Matches($Value, '(?i)0x[0-9a-f]+|\b\d+\b')) {
            $cell = if ($match.Value.StartsWith('0x')) {
                [Convert]::ToUInt32($match.Value.Substring(2), 16)
            } else {
                [Convert]::ToUInt32($match.Value, 10)
            }
            $bytes.Add([byte](($cell -shr 24) -band 0xff))
            $bytes.Add([byte](($cell -shr 16) -band 0xff))
            $bytes.Add([byte](($cell -shr 8) -band 0xff))
            $bytes.Add([byte]($cell -band 0xff))
        }
        return $bytes.ToArray()
    }
    throw "Unsupported property encoding: $($Value.Substring(0, [Math]::Min(16, $Value.Length)))"
}

function Convert-DsiPackets {
    param([byte[]]$Bytes)

    $packets = [System.Collections.Generic.List[object]]::new()
    $offset = 0
    $index = 0
    while ($offset -lt $Bytes.Length) {
        if ($Bytes.Length - $offset -lt 7) {
            throw "Truncated DSI header at byte $offset of $($Bytes.Length)"
        }
        $length = ([int]$Bytes[$offset + 5] -shl 8) -bor [int]$Bytes[$offset + 6]
        if ($offset + 7 + $length -gt $Bytes.Length) {
            throw "Packet $index payload length $length exceeds property length $($Bytes.Length)"
        }
        $payload = if ($length) {
            [byte[]]$Bytes[($offset + 7)..($offset + 6 + $length)]
        } else {
            [byte[]]@()
        }
        $packets.Add([pscustomobject]@{
            Index = $index
            Offset = $offset
            Type = $Bytes[$offset]
            Last = $Bytes[$offset + 1]
            Channel = $Bytes[$offset + 2]
            Flags = $Bytes[$offset + 3]
            WaitMs = $Bytes[$offset + 4]
            Length = $length
            Payload = $payload
            PayloadHex = (($payload | ForEach-Object { $_.ToString('x2') }) -join ' ')
        })
        $offset += 7 + $length
        $index++
    }
    return $packets.ToArray()
}

function Get-PropertyValue {
    param(
        [string]$Node,
        [string]$Name
    )

    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match($Node, "(?ms)^\s*$escapedName\s*=\s*(\[[^;]*\]|<[^;]*>)\s*;")
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups[1].Value.Trim()
}

function Get-U32Property {
    param(
        [string]$Node,
        [string]$Name
    )

    $value = Get-PropertyValue -Node $Node -Name $Name
    if (-not $value) {
        return $null
    }
    $match = [regex]::Match($value, '(?i)0x[0-9a-f]+|\b\d+\b')
    if (-not $match.Success) {
        return $null
    }
    if ($match.Value.StartsWith('0x')) {
        return [Convert]::ToUInt32($match.Value.Substring(2), 16)
    }
    return [Convert]::ToUInt32($match.Value, 10)
}

function Get-DirectChildNodes {
    param(
        [string]$Node,
        [string]$NamePattern
    )

    $children = [System.Collections.Generic.List[object]]::new()
    $regex = [regex]::new("(?m)^\s*($NamePattern)\s*\{")
    foreach ($match in $regex.Matches($Node)) {
        $open = $Node.IndexOf('{', $match.Index)
        $close = Find-MatchingBrace -Text $Node -OpenIndex $open
        $children.Add([pscustomobject]@{
            Name = $match.Groups[1].Value
            Text = $Node.Substring($match.Index, $close - $match.Index + 1)
            Offset = $match.Index
        })
    }
    return $children.ToArray()
}

function Format-PacketDiff {
    param(
        [hashtable]$PacketSets,
        [int[]]$Rates
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $count = $PacketSets[$Rates[0]].Count
    foreach ($rate in $Rates) {
        if ($PacketSets[$rate].Count -ne $count) {
            throw "Packet count mismatch: $($Rates[0])Hz=$count, ${rate}Hz=$($PacketSets[$rate].Count)"
        }
    }
    for ($index = 0; $index -lt $count; $index++) {
        $signatures = foreach ($rate in $Rates) {
            $packet = $PacketSets[$rate][$index]
            '{0:x2}/{1:x2}/{2:x2}/{3:x2}/{4:x2}/{5}:{6}' -f `
                $packet.Type, $packet.Last, $packet.Channel, $packet.Flags,
                $packet.WaitMs, $packet.Length, $packet.PayloadHex
        }
        if (($signatures | Sort-Object -Unique).Count -eq 1) {
            continue
        }
        $lines.Add("packet $index")
        foreach ($rate in $Rates) {
            $packet = $PacketSets[$rate][$index]
            $lines.Add(('  {0,3}Hz off={1,4} type=0x{2:x2} last={3} wait={4,3} len={5,3} payload={6}' -f `
                $rate, $packet.Offset, $packet.Type, $packet.Last,
                $packet.WaitMs, $packet.Length, $packet.PayloadHex))
        }
    }
    return $lines.ToArray()
}

$dts = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $DtsPath))
$panelName = 'qcom,mdss_dsi_panel_AE084_P_3_A0033_dsc_cmd_dvt02'
$panelRegex = [regex]::new("(?m)^\s*$([regex]::Escape($panelName))\s*\{")
$panel = $null
foreach ($match in $panelRegex.Matches($dts)) {
    $open = $dts.IndexOf('{', $match.Index)
    $close = Find-MatchingBrace -Text $dts -OpenIndex $open
    $candidate = $dts.Substring($match.Index, $close - $match.Index + 1)
    if ($candidate.Contains('qcom,mdss-dsi-panel-name') -and
        $candidate.Contains('qcom,mdss-dsi-display-timings')) {
        $panel = $candidate
        break
    }
}
if (-not $panel) {
    throw "Could not find the full $panelName node"
}

$timingsContainerMatch = [regex]::Match($panel, '(?m)^\s*qcom,mdss-dsi-display-timings\s*\{')
if (-not $timingsContainerMatch.Success) {
    throw 'Missing display timings container'
}
$timingsOpen = $panel.IndexOf('{', $timingsContainerMatch.Index)
$timingsClose = Find-MatchingBrace -Text $panel -OpenIndex $timingsOpen
$timingsContainer = $panel.Substring(
    $timingsContainerMatch.Index,
    $timingsClose - $timingsContainerMatch.Index + 1)

$wantedRates = @(60, 90, 120, 144)
$timings = @{}
foreach ($child in Get-DirectChildNodes -Node $timingsContainer -NamePattern 'timing@[A-Za-z0-9_.+-]+') {
    $rate = Get-U32Property -Node $child.Text -Name 'qcom,mdss-dsi-panel-framerate'
    if ($wantedRates -contains $rate -and -not $timings.ContainsKey([int]$rate)) {
        $timings[[int]$rate] = $child
    }
}
foreach ($rate in $wantedRates) {
    if (-not $timings.ContainsKey($rate)) {
        throw "Missing ${rate}Hz timing in DVT02 panel"
    }
}

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("DTS: $((Resolve-Path -LiteralPath $DtsPath).Path)")
$report.Add("Panel: $panelName")
$report.Add('')

foreach ($property in @('qcom,mdss-dsi-timing-switch-command', 'qcom,mdss-dsi-on-command')) {
    $packetSets = @{}
    $report.Add("[$property]")
    foreach ($rate in $wantedRates) {
        $value = Get-PropertyValue -Node $timings[$rate].Text -Name $property
        if (-not $value) {
            throw "Missing $property in ${rate}Hz timing"
        }
        $bytes = Convert-PropertyBytes -Value $value
        $packets = Convert-DsiPackets -Bytes $bytes
        $packetSets[$rate] = $packets
        $report.Add("${rate}Hz: node=$($timings[$rate].Name) bytes=$($bytes.Length) packets=$($packets.Count)")
    }
    $report.Add('')
    foreach ($line in Format-PacketDiff -PacketSets $packetSets -Rates $wantedRates) {
        $report.Add($line)
    }
    $report.Add('')
}

$text = $report -join [Environment]::NewLine
if ($OutputDirectory) {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
    [IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
    $outputPath = Join-Path $resolvedOutput 'ae084-dvt02-dsi-diff.txt'
    [IO.File]::WriteAllText($outputPath, $text + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    Write-Output $outputPath
}
Write-Output $text
