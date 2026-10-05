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

.EXAMPLES
    .\AppleHomePodDiag.ps1

    .\AppleHomePodDiag.ps1 -NodeName "AP1-24GHz"

    .\AppleHomePodDiag.ps1 -NodeName "AP2-5GHz" -ReferenceJson ".\AP1.json"

    .\AppleHomePodDiag.ps1 -HomePodsOnly -ScanSeconds 8

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

    [Parameter(Mandatory = $true, ParameterSetName = 'Compare')]
    [ValidateCount(2, 20)]
    [string[]]$Compare
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:ToolName = 'AppleHomePodDiag'
$Script:ToolVersion = '1.0.0'
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

    # Apple dns-sd output is UTF-8. Without this, umlauts can appear corrupted.
    try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    try { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch {}

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()

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
    try { $stdout = $process.StandardOutput.ReadToEnd() } catch {}
    try { $stderr = $process.StandardError.ReadToEnd() } catch {}

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

    return @($names)
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

    return $null
}

function Test-PingAddress {
    param([AllowNull()][string]$IPAddress)

    if ([string]::IsNullOrWhiteSpace($IPAddress)) {
        return [pscustomobject]@{
            Success = $false
            Ms      = $null
        }
    }

    try {
        $reply = Test-Connection -ComputerName $IPAddress -Count 1 -ErrorAction Stop |
            Select-Object -First 1

        $responseMs = $null

        if ($reply.PSObject.Properties.Name -contains 'ResponseTime') {
            $responseMs = [int]$reply.ResponseTime
        }
        elseif ($reply.PSObject.Properties.Name -contains 'Latency') {
            $responseMs = [int]$reply.Latency
        }

        return [pscustomobject]@{
            Success = $true
            Ms      = $responseMs
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Ms      = $null
        }
    }
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

    function H([AllowNull()][object]$Value) {
        if ($null -eq $Value) { return '' }
        return [System.Web.HttpUtility]::HtmlEncode([string]$Value)
    }

    $rows = foreach ($device in $Devices) {
        $class = 'ok'

        if (-not $device.MdnsDiscovered -or -not $device.PingOK -or -not $device.TcpOK) {
            $class = 'bad'
        }
        elseif ($device.VersionStatus -eq 'UPDATE AVAILABLE') {
            $class = 'warn'
        }

        @"
<tr class="$class">
<td>$(H $device.Name)</td>
<td>$(H $device.Type)</td>
<td>$(H $device.IPv4)</td>
<td>$(H $device.MAC)</td>
<td>$(H $device.OSVersion)</td>
<td>$(H $device.VersionStatus)</td>
<td>$(H $device.MdnsDiscovered)</td>
<td>$(H $device.MdnsResolved)</td>
<td>$(H $(if ($device.PingOK) { if ($null -ne $device.PingMs) { "$($device.PingMs) ms" } else { 'OK' } } else { 'FAIL' }))</td>
<td>$(H $(if ($device.TcpOK) { "OK:$($device.Port)" } else { "FAIL:$($device.Port)" }))</td>
<td>$(H $device.DiscoverySource)</td>
</tr>
"@
    }

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>AppleHomePodDiag - $(H $Metadata.NodeName)</title>
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
<tr><th>Scan time</th><td>$(H $Metadata.Timestamp)</td></tr>
<tr><th>Node</th><td>$(H $Metadata.NodeName)</td></tr>
<tr><th>Computer</th><td>$(H $Metadata.ComputerName)</td></tr>
<tr><th>SSID</th><td>$(H $Metadata.WLAN.SSID)</td></tr>
<tr><th>BSSID</th><td>$(H $Metadata.WLAN.BSSID)</td></tr>
<tr><th>Band / Channel</th><td>$(H ("{0} / {1}" -f $Metadata.WLAN.Band, $Metadata.WLAN.Channel))</td></tr>
<tr><th>Local IPv4</th><td>$(H $Metadata.WLAN.IPv4)</td></tr>
<tr><th>Public HomePod version</th><td>$(H ("{0} ({1})" -f $Metadata.CurrentHomePodVersion, $Metadata.CurrentVersionSource))</td></tr>
<tr><th>Reference report</th><td>$(H $Metadata.ReferenceJson)</td></tr>
</table>

<h2>AirPlay devices</h2>
<table>
<thead>
<tr>
<th>Name</th><th>Type</th><th>IPv4</th><th>MAC</th><th>OS</th><th>Firmware</th>
<th>mDNS found</th><th>.local resolved</th><th>Ping</th><th>AirPlay TCP</th><th>Source</th>
</tr>
</thead>
<tbody>
$($rows -join "`n")
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
                    Ping          = if ($match.PingOK) {
                                        if ($null -ne $match.PingMs) { "$($match.PingMs) ms" } else { 'OK' }
                                    } else { 'FAIL' }
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

$dnsSd = Get-DnsSdPath

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

Write-Section "$Script:ToolName $Script:ToolVersion"
Write-Host "Node:            $NodeName"
Write-Host "dns-sd.exe:      $dnsSd"
Write-Host "Discovery time:  $ScanSeconds seconds"
Write-Host "Project:         $Script:ProjectUrl"

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

if ($instances.Count -eq 0) {
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

    $detail = Get-AirPlayDetails -DnsSd $dnsSd -InstanceName $instance

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
        -TcpOK ([bool]$tcp) `
        -DnsSdInterfaceIndex $detail.InterfaceIndex `
        -CurrentHomePodVersion $currentVersion.Version `
        -DiscoverySource 'mDNS / Bonjour' `
        -TxtRecords $txtHash

    $devices.Add($device)
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
}

Write-Section 'Results'

$display = @(
    $devices |
        Sort-Object @{ Expression = 'IsHomePod'; Descending = $true }, Name |
        Select-Object `
            Name,
            Type,
            IPv4,
            MAC,
            OSVersion,
            VersionStatus,
            @{ Name = 'mDNS'; Expression = { if ($_.MdnsDiscovered) { 'YES' } else { 'NO' } } },
            @{ Name = 'Ping'; Expression = {
                if ($_.PingOK) {
                    if ($null -ne $_.PingMs) { "$($_.PingMs)ms" } else { 'OK' }
                } else { 'FAIL' }
            }},
            @{ Name = 'TCP'; Expression = {
                if ($_.TcpOK) { "OK:$($_.Port)" } else { "FAIL:$($_.Port)" }
            }}
)

if ($display.Count -gt 0) {
    $display | Format-Table -AutoSize
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
    Devices  = @($devices)
}

$report |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $jsonPath -Encoding UTF8

@($devices) |
    Export-Csv -LiteralPath $csvPath -Delimiter ';' -NoTypeInformation -Encoding UTF8

try {
    Convert-ToHtmlReport -Metadata $metadata -Devices @($devices) -Path $htmlPath
}
catch {
    Write-Warning "HTML report could not be created: $($_.Exception.Message)"
    $htmlPath = $null
}

Write-Section 'Summary'

$homePods = @($devices | Where-Object { $_.IsHomePod })
$updates = @($homePods | Where-Object { $_.VersionStatus -eq 'UPDATE AVAILABLE' })
$notDiscovered = @($devices | Where-Object { -not $_.MdnsDiscovered })
$resolvedFailures = @($devices | Where-Object { $_.MdnsDiscovered -and -not $_.MdnsResolved })
$pingFailures = @($devices | Where-Object { $_.IPv4 -and -not $_.PingOK })
$tcpFailures = @($devices | Where-Object { $_.IPv4 -and -not $_.TcpOK })

Write-Host ("AirPlay records/devices:      {0}" -f $devices.Count)
Write-Host ("HomePods:                     {0}" -f $homePods.Count)
Write-Host ("HomePods with update:         {0}" -f $updates.Count)
Write-Host ("Missing from mDNS (reference):{0}" -f $notDiscovered.Count)
Write-Host (".local resolution failures:   {0}" -f $resolvedFailures.Count)
Write-Host ("Ping failures:                {0}" -f $pingFailures.Count)
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
