# AppleHomePodDiag 1.1.3
# Copyright (c) 2026 Stefan Kittel <info@kittel.online>
# Project: https://github.com/Skittel/AppleHomePodDiag
#requires -Version 5.1
<#
.SYNOPSIS
    AppleHomePodDiag - HomePod, AirPlay and Bonjour/mDNS diagnostics for Windows.

.DESCRIPTION
    Discovers AirPlay devices using Apple's dns-sd.exe, identifies HomePods,
    reads Bonjour TXT records (including model and osvers), resolves .local
    names, tests ping and the advertised AirPlay TCP port, records the local
    Wi-Fi connection and exports JSON/CSV/HTML reports.

    A reference scan can be supplied to test known device IP addresses even
    when Bonjour discovery fails on the current test node. This is useful for
    proving "IP connectivity works, but mDNS discovery does not".

    Multiple JSON reports can also be compared.

.ORIGINAL PROJECT
    https://github.com/Skittel/AppleHomePodDiag

.LICENSE
    See LICENSE and PROJECT_INFO.txt in the original project.
    Redistributed or modified versions are subject to the license terms,
    including the requirement to retain PROJECT_INFO.txt.

.NOTES
    Version: 1.1.3
    Author: Stefan Kittel
    Project: https://github.com/Skittel/AppleHomePodDiag

.EXAMPLES
    .\AppleHomePodDiag.ps1

    .\AppleHomePodDiag.ps1 -NodeName "AP1-24GHz"

    .\AppleHomePodDiag.ps1 -NodeName "AP2-5GHz" -ReferenceJson ".\AP1.json"

    .\AppleHomePodDiag.ps1 -HomePodsOnly -ScanSeconds 8

    .\AppleHomePodDiag.ps1 -Name "Küche"

    .\AppleHomePodDiag.ps1 -IP "192.168.2.67"

    .\AppleHomePodDiag.ps1 -MAC "50-BC-96-03-A8-54"

    .\AppleHomePodDiag.ps1 -Compare ".\AP1.json", ".\AP2.json"
#>

[CmdletBinding(DefaultParameterSetName = 'Scan')]
param(
    [Parameter(ParameterSetName = 'Scan')]
    [string]$NodeName = $env:COMPUTERNAME,

    [Parameter(ParameterSetName = 'Scan')]
    [ValidateRange(2, 60)]
    [int]$ScanSeconds = 5,

    [Parameter(ParameterSetName = 'Scan')]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'HomePodDiag-Results'),

    [Parameter(ParameterSetName = 'Scan')]
    [switch]$HomePodsOnly,

    [Parameter(ParameterSetName = 'Scan')]
    [switch]$SkipOnlineVersionCheck,

    [Parameter(ParameterSetName = 'Scan')]
    [string]$ExpectedHomePodVersion,

    [Parameter(ParameterSetName = 'Scan')]
    [string]$ReferenceJson,

    # Focused diagnostic mode. Use exactly one of -Name, -IP or -MAC.
    # The script still takes one Bonjour snapshot so model/OS/TXT data can be
    # correlated, but only the requested device is fully tested and displayed.
    [Parameter(ParameterSetName = 'Scan')]
    [string]$Name,

    [Parameter(ParameterSetName = 'Scan')]
    [string]$IP,

    [Parameter(ParameterSetName = 'Scan')]
    [string]$MAC,

    [Parameter(Mandatory = $true, ParameterSetName = 'Compare')]
    [ValidateCount(2, 20)]
    [string[]]$Compare
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:ToolName = 'AppleHomePodDiag'
$Script:ToolVersion = '1.1.3'
$Script:ProjectUrl = 'https://github.com/Skittel/AppleHomePodDiag'
$Script:AppleUpdateUrl = 'https://support.apple.com/en-us/108045'

# Improve Unicode output in Windows PowerShell 5.1 consoles.
try {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
} catch {}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Text)

    Write-Host ''
    Write-Host ('=' * 86) -ForegroundColor DarkGray
    Write-Host (' {0}' -f $Text) -ForegroundColor Cyan
    Write-Host ('=' * 86) -ForegroundColor DarkGray
}

function Get-DnsSdPath {
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    $cmd = Get-Command 'dns-sd.exe' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        $candidates.Add($cmd.Source)
    }

    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Bonjour\dns-sd.exe'))
        $candidates.Add((Join-Path $env:ProgramFiles 'Bonjour Print Services\dns-sd.exe'))
    }

    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Bonjour\dns-sd.exe'))
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Bonjour Print Services\dns-sd.exe'))
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw @"
dns-sd.exe was not found.

Install Apple Bonjour / Bonjour Print Services or make dns-sd.exe available in PATH.
Apple support page:
https://support.apple.com/106380
"@
}

function Quote-ProcessArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    # ProcessStartInfo.Arguments parsing on Windows: quote the argument and
    # escape embedded double quotes.
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [ValidateRange(100, 120000)][int]$TimeoutMs = 3000
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try { $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8 } catch {}

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()

    # Read both redirected streams asynchronously while dns-sd is running.
    # This is important for "dns-sd -Z", which can emit enough TXT records to
    # fill the Windows pipe buffer and otherwise block before the timeout.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $timer = [Diagnostics.Stopwatch]::StartNew()

    while (-not $process.HasExited -and $timer.ElapsedMilliseconds -lt $TimeoutMs) {
        Start-Sleep -Milliseconds 40
    }

    if (-not $process.HasExited) {
        try { $process.Kill() } catch {}
    }

    try { $process.WaitForExit() } catch {}

    $stdout = ''
    $stderr = ''

    try { $stdout = $stdoutTask.Result } catch {}
    try { $stderr = $stderrTask.Result } catch {}

    $timer.Stop()

    [pscustomobject]@{
        StdOut    = $stdout
        StdErr    = $stderr
        ExitCode  = if ($process.HasExited) { $process.ExitCode } else { $null }
        ElapsedMs = $timer.ElapsedMilliseconds
    }
}

function Get-WlanInfo {
    $raw = (& netsh wlan show interfaces 2>&1 | Out-String)

    $result = [ordered]@{
        Interface = $null
        State     = $null
        SSID      = $null
        BSSID     = $null
        Band      = $null
        Channel   = $null
        RadioType = $null
        Signal    = $null
        IPv4      = $null
        Raw       = $raw.Trim()
    }

    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*(Name|Name der Schnittstelle)\s*:\s*(.+?)\s*$' -and -not $result.Interface) {
            $result.Interface = $matches[2].Trim()
            continue
        }

        if ($line -match '^\s*(State|Status|Zustand)\s*:\s*(.+?)\s*$') {
            $result.State = $matches[2].Trim()
            continue
        }

        if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$' -and $line -notmatch 'BSSID') {
            $result.SSID = $matches[1].Trim()
            continue
        }

        if ($line -match '^\s*BSSID\s*:\s*(.+?)\s*$') {
            $result.BSSID = $matches[1].Trim().ToUpperInvariant()
            continue
        }

        if ($line -match '^\s*Band\s*:\s*(.+?)\s*$') {
            $result.Band = $matches[1].Trim()
            continue
        }

        if ($line -match '^\s*(Channel|Kanal)\s*:\s*(\d+)\s*$') {
            $result.Channel = [int]$matches[2]
            continue
        }

        if ($line -match '^\s*(Radio type|Funktyp)\s*:\s*(.+?)\s*$') {
            $result.RadioType = $matches[2].Trim()
            continue
        }

        if ($line -match '^\s*Signal\s*:\s*(.+?)\s*$') {
            $result.Signal = $matches[1].Trim()
            continue
        }
    }

    if ($result.Interface) {
        try {
            $result.IPv4 = Get-NetIPAddress -InterfaceAlias $result.Interface -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1 -ExpandProperty IPAddress
        } catch {}
    }

    if (-not $result.IPv4) {
        try {
            $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                Sort-Object RouteMetric |
                Select-Object -First 1

            if ($defaultRoute) {
                $result.IPv4 = Get-NetIPAddress -InterfaceIndex $defaultRoute.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.IPAddress -notlike '169.254.*' } |
                    Select-Object -First 1 -ExpandProperty IPAddress
            }
        } catch {}
    }

    # If older netsh does not report "Band", channel still gives a useful hint.
    if (-not $result.Band -and $null -ne $result.Channel) {
        if ($result.Channel -ge 1 -and $result.Channel -le 14) {
            $result.Band = '2.4 GHz (derived from channel)'
        } else {
            $result.Band = '5/6 GHz (netsh did not expose band)'
        }
    }

    [pscustomobject]$result
}

function Get-CurrentHomePodVersion {
    param(
        [switch]$SkipOnline,
        [string]$Expected
    )

    if ($Expected) {
        return [pscustomobject]@{
            Version = $Expected.Trim()
            Source  = 'Manual parameter'
            Url     = $null
            Error   = $null
        }
    }

    if ($SkipOnline) {
        return [pscustomobject]@{
            Version = $null
            Source  = 'Online check skipped'
            Url     = $null
            Error   = $null
        }
    }

    try {
        # Windows PowerShell 5.1 may otherwise negotiate an obsolete protocol
        # on older systems.
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {}

        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'

        try {
            $response = Invoke-WebRequest `
                -Uri $Script:AppleUpdateUrl `
                -UseBasicParsing `
                -TimeoutSec 12 `
                -Headers @{ 'User-Agent' = 'Mozilla/5.0 AppleHomePodDiag/1.0' }
        } finally {
            $ProgressPreference = $oldProgress
        }

        # Apple's page is ordered newest first. Capture the first public
        # "HomePod Software Version X" heading.
        $match = [regex]::Match(
            $response.Content,
            'HomePod\s+Software\s+Version\s+([0-9]+(?:\.[0-9]+){0,3})',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if ($match.Success) {
            return [pscustomobject]@{
                Version = $match.Groups[1].Value
                Source  = 'Apple Support'
                Url     = $Script:AppleUpdateUrl
                Error   = $null
            }
        }

        return [pscustomobject]@{
            Version = $null
            Source  = 'Apple Support'
            Url     = $Script:AppleUpdateUrl
            Error   = 'No version heading could be parsed from the Apple page.'
        }
    }
    catch {
        return [pscustomobject]@{
            Version = $null
            Source  = 'Apple Support'
            Url     = $Script:AppleUpdateUrl
            Error   = $_.Exception.Message
        }
    }
}

function ConvertTo-VersionObject {
    param([AllowNull()][string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $match = [regex]::Match($VersionText.Trim(), '^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $match.Success) {
        return $null
    }

    $parts = @(0, 0, 0, 0)
    for ($i = 1; $i -le 4; $i++) {
        if ($match.Groups[$i].Success) {
            $parts[$i - 1] = [int]$match.Groups[$i].Value
        }
    }

    return [version](('{0}.{1}.{2}.{3}' -f $parts[0], $parts[1], $parts[2], $parts[3]))
}

function Get-VersionStatus {
    param(
        [AllowNull()][string]$Installed,
        [AllowNull()][string]$Current,
        [bool]$IsHomePod
    )

    if (-not $IsHomePod) {
        return 'N/A'
    }

    if ([string]::IsNullOrWhiteSpace($Installed)) {
        return 'UNKNOWN'
    }

    if ([string]::IsNullOrWhiteSpace($Current)) {
        return 'NOT CHECKED'
    }

    $installedVersion = ConvertTo-VersionObject $Installed
    $currentVersion = ConvertTo-VersionObject $Current

    if ($null -eq $installedVersion -or $null -eq $currentVersion) {
        return 'UNKNOWN'
    }

    if ($installedVersion -eq $currentVersion) {
        return 'CURRENT'
    }

    if ($installedVersion -lt $currentVersion) {
        return 'UPDATE AVAILABLE'
    }

    return 'NEWER THAN PUBLIC'
}

function Get-FriendlyModel {
    param([AllowNull()][string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) {
        return 'AirPlay device'
    }

    switch ($Model) {
        'AudioAccessory1,1'       { return 'HomePod (1st generation)' }
        'AudioAccessory1,2'       { return 'HomePod (1st generation)' }
        'AudioAccessory5,1'       { return 'HomePod mini' }
        'AudioAccessorySingle5,1' { return 'HomePod mini' }
        'AudioAccessory6,1'       { return 'HomePod (2nd generation)' }
        default {
            if ($Model -match '^AudioAccessory') {
                return "HomePod (unknown model: $Model)"
            }

            if ($Model -match '^AppleTV') {
                return "Apple TV / AirPlay ($Model)"
            }

            if ($Model) {
                return "AirPlay device ($Model)"
            }

            return 'AirPlay device'
        }
    }
}

function Test-IsHomePodModel {
    param([AllowNull()][string]$Model)
    return [bool]($Model -match '^AudioAccessory')
}

function Get-AirPlayInstances {
    param(
        [Parameter(Mandatory = $true)][string]$DnsSd,
        [Parameter(Mandatory = $true)][int]$Seconds
    )

    $result = Invoke-CapturedProcess `
        -FilePath $DnsSd `
        -Arguments '-B _airplay._tcp local' `
        -TimeoutMs ($Seconds * 1000)

    $names = New-Object 'System.Collections.Generic.List[string]'

    foreach ($line in ($result.StdOut -split "`r?`n")) {
        # Example:
        # 0:28:45.613  Add  3 17 local. _airplay._tcp. Galerie
        if ($line -match '\sAdd\s+' -and $line -match '_airplay\._tcp\.\s+(.+?)\s*$') {
            $name = $matches[1].Trim()

            if ($name -and -not $names.Contains($name)) {
                $names.Add($name)
            }
        }
    }

    return $names.ToArray()
}


function ConvertFrom-DnsSdZoneName {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    # dns-sd -Z leaves Unicode characters such as ä/ü intact on Windows but
    # escapes characters such as spaces as decimal DNS escapes, e.g. \032.
    # PowerShell strings are already Unicode, so decode only the DNS escapes.
    $result = [regex]::Replace(
        $Text,
        '\\(?<n>\d{3})',
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            $value = [int]$m.Groups['n'].Value
            return [char]$value
        }
    )

    # Decode a simple escaped character as well (for example "\." if present).
    $result = [regex]::Replace(
        $result,
        '\\(?<c>.)',
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            return $m.Groups['c'].Value
        }
    )

    return $result
}

function Get-AirPlayInstanceFromZoneOwner {
    param([AllowNull()][string]$Owner)

    if ([string]::IsNullOrWhiteSpace($Owner)) {
        return $null
    }

    $value = $Owner.Trim().TrimEnd('.')

    foreach ($suffix in @(
        '._airplay._tcp.local',
        '._airplay._tcp'
    )) {
        if ($value.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
            $value = $value.Substring(0, $value.Length - $suffix.Length)
            break
        }
    }

    if ($value -eq '_airplay._tcp' -or $value -eq '_airplay._tcp.local') {
        return $null
    }

    return (ConvertFrom-DnsSdZoneName $value)
}

function Get-AirPlayZoneDetails {
    param(
        [Parameter(Mandatory = $true)][string]$DnsSd,
        [Parameter(Mandatory = $true)][int]$Seconds
    )

    # -Z is the Unicode-safe path on Windows. The instance name never has to
    # be supplied back to dns-sd.exe as an argument, so names such as "Küche",
    # "Gäste WC" and "Joni‘s Zimmer" can be handled correctly.
    $result = Invoke-CapturedProcess `
        -FilePath $DnsSd `
        -Arguments '-Z _airplay._tcp local' `
        -TimeoutMs ($Seconds * 1000)

    $records = @{}

    function Get-OrCreateZoneRecord {
        param([Parameter(Mandatory = $true)][string]$Name)

        if (-not $records.ContainsKey($Name)) {
            $records[$Name] = [pscustomobject]@{
                InstanceName   = $Name
                HostName       = $null
                Port           = $null
                InterfaceIndex = $null
                TXT            = [ordered]@{}
                Raw            = ''
            }
        }

        return $records[$Name]
    }

    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        # Observed Windows format:
        # _airplay._tcp PTR Küche._airplay._tcp
        # Küche._airplay._tcp SRV 0 0 7000 Kuche.local. ; comment
        # Küche._airplay._tcp TXT "acl=0" ... "model=AudioAccessory1,1"
        $rr = [regex]::Match(
            $line,
            '^\s*(?<owner>\S+)\s+(?<type>PTR|SRV|TXT)\s+(?<data>.*)$'
        )

        if (-not $rr.Success) {
            continue
        }

        $owner = $rr.Groups['owner'].Value
        $type  = $rr.Groups['type'].Value
        $data  = $rr.Groups['data'].Value

        if ($type -eq 'PTR') {
            $ptrTarget = ($data -split '\s+')[0]
            $name = Get-AirPlayInstanceFromZoneOwner $ptrTarget

            if ($name) {
                [void](Get-OrCreateZoneRecord $name)
            }

            continue
        }

        $name = Get-AirPlayInstanceFromZoneOwner $owner
        if (-not $name) {
            continue
        }

        $record = Get-OrCreateZoneRecord $name
        $record.Raw += $line + "`r`n"

        if ($type -eq 'SRV') {
            # Remove dns-sd's explanatory comment after the target hostname.
            $srvData = ($data -split '\s+;\s+', 2)[0]

            $srv = [regex]::Match(
                $srvData,
                '^\s*\d+\s+\d+\s+(?<port>\d+)\s+(?<host>\S+)\s*$'
            )

            if ($srv.Success) {
                $record.Port = [int]$srv.Groups['port'].Value
                $record.HostName = ConvertFrom-DnsSdZoneName(
                    $srv.Groups['host'].Value.Trim().TrimEnd('.')
                )
            }

            continue
        }

        if ($type -eq 'TXT') {
            foreach ($quoted in [regex]::Matches($data, '"(?<txt>(?:\\.|[^"])*)"')) {
                $value = ConvertFrom-DnsSdZoneName $quoted.Groups['txt'].Value

                if ($value -match '^(?<key>[^=]+)=(?<val>.*)$') {
                    $record.TXT[$matches['key']] = $matches['val']
                }
            }
        }
    }

    return $records
}


function Get-AirPlayDetails {
    param(
        [Parameter(Mandatory = $true)][string]$DnsSd,
        [Parameter(Mandatory = $true)][string]$InstanceName
    )

    $arguments = '-L {0} _airplay._tcp local' -f (Quote-ProcessArgument $InstanceName)

    # dns-sd stays running after a successful lookup. A short timeout is
    # intentional; local responses normally arrive almost immediately.
    $result = Invoke-CapturedProcess `
        -FilePath $DnsSd `
        -Arguments $arguments `
        -TimeoutMs 1400

    $hostName = $null
    $port = $null
    $interfaceIndex = $null
    $txt = [ordered]@{}

    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ($line -match 'can be reached at\s+(.+?):(\d+)\s+\(interface\s+(\d+)\)') {
            $hostName = $matches[1].Trim().TrimEnd('.')
            $port = [int]$matches[2]
            $interfaceIndex = [int]$matches[3]
        }

        foreach ($m in [regex]::Matches($line, '(?<key>[A-Za-z0-9_]+)=(?<value>[^\s]+)')) {
            $txt[$m.Groups['key'].Value] = $m.Groups['value'].Value
        }
    }

    [pscustomobject]@{
        InstanceName  = $InstanceName
        HostName      = $hostName
        Port          = $port
        InterfaceIndex = $interfaceIndex
        TXT           = $txt
        Raw           = $result.StdOut.Trim()
    }
}

function Resolve-MdnsIPv4 {
    param(
        [Parameter(Mandatory = $true)][string]$DnsSd,
        [AllowNull()][string]$HostName
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return $null
    }

    $arguments = '-G v4 {0}' -f (Quote-ProcessArgument $HostName)

    $result = Invoke-CapturedProcess `
        -FilePath $DnsSd `
        -Arguments $arguments `
        -TimeoutMs 1400

    foreach ($line in ($result.StdOut -split "`r?`n")) {
        $match = [regex]::Match($line, '(?<!\d)((?:\d{1,3}\.){3}\d{1,3})(?!\d)')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    # Fallback to the Windows name resolver. This uses Unicode APIs and is
    # therefore more reliable for .local hostnames containing non-ASCII chars.
    try {
        $address = [System.Net.Dns]::GetHostAddresses($HostName) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            Select-Object -First 1

        if ($address) {
            return $address.IPAddressToString
        }
    }
    catch {}

    return $null
}

function Test-PingAddress {
    param(
        [AllowNull()][string]$IPAddress,
        [ValidateRange(100, 5000)][int]$TimeoutMs = 1000
    )

    $measuredPingCount = 5
    $measurementIntervalMs = 500

    if ([string]::IsNullOrWhiteSpace($IPAddress)) {
        return [pscustomobject]@{
            Success = $false
            Ms      = $null
            MinMs   = $null
            MaxMs   = $null
            AvgMs   = $null
            Lost    = $measuredPingCount
            Sent    = $measuredPingCount
            Samples = @()
        }
    }

    $pingClient = New-Object System.Net.NetworkInformation.Ping
    $samples = New-Object 'System.Collections.Generic.List[int]'
    $lost = 0

    try {
        # Warm-up / wake-up ping. Its result is deliberately discarded.
        # Wi-Fi power-saving clients such as HomePods can show a high first
        # response time while waking up.
        try {
            [void]$pingClient.Send($IPAddress, $TimeoutMs)
        }
        catch {}

        # Do not immediately follow the wake-up ping with the measurements.
        # A 500 ms gap and 500 ms spacing between measured pings makes the test
        # more representative of intermittent WLAN latency / power-save effects.
        Start-Sleep -Milliseconds $measurementIntervalMs

        for ($i = 0; $i -lt $measuredPingCount; $i++) {
            try {
                $reply = $pingClient.Send($IPAddress, $TimeoutMs)

                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $samples.Add([int]$reply.RoundtripTime)
                }
                else {
                    $lost++
                }
            }
            catch {
                $lost++
            }

            if ($i -lt ($measuredPingCount - 1)) {
                Start-Sleep -Milliseconds $measurementIntervalMs
            }
        }
    }
    finally {
        try { $pingClient.Dispose() } catch {}
    }

    if ($samples.Count -eq 0) {
        return [pscustomobject]@{
            Success = $false
            Ms      = $null
            MinMs   = $null
            MaxMs   = $null
            AvgMs   = $null
            Lost    = $lost
            Sent    = $measuredPingCount
            Samples = @()
        }
    }

    $values = $samples.ToArray()
    $min = ($values | Measure-Object -Minimum).Minimum
    $max = ($values | Measure-Object -Maximum).Maximum
    $avg = [int][math]::Round(($values | Measure-Object -Average).Average)

    return [pscustomobject]@{
        Success = $true
        # Keep Ms for backwards compatibility with older reports/code.
        Ms      = $avg
        MinMs   = [int]$min
        MaxMs   = [int]$max
        AvgMs   = [int]$avg
        Lost    = $lost
        Sent    = $measuredPingCount
        Samples = @($values)
    }
}

function Get-PingDisplay {
    param([Parameter(Mandatory = $true)]$Object)

    if (-not $Object.PingOK) {
        return 'NO REPLY'
    }

    $min = $null
    $max = $null
    $lost = 0

    if ($Object.PSObject.Properties.Name -contains 'PingMinMs') {
        $min = $Object.PingMinMs
    }

    if ($Object.PSObject.Properties.Name -contains 'PingMaxMs') {
        $max = $Object.PingMaxMs
    }

    if ($Object.PSObject.Properties.Name -contains 'PingLost' -and $null -ne $Object.PingLost) {
        $lost = [int]$Object.PingLost
    }

    if ($null -ne $min -and $null -ne $max) {
        $text = if ([int]$min -eq [int]$max) {
            "{0}ms" -f $min
        }
        else {
            "{0}-{1}ms" -f $min, $max
        }

        if ($lost -gt 0) {
            $text += " / $lost lost"
        }

        return $text
    }

    # Backwards compatibility when comparing old JSON reports.
    if ($Object.PSObject.Properties.Name -contains 'PingMs' -and $null -ne $Object.PingMs) {
        return ("{0}ms" -f $Object.PingMs)
    }

    return 'OK'
}

function Normalize-MacAddress {
    param([AllowNull()][string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $null
    }

    $hex = ($Address -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()

    if ($hex.Length -ne 12) {
        return $null
    }

    return (($hex -split '(.{2})' | Where-Object { $_ }) -join '-')
}

function Get-IPAddressForMac {
    param([Parameter(Mandatory = $true)][string]$MacAddress)

    $wanted = Normalize-MacAddress $MacAddress
    if (-not $wanted) {
        return $null
    }

    try {
        $neighbor = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.LinkLayerAddress -and
                (Normalize-MacAddress $_.LinkLayerAddress) -eq $wanted -and
                $_.State -ne 'Unreachable'
            } |
            Select-Object -First 1

        if ($neighbor) {
            return [string]$neighbor.IPAddress
        }
    }
    catch {}

    try {
        $raw = (& arp -a 2>&1 | Out-String)

        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match '^\s*((?:\d{1,3}\.){3}\d{1,3})\s+([0-9A-Fa-f:-]{17})\s+') {
                if ((Normalize-MacAddress $matches[2]) -eq $wanted) {
                    return $matches[1]
                }
            }
        }
    }
    catch {}

    return $null
}

function Test-IPv4String {
    param([AllowNull()][string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $false
    }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return $false
    }

    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Get-NeighborMac {
    param([AllowNull()][string]$IPAddress)

    if ([string]::IsNullOrWhiteSpace($IPAddress)) {
        return $null
    }

    try {
        $neighbor = Get-NetNeighbor `
            -IPAddress $IPAddress `
            -AddressFamily IPv4 `
            -ErrorAction Stop |
            Where-Object {
                $_.LinkLayerAddress -and
                $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and
                $_.State -ne 'Unreachable'
            } |
            Select-Object -First 1

        if ($neighbor) {
            return $neighbor.LinkLayerAddress.ToUpperInvariant()
        }
    }
    catch {}

    try {
        $raw = (& arp -a $IPAddress 2>&1 | Out-String)

        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match ('^\s*' + [regex]::Escape($IPAddress) + '\s+([0-9A-Fa-f:-]{17})\s+')) {
                return ($matches[1] -replace ':', '-').ToUpperInvariant()
            }
        }
    }
    catch {}

    return $null
}

function Test-TcpPort {
    param(
        [AllowNull()][string]$IPAddress,
        [AllowNull()][Nullable[int]]$Port,
        [ValidateRange(100, 10000)][int]$TimeoutMs = 1200
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress) -or $null -eq $Port) {
        return $false
    }

    $client = New-Object System.Net.Sockets.TcpClient

    try {
        $async = $client.BeginConnect($IPAddress, [int]$Port, $null, $null)

        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }

        $client.EndConnect($async)
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        try { $client.Close() } catch {}
    }
}

function Get-DeviceMatchKey {
    param([Parameter(Mandatory = $true)]$Device)

    if ($Device.PSObject.Properties.Name -contains 'DeviceId' -and $Device.DeviceId) {
        return ('DEVICEID:{0}' -f ([string]$Device.DeviceId).ToUpperInvariant())
    }

    if ($Device.PSObject.Properties.Name -contains 'MAC' -and $Device.MAC) {
        return ('MAC:{0}' -f ([string]$Device.MAC).ToUpperInvariant())
    }

    if ($Device.PSObject.Properties.Name -contains 'HostName' -and $Device.HostName) {
        return ('HOST:{0}' -f ([string]$Device.HostName).ToUpperInvariant())
    }

    return ('NAME:{0}' -f ([string]$Device.Name).ToUpperInvariant())
}

function New-DeviceResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Model,
        [AllowNull()][string]$HostName,
        [AllowNull()][string]$IPv4,
        [AllowNull()][string]$MAC,
        [AllowNull()][string]$DeviceId,
        [AllowNull()][string]$BluetoothAddress,
        [AllowNull()][string]$OSVersion,
        [AllowNull()][string]$SrcVersion,
        [AllowNull()][Nullable[int]]$Port,
        [bool]$MdnsDiscovered,
        [bool]$MdnsResolved,
        [bool]$PingOK,
        [AllowNull()][Nullable[int]]$PingMs,
        [AllowNull()][Nullable[int]]$PingMinMs,
        [AllowNull()][Nullable[int]]$PingMaxMs,
        [AllowNull()][Nullable[int]]$PingAvgMs,
        [int]$PingLost = 0,
        [int]$PingSent = 5,
        [AllowNull()][int[]]$PingSamples,
        [bool]$TcpOK,
        [AllowNull()][Nullable[int]]$DnsSdInterfaceIndex,
        [AllowNull()][string]$CurrentHomePodVersion,
        [string]$DiscoverySource,
        [AllowNull()][hashtable]$TxtRecords
    )

    $isHomePod = Test-IsHomePodModel $Model

    [pscustomobject]@{
        Name                  = $Name
        Type                  = Get-FriendlyModel $Model
        IsHomePod             = $isHomePod
        Model                 = $Model
        HostName              = $HostName
        IPv4                  = $IPv4
        MAC                   = $MAC
        DeviceId              = $DeviceId
        BluetoothAddress      = $BluetoothAddress
        OSVersion             = $OSVersion
        CurrentHomePodVersion = if ($isHomePod) { $CurrentHomePodVersion } else { $null }
        VersionStatus         = Get-VersionStatus -Installed $OSVersion -Current $CurrentHomePodVersion -IsHomePod $isHomePod
        SrcVersion            = $SrcVersion
        Port                  = $Port
        MdnsDiscovered        = $MdnsDiscovered
        MdnsResolved          = $MdnsResolved
        PingOK                = $PingOK
        PingMs                = $PingMs
        PingMinMs             = $PingMinMs
        PingMaxMs             = $PingMaxMs
        PingAvgMs             = $PingAvgMs
        PingLost              = $PingLost
        PingSent              = $PingSent
        PingSamples           = $PingSamples
        TcpOK                 = $TcpOK
        DnsSdInterfaceIndex   = $DnsSdInterfaceIndex
        DiscoverySource       = $DiscoverySource
        TxtRecords            = $TxtRecords
    }
}

function Add-ReferenceOnlyDevices {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Devices,
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [AllowNull()][string]$CurrentHomePodVersion,
        [switch]$OnlyHomePods
    )

    if (-not (Test-Path -LiteralPath $ReferencePath)) {
        throw "Reference JSON not found: $ReferencePath"
    }

    $reference = Get-Content -LiteralPath $ReferencePath -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not ($reference.PSObject.Properties.Name -contains 'Devices')) {
        throw "Reference JSON does not look like an AppleHomePodDiag report: $ReferencePath"
    }

    $knownKeys = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)

    foreach ($device in $Devices) {
        [void]$knownKeys.Add((Get-DeviceMatchKey $device))
    }

    foreach ($refDevice in @($reference.Devices)) {
        $key = Get-DeviceMatchKey $refDevice

        if ($knownKeys.Contains($key)) {
            continue
        }

        $model = if ($refDevice.PSObject.Properties.Name -contains 'Model') { [string]$refDevice.Model } else { $null }
        $isHomePod = Test-IsHomePodModel $model

        if ($OnlyHomePods -and -not $isHomePod) {
            continue
        }

        $ip = if ($refDevice.PSObject.Properties.Name -contains 'IPv4') { [string]$refDevice.IPv4 } else { $null }

        $port = $null
        if ($refDevice.PSObject.Properties.Name -contains 'Port' -and $null -ne $refDevice.Port) {
            $port = [int]$refDevice.Port
        }

        # This is the key diagnostic point: the device was NOT discovered by
        # mDNS on this node, but we can still test its known IP from a reference.
        $ping = Test-PingAddress $ip
        $mac = if ($ping.Success) { Get-NeighborMac $ip } else { $null }
        $tcp = Test-TcpPort -IPAddress $ip -Port $port

        $device = New-DeviceResult `
            -Name ([string]$refDevice.Name) `
            -Model $model `
            -HostName $(if ($refDevice.PSObject.Properties.Name -contains 'HostName') { [string]$refDevice.HostName } else { $null }) `
            -IPv4 $ip `
            -MAC $(if ($mac) { $mac } elseif ($refDevice.PSObject.Properties.Name -contains 'MAC') { [string]$refDevice.MAC } else { $null }) `
            -DeviceId $(if ($refDevice.PSObject.Properties.Name -contains 'DeviceId') { [string]$refDevice.DeviceId } else { $null }) `
            -BluetoothAddress $(if ($refDevice.PSObject.Properties.Name -contains 'BluetoothAddress') { [string]$refDevice.BluetoothAddress } else { $null }) `
            -OSVersion $(if ($refDevice.PSObject.Properties.Name -contains 'OSVersion') { [string]$refDevice.OSVersion } else { $null }) `
            -SrcVersion $(if ($refDevice.PSObject.Properties.Name -contains 'SrcVersion') { [string]$refDevice.SrcVersion } else { $null }) `
            -Port $port `
            -MdnsDiscovered $false `
            -MdnsResolved $false `
            -PingOK ([bool]$ping.Success) `
            -PingMs $ping.Ms `
            -PingMinMs $ping.MinMs `
            -PingMaxMs $ping.MaxMs `
            -PingAvgMs $ping.AvgMs `
            -PingLost $ping.Lost `
            -PingSent $ping.Sent `
            -PingSamples $ping.Samples `
            -TcpOK ([bool]$tcp) `
            -DnsSdInterfaceIndex $null `
            -CurrentHomePodVersion $CurrentHomePodVersion `
            -DiscoverySource 'Reference IP (not discovered by mDNS on this node)' `
            -TxtRecords $null

        $Devices.Add($device)
        [void]$knownKeys.Add($key)
    }
}

function Convert-ToHtmlReport {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][array]$Devices,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

    function ConvertTo-HtmlEncoded([AllowNull()][object]$Value) {
        if ($null -eq $Value) { return '' }
        return [System.Web.HttpUtility]::HtmlEncode([string]$Value)
    }

    function New-HtmlRows {
        param([array]$Items)

        $rows = foreach ($device in ($Items | Sort-Object Type, Name)) {
            $class = 'ok'

            if (-not $device.MdnsDiscovered -or -not $device.PingOK -or -not $device.TcpOK) {
                $class = 'bad'
            }
            elseif ($device.VersionStatus -eq 'UPDATE AVAILABLE') {
                $class = 'warn'
            }

            @"
<tr class="$class">
<td>$(ConvertTo-HtmlEncoded $device.Type)</td>
<td>$(ConvertTo-HtmlEncoded $device.Name)</td>
<td>$(ConvertTo-HtmlEncoded $device.IPv4)</td>
<td>$(ConvertTo-HtmlEncoded $device.MAC)</td>
<td>$(ConvertTo-HtmlEncoded $device.OSVersion)</td>
<td>$(ConvertTo-HtmlEncoded $device.VersionStatus)</td>
<td>$(ConvertTo-HtmlEncoded $device.MdnsDiscovered)</td>
<td>$(ConvertTo-HtmlEncoded $device.MdnsResolved)</td>
<td>$(ConvertTo-HtmlEncoded $(Get-PingDisplay $device))</td>
<td>$(ConvertTo-HtmlEncoded $(if ($device.TcpOK) { "OK:$($device.Port)" } else { "FAIL:$($device.Port)" }))</td>
<td>$(ConvertTo-HtmlEncoded $device.DiscoverySource)</td>
</tr>
"@
        }

        return ($rows -join "`n")
    }

    $homePodRows = New-HtmlRows @($Devices | Where-Object { $_.IsHomePod })
    $otherRows   = New-HtmlRows @($Devices | Where-Object { -not $_.IsHomePod })

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>AppleHomePodDiag - $(ConvertTo-HtmlEncoded $Metadata.NodeName)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}
h1,h2{margin-bottom:.45em}
table{border-collapse:collapse;width:100%;margin:12px 0 28px 0}
th,td{border:1px solid #ccc;padding:6px 8px;text-align:left;font-size:13px;vertical-align:top}
th{background:#eee}
.ok{background:#f4fff4}
.warn{background:#fff8dc}
.bad{background:#fff0f0}
.small{font-size:12px;color:#666}
code{background:#f4f4f4;padding:1px 4px}
</style>
</head>
<body>
<h1>AppleHomePodDiag</h1>
<table>
<tr><th>Scan time</th><td>$(ConvertTo-HtmlEncoded $Metadata.Timestamp)</td></tr>
<tr><th>Node</th><td>$(ConvertTo-HtmlEncoded $Metadata.NodeName)</td></tr>
<tr><th>Computer</th><td>$(ConvertTo-HtmlEncoded $Metadata.ComputerName)</td></tr>
<tr><th>SSID</th><td>$(ConvertTo-HtmlEncoded $Metadata.WLAN.SSID)</td></tr>
<tr><th>BSSID</th><td>$(ConvertTo-HtmlEncoded $Metadata.WLAN.BSSID)</td></tr>
<tr><th>Band / Channel</th><td>$(ConvertTo-HtmlEncoded ("{0} / {1}" -f $Metadata.WLAN.Band, $Metadata.WLAN.Channel))</td></tr>
<tr><th>Local IPv4</th><td>$(ConvertTo-HtmlEncoded $Metadata.WLAN.IPv4)</td></tr>
<tr><th>Public HomePod version</th><td>$(ConvertTo-HtmlEncoded ("{0} ({1})" -f $Metadata.CurrentHomePodVersion, $Metadata.CurrentVersionSource))</td></tr>
<tr><th>Reference report</th><td>$(ConvertTo-HtmlEncoded $Metadata.ReferenceJson)</td></tr>
</table>

<h2>AirPlay devices - HomePods</h2>
<table>
<thead>
<tr>
<th>Type</th><th>Name</th><th>IPv4</th><th>MAC</th><th>OS</th><th>Firmware</th>
<th>mDNS found</th><th>.local resolved</th><th>Ping</th><th>AirPlay TCP</th><th>Source</th>
</tr>
</thead>
<tbody>
$homePodRows
</tbody>
</table>

<h2>AirPlay devices - Other devices</h2>
<table>
<thead>
<tr>
<th>Type</th><th>Name</th><th>IPv4</th><th>MAC</th><th>OS</th><th>Firmware</th>
<th>mDNS found</th><th>.local resolved</th><th>Ping</th><th>AirPlay TCP</th><th>Source</th>
</tr>
</thead>
<tbody>
$otherRows
</tbody>
</table>

<p class="small">
Original project: <code>$Script:ProjectUrl</code><br>
The tool is diagnostic only and does not change HomePod, Wi-Fi, firewall or router settings.
</p>
</body>
</html>
"@

    [System.IO.File]::WriteAllText(
        $Path,
        $html,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Invoke-CompareReports {
    param([Parameter(Mandatory = $true)][string[]]$Files)

    Write-Section 'Compare scan reports'

    $reports = New-Object 'System.Collections.Generic.List[object]'

    foreach ($file in $Files) {
        if (-not (Test-Path -LiteralPath $file)) {
            throw "Report not found: $file"
        }

        $report = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json

        if (-not ($report.PSObject.Properties.Name -contains 'Metadata') -or
            -not ($report.PSObject.Properties.Name -contains 'Devices')) {
            throw "Not a valid AppleHomePodDiag JSON report: $file"
        }

        $reports.Add($report)
    }

    $allKeys = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)

    foreach ($report in $reports) {
        foreach ($device in @($report.Devices)) {
            [void]$allKeys.Add((Get-DeviceMatchKey $device))
        }
    }

    $matrix = New-Object 'System.Collections.Generic.List[object]'

    foreach ($key in ($allKeys | Sort-Object)) {
        $friendlyName = $null
        $friendlyType = $null

        foreach ($report in $reports) {
            $match = $null

            foreach ($device in @($report.Devices)) {
                if ((Get-DeviceMatchKey $device) -eq $key) {
                    $match = $device
                    break
                }
            }

            if ($match) {
                if (-not $friendlyName) { $friendlyName = [string]$match.Name }
                if (-not $friendlyType) { $friendlyType = [string]$match.Type }

                $matrix.Add([pscustomobject]@{
                    Device        = $friendlyName
                    Type          = $friendlyType
                    Node          = [string]$report.Metadata.NodeName
                    WLAN          = ('{0} / Ch {1}' -f $report.Metadata.WLAN.Band, $report.Metadata.WLAN.Channel)
                    BSSID         = [string]$report.Metadata.WLAN.BSSID
                    MdnsDiscovered = if ($match.MdnsDiscovered) { 'YES' } else { 'NO' }
                    IPv4          = [string]$match.IPv4
                    Ping          = Get-PingDisplay $match
                    AirPlayTcp    = if ($match.TcpOK) { "OK:$($match.Port)" } else { "FAIL:$($match.Port)" }
                    OS            = [string]$match.OSVersion
                    Firmware      = [string]$match.VersionStatus
                    Source        = [string]$match.DiscoverySource
                })
            }
            else {
                $matrix.Add([pscustomobject]@{
                    Device        = if ($friendlyName) { $friendlyName } else { $key }
                    Type          = $friendlyType
                    Node          = [string]$report.Metadata.NodeName
                    WLAN          = ('{0} / Ch {1}' -f $report.Metadata.WLAN.Band, $report.Metadata.WLAN.Channel)
                    BSSID         = [string]$report.Metadata.WLAN.BSSID
                    MdnsDiscovered = 'NO RECORD'
                    IPv4          = ''
                    Ping          = '-'
                    AirPlayTcp    = '-'
                    OS            = ''
                    Firmware      = '-'
                    Source        = '-'
                })
            }
        }
    }

    $matrix |
        Sort-Object Device, Node |
        Format-Table Device, Node, WLAN, MdnsDiscovered, IPv4, Ping, AirPlayTcp, OS, Firmware -AutoSize

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvPath = Join-Path (Get-Location) "AppleHomePodDiag-Compare-$stamp.csv"

    $matrix |
        Sort-Object Device, Node |
        Export-Csv -LiteralPath $csvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host "Comparison CSV: $csvPath" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Compare mode
# -----------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Compare') {
    Invoke-CompareReports -Files $Compare
    return
}

# -----------------------------------------------------------------------------
# Scan mode
# -----------------------------------------------------------------------------

$focusParameterCount = @(
    @($Name, $IP, $MAC) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
).Count

if ($focusParameterCount -gt 1) {
    throw 'Use only one focused diagnostic selector at a time: -Name, -IP or -MAC.'
}

if ($IP -and -not (Test-IPv4String $IP)) {
    throw "Invalid IPv4 address supplied to -IP: $IP"
}

if ($MAC -and -not (Normalize-MacAddress $MAC)) {
    throw "Invalid MAC address supplied to -MAC: $MAC"
}

$focusedMode = $focusParameterCount -eq 1
$focusedSelector = $null
$focusedValue = $null

if ($Name) {
    $focusedSelector = 'Name'
    $focusedValue = $Name
}
elseif ($IP) {
    $focusedSelector = 'IP'
    $focusedValue = $IP
}
elseif ($MAC) {
    $focusedSelector = 'MAC'
    $focusedValue = Normalize-MacAddress $MAC
}

$dnsSd = Get-DnsSdPath

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

Write-Host ''
Write-Host ('=' * 86) -ForegroundColor DarkGray
Write-Host (" {0} {1}" -f $Script:ToolName, $Script:ToolVersion) -ForegroundColor Cyan
Write-Host " Copyright (c) 2026 Stefan Kittel <info@kittel.online>"
Write-Host " Project: https://github.com/Skittel/AppleHomePodDiag"
Write-Host ('=' * 86) -ForegroundColor DarkGray
Write-Host "Node:            $NodeName"
Write-Host "dns-sd.exe:      $dnsSd"
Write-Host "Discovery time:  $ScanSeconds seconds"

if ($focusedMode) {
    Write-Host ("Focused target:  {0} = {1}" -f $focusedSelector, $focusedValue) -ForegroundColor Yellow
}

if ($ReferenceJson) {
    Write-Host "Reference JSON:  $ReferenceJson"
}

$wlan = Get-WlanInfo

Write-Section 'Local Wi-Fi connection'
$wlan |
    Select-Object Interface, State, SSID, BSSID, Band, Channel, RadioType, Signal, IPv4 |
    Format-List

$currentVersion = Get-CurrentHomePodVersion `
    -SkipOnline:$SkipOnlineVersionCheck `
    -Expected $ExpectedHomePodVersion

if ($currentVersion.Version) {
    Write-Host ("Latest public HomePod version: {0} ({1})" -f $currentVersion.Version, $currentVersion.Source) -ForegroundColor Green
}
else {
    Write-Host ("Latest public HomePod version: unknown ({0})" -f $currentVersion.Source) -ForegroundColor Yellow

    if ($currentVersion.Error) {
        Write-Host ("Version check detail: {0}" -f $currentVersion.Error) -ForegroundColor DarkYellow
    }
}

Write-Section 'Bonjour / mDNS discovery: _airplay._tcp.local'
Write-Host 'Discovering AirPlay services...' -ForegroundColor Gray

$instances = @(Get-AirPlayInstances -DnsSd $dnsSd -Seconds $ScanSeconds)

# Capture the same services in zone-file form as well. Besides being more
# efficient for TXT/SRV data, this avoids the Windows dns-sd.exe Unicode
# command-line issue when an instance contains characters such as ä, ü or ‘.
$zoneDetails = Get-AirPlayZoneDetails -DnsSd $dnsSd -Seconds $ScanSeconds

if ($instances.Count -eq 0 -and $zoneDetails.Count -gt 0) {
    $instances = @($zoneDetails.Keys)
}

# Focused mode narrows the full Bonjour snapshot down to one device. For -IP
# and -MAC we correlate the selector with Bonjour records first. If correlation
# is impossible, a direct IP-only diagnostic result is created later.
$focusedDirectIP = $null
$focusedMatchedInstance = $null

if ($focusedMode) {
    if ($focusedSelector -eq 'Name') {
        $focusedMatchedInstance = @(
            $instances | Where-Object { $_ -eq $focusedValue }
        ) | Select-Object -First 1
    }
    elseif ($focusedSelector -eq 'IP') {
        $focusedDirectIP = $focusedValue

        foreach ($candidateName in $instances) {
            $candidateDetail = $null

            if ($zoneDetails.ContainsKey($candidateName)) {
                $candidateDetail = $zoneDetails[$candidateName]
            }

            if ($null -eq $candidateDetail -or -not $candidateDetail.HostName) {
                $candidateDetail = Get-AirPlayDetails -DnsSd $dnsSd -InstanceName $candidateName
            }

            if ($candidateDetail.HostName) {
                $candidateIP = Resolve-MdnsIPv4 -DnsSd $dnsSd -HostName $candidateDetail.HostName

                if ($candidateIP -eq $focusedValue) {
                    $focusedMatchedInstance = $candidateName
                    break
                }
            }
        }
    }
    elseif ($focusedSelector -eq 'MAC') {
        $wantedMac = Normalize-MacAddress $focusedValue
        $focusedDirectIP = Get-IPAddressForMac -MacAddress $wantedMac

        # First try AirPlay deviceid because it is available without touching
        # every device. It may or may not be the WLAN MAC, so neighbor MAC is
        # checked as a fallback.
        foreach ($candidateName in $instances) {
            $candidateDetail = $null

            if ($zoneDetails.ContainsKey($candidateName)) {
                $candidateDetail = $zoneDetails[$candidateName]
            }

            if ($null -eq $candidateDetail -or $candidateDetail.TXT.Count -eq 0) {
                $candidateDetail = Get-AirPlayDetails -DnsSd $dnsSd -InstanceName $candidateName
            }

            if ($candidateDetail.TXT.Contains('deviceid')) {
                $candidateDeviceId = Normalize-MacAddress ([string]$candidateDetail.TXT['deviceid'])

                if ($candidateDeviceId -eq $wantedMac) {
                    $focusedMatchedInstance = $candidateName
                    break
                }
            }

            if ($candidateDetail.HostName) {
                $candidateIP = Resolve-MdnsIPv4 -DnsSd $dnsSd -HostName $candidateDetail.HostName

                if ($candidateIP) {
                    # Populate/refresh the neighbor table before asking for MAC.
                    [void](Test-PingAddress $candidateIP)
                    $candidateMac = Normalize-MacAddress (Get-NeighborMac $candidateIP)

                    if ($candidateMac -eq $wantedMac) {
                        $focusedMatchedInstance = $candidateName
                        $focusedDirectIP = $candidateIP
                        break
                    }
                }
            }
        }
    }

    if ($focusedMatchedInstance) {
        $instances = @($focusedMatchedInstance)
    }
    else {
        $instances = @()
    }
}

if ($instances.Count -eq 0 -and -not $focusedMode) {
    Write-Warning 'No _airplay._tcp services were discovered. This is itself an important diagnostic result.'
}

$devices = New-Object 'System.Collections.Generic.List[object]'
$index = 0

foreach ($instance in $instances) {
    $index++

    Write-Progress `
        -Activity 'Inspecting AirPlay devices' `
        -Status ("{0}/{1}: {2}" -f $index, $instances.Count, $instance) `
        -PercentComplete (($index / [math]::Max(1, $instances.Count)) * 100)

    # Prefer complete -Z data. It is robust for Unicode instance names because
    # the instance does not need to be passed back as a command-line argument.
    $detail = $null

    if ($zoneDetails.ContainsKey($instance)) {
        $candidate = $zoneDetails[$instance]

        if ($candidate.HostName -and $candidate.Port -and $candidate.TXT.Count -gt 0) {
            $detail = $candidate
        }
    }

    # Fallback for plain ASCII names if the -Z snapshot did not contain the
    # complete SRV/TXT record. This also keeps devices such as NAD M10 working.
    if ($null -eq $detail) {
        $detail = Get-AirPlayDetails -DnsSd $dnsSd -InstanceName $instance
    }

    $model = if ($detail.TXT.Contains('model')) { [string]$detail.TXT['model'] } else { $null }
    $isHomePod = Test-IsHomePodModel $model

    if ($HomePodsOnly -and -not $isHomePod) {
        continue
    }

    $osVersion = if ($detail.TXT.Contains('osvers')) { [string]$detail.TXT['osvers'] } else { $null }
    $srcVersion = if ($detail.TXT.Contains('srcvers')) { [string]$detail.TXT['srcvers'] } else { $null }
    $deviceId = if ($detail.TXT.Contains('deviceid')) { [string]$detail.TXT['deviceid'] } else { $null }
    $bluetoothAddress = if ($detail.TXT.Contains('btaddr')) { [string]$detail.TXT['btaddr'] } else { $null }

    $ip = Resolve-MdnsIPv4 -DnsSd $dnsSd -HostName $detail.HostName
    $ping = Test-PingAddress $ip

    # Ping normally creates or refreshes the neighbor/ARP entry.
    $mac = Get-NeighborMac $ip
    $tcp = Test-TcpPort -IPAddress $ip -Port $detail.Port

    $txtHash = @{}
    foreach ($key in $detail.TXT.Keys) {
        $txtHash[$key] = $detail.TXT[$key]
    }

    $device = New-DeviceResult `
        -Name $instance `
        -Model $model `
        -HostName $detail.HostName `
        -IPv4 $ip `
        -MAC $mac `
        -DeviceId $deviceId `
        -BluetoothAddress $bluetoothAddress `
        -OSVersion $osVersion `
        -SrcVersion $srcVersion `
        -Port $detail.Port `
        -MdnsDiscovered $true `
        -MdnsResolved ([bool]$ip) `
        -PingOK ([bool]$ping.Success) `
        -PingMs $ping.Ms `
        -PingMinMs $ping.MinMs `
        -PingMaxMs $ping.MaxMs `
        -PingAvgMs $ping.AvgMs `
        -PingLost $ping.Lost `
        -PingSent $ping.Sent `
        -PingSamples $ping.Samples `
        -TcpOK ([bool]$tcp) `
        -DnsSdInterfaceIndex $detail.InterfaceIndex `
        -CurrentHomePodVersion $currentVersion.Version `
        -DiscoverySource 'mDNS / Bonjour' `
        -TxtRecords $txtHash

    $devices.Add($device)
}

# If focused lookup by IP/MAC could not be correlated with Bonjour, still run
# the direct network checks. Model/OS/TXT data remain unknown because they are
# Bonjour metadata, but the result clearly shows whether IP connectivity works.
if ($focusedMode -and $devices.Count -eq 0) {
    if ($focusedSelector -eq 'Name') {
        Write-Warning ("The AirPlay/Bonjour name '{0}' was not discovered in this scan." -f $focusedValue)
    }
    else {
        if (-not $focusedDirectIP -and $focusedSelector -eq 'MAC') {
            $focusedDirectIP = Get-IPAddressForMac -MacAddress $focusedValue
        }

        if ($focusedDirectIP) {
            $ping = Test-PingAddress $focusedDirectIP
            $neighborMac = Get-NeighborMac $focusedDirectIP
            $tcp = Test-TcpPort -IPAddress $focusedDirectIP -Port 7000

            $directName = if ($focusedSelector -eq 'MAC') {
                "MAC $focusedValue"
            } else {
                "IP $focusedDirectIP"
            }

            $device = New-DeviceResult `
                -Name $directName `
                -Model $null `
                -HostName $null `
                -IPv4 $focusedDirectIP `
                -MAC $(if ($neighborMac) { $neighborMac } elseif ($focusedSelector -eq 'MAC') { $focusedValue } else { $null }) `
                -DeviceId $null `
                -BluetoothAddress $null `
                -OSVersion $null `
                -SrcVersion $null `
                -Port 7000 `
                -MdnsDiscovered $false `
                -MdnsResolved $false `
                -PingOK ([bool]$ping.Success) `
                -PingMs $ping.Ms `
                -PingMinMs $ping.MinMs `
                -PingMaxMs $ping.MaxMs `
                -PingAvgMs $ping.AvgMs `
                -PingLost $ping.Lost `
                -PingSent $ping.Sent `
                -PingSamples $ping.Samples `
                -TcpOK ([bool]$tcp) `
                -DnsSdInterfaceIndex $null `
                -CurrentHomePodVersion $currentVersion.Version `
                -DiscoverySource 'Direct focused diagnostic; no Bonjour correlation' `
                -TxtRecords $null

            $devices.Add($device)
        }
        else {
            Write-Warning ("The requested MAC address {0} could not be mapped to an IPv4 address." -f $focusedValue)
        }
    }
}

Write-Progress -Activity 'Inspecting AirPlay devices' -Completed

if ($ReferenceJson) {
    Write-Section 'Testing devices missing from mDNS using reference IP data'

    Add-ReferenceOnlyDevices `
        -Devices $devices `
        -ReferencePath $ReferenceJson `
        -CurrentHomePodVersion $currentVersion.Version `
        -OnlyHomePods:$HomePodsOnly
}

# Convert the generic List to a real Object[] once. Windows PowerShell 5.1
# can throw "Argument types do not match" when @($genericList) is used during
# JSON/CSV/report generation.
$deviceArray = $devices.ToArray()

$metadata = [pscustomobject]@{
    Tool                  = $Script:ToolName
    ToolVersion           = $Script:ToolVersion
    ProjectUrl            = $Script:ProjectUrl
    Timestamp             = (Get-Date).ToString('o')
    NodeName              = $NodeName
    ComputerName          = $env:COMPUTERNAME
    UserName              = $env:USERNAME
    WLAN                  = $wlan
    CurrentHomePodVersion = $currentVersion.Version
    CurrentVersionSource  = $currentVersion.Source
    CurrentVersionUrl     = $currentVersion.Url
    CurrentVersionError   = $currentVersion.Error
    DnsSdPath             = $dnsSd
    ScanSeconds           = $ScanSeconds
    ReferenceJson         = $ReferenceJson
    FocusedMode           = $focusedMode
    FocusedSelector       = $focusedSelector
    FocusedValue          = $focusedValue
}

Write-Section 'Results'

function Show-DeviceTable {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][array]$Items
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor DarkGray

    if ($Items.Count -eq 0) {
        Write-Host 'No devices found.' -ForegroundColor DarkGray
        return
    }

    $Items |
        Sort-Object Type, Name |
        Select-Object `
            Type,
            Name,
            IPv4,
            MAC,
            OSVersion,
            VersionStatus,
            @{ Name = 'mDNS'; Expression = { if ($_.MdnsDiscovered) { 'YES' } else { 'NO' } } },
            @{ Name = 'Ping'; Expression = { Get-PingDisplay $_ } },
            @{ Name = 'TCP'; Expression = {
                if ($_.TcpOK) { "OK:$($_.Port)" } else { "FAIL:$($_.Port)" }
            }} |
        Format-Table -AutoSize
}

$homePodDevices = @(
    $deviceArray |
        Where-Object { $_.IsHomePod } |
        Sort-Object Type, Name
)

$otherAirPlayDevices = @(
    $deviceArray |
        Where-Object { -not $_.IsHomePod } |
        Sort-Object Type, Name
)

if ($deviceArray.Count -gt 0) {
    Show-DeviceTable -Title 'AirPlay devices - HomePods' -Items $homePodDevices
    Show-DeviceTable -Title 'AirPlay devices - Other devices' -Items $otherAirPlayDevices

    if ($focusedMode -and $deviceArray.Count -eq 1) {
        Write-Section 'Focused device details'

        $deviceArray[0] |
            Select-Object `
                Name,
                Type,
                Model,
                HostName,
                IPv4,
                MAC,
                DeviceId,
                BluetoothAddress,
                OSVersion,
                CurrentHomePodVersion,
                VersionStatus,
                SrcVersion,
                Port,
                MdnsDiscovered,
                MdnsResolved,
                PingOK,
                PingMinMs,
                PingMaxMs,
                PingAvgMs,
                PingLost,
                PingSent,
                PingSamples,
                TcpOK,
                DnsSdInterfaceIndex,
                DiscoverySource |
            Format-List

        if ($deviceArray[0].TxtRecords) {
            Write-Host 'Bonjour TXT records:' -ForegroundColor Cyan
            $deviceArray[0].TxtRecords.GetEnumerator() |
                Sort-Object Name |
                Format-Table Name, Value -AutoSize
        }
    }
}
else {
    Write-Host 'No matching devices found.' -ForegroundColor Yellow
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeNode = $NodeName -replace '[^A-Za-z0-9_.-]', '_'
$baseName = "AppleHomePodDiag-$safeNode-$stamp"

$jsonPath = Join-Path $OutputDirectory ($baseName + '.json')
$csvPath = Join-Path $OutputDirectory ($baseName + '.csv')
$htmlPath = Join-Path $OutputDirectory ($baseName + '.html')

$report = [pscustomobject]@{
    Metadata = $metadata
    Devices  = $deviceArray
}

$report |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $jsonPath -Encoding UTF8

$deviceArray |
    Sort-Object Type, Name |
    Export-Csv -LiteralPath $csvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

try {
    Convert-ToHtmlReport -Metadata $metadata -Devices $deviceArray -Path $htmlPath
}
catch {
    Write-Warning "HTML report could not be created: $($_.Exception.Message)"
    $htmlPath = $null
}

Write-Section 'Summary'

$homePods = @($deviceArray | Where-Object { $_.IsHomePod })
$updates = @($homePods | Where-Object { $_.VersionStatus -eq 'UPDATE AVAILABLE' })
$notDiscovered = @($deviceArray | Where-Object { -not $_.MdnsDiscovered })
$resolvedFailures = @($deviceArray | Where-Object { $_.MdnsDiscovered -and -not $_.MdnsResolved })
$pingFailures = @($deviceArray | Where-Object { $_.IPv4 -and -not $_.PingOK })
$pingLossDevices = @($deviceArray | Where-Object { $_.IPv4 -and $_.PingOK -and $_.PingLost -gt 0 })
$tcpFailures = @($deviceArray | Where-Object { $_.IPv4 -and -not $_.TcpOK })

Write-Host ("AirPlay records/devices:      {0}" -f $deviceArray.Count)
Write-Host ("HomePods:                     {0}" -f $homePods.Count)
Write-Host ("HomePods with update:         {0}" -f $updates.Count)
Write-Host ("Missing from mDNS (reference):{0}" -f $notDiscovered.Count)
Write-Host (".local resolution failures:   {0}" -f $resolvedFailures.Count)
Write-Host ("Ping failures:                {0}" -f $pingFailures.Count)
Write-Host ("Ping partial loss:            {0}" -f $pingLossDevices.Count)
Write-Host ("AirPlay TCP failures:         {0}" -f $tcpFailures.Count)

if ($notDiscovered.Count -gt 0) {
    Write-Host ''
    Write-Host 'Important:' -ForegroundColor Yellow
    Write-Host 'Devices marked mDNS=NO came from the reference report and were not discovered'
    Write-Host 'by Bonjour on this node. If Ping/TCP still show OK, this strongly suggests an'
    Write-Host 'mDNS/multicast discovery problem rather than general IP connectivity.'
}

Write-Host ''
Write-Host "JSON: $jsonPath" -ForegroundColor Green
Write-Host "CSV:  $csvPath" -ForegroundColor Green
if ($htmlPath) {
    Write-Host "HTML: $htmlPath" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Recommended two-node workflow:' -ForegroundColor Cyan
Write-Host '  Node A: .\AppleHomePodDiag.ps1 -NodeName "AP1-24GHz"'
Write-Host '  Node B: .\AppleHomePodDiag.ps1 -NodeName "AP2-5GHz" -ReferenceJson "<Node-A.json>"'
Write-Host '  Compare: .\AppleHomePodDiag.ps1 -Compare "<Node-A.json>","<Node-B.json>"'
