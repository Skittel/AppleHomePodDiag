# AppleHomePodDiag

AppleHomePodDiag is a Windows PowerShell diagnostic tool for troubleshooting
Apple HomePod, AirPlay and Bonjour/mDNS connectivity.

It was created to help diagnose situations where HomePods are visible or usable
only from certain Wi-Fi bands, access points or network segments.

The tool is especially useful in Wi-Fi environments with multiple access points,
2.4 GHz / 5 GHz / 6 GHz networks, multicast filtering, IGMP snooping or other
network infrastructure that may affect Bonjour/mDNS traffic.

## Features

AppleHomePodDiag can:

- Discover AirPlay devices using Bonjour / mDNS
- Detect Apple HomePods from their AirPlay service records
- Identify known HomePod generations
- Read HomePod software version information from Bonjour TXT records
- Resolve `.local` hostnames using mDNS
- Determine IPv4 addresses
- Determine the Layer-2 MAC address through the Windows neighbor/ARP table
- Test ICMP/ping connectivity
- Test the advertised AirPlay TCP port
- Show the current Wi-Fi connection of the Windows test computer
- Record:
  - SSID
  - BSSID
  - Wi-Fi band
  - channel
  - local IPv4 address
- Export results as:
  - JSON
  - CSV
  - HTML
- Compare scans from multiple Windows test nodes

This makes it possible to compare, for example:

- Client A on 2.4 GHz / Access Point 1
- Client B on 5 GHz / Access Point 2

and determine whether both clients can discover and communicate with the same
HomePods.

## Typical diagnostic scenario

A useful test setup consists of three Windows devices:

1. Management computer
2. Test node connected to 2.4 GHz / AP1
3. Test node connected to 5 GHz / AP2

Run AppleHomePodDiag on both test nodes and compare the resulting JSON files.

This can help distinguish between:

- general IP connectivity problems
- Wi-Fi client isolation
- multicast / mDNS problems
- communication problems between access points
- band-specific problems
- Apple/HomePod-specific behavior

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or newer
- Apple Bonjour / `dns-sd.exe`

The script searches common Bonjour installation paths and also checks whether
`dns-sd.exe` is available through `PATH`.
Download: https://support.apple.com/de-de/106380

## Basic usage

Open PowerShell in the directory containing the script:

```powershell
.\AppleHomePodDiag.ps1
