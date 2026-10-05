# AppleHomePodDiag

AppleHomePodDiag is a Windows PowerShell diagnostic tool for troubleshooting
Apple HomePod, AirPlay and Bonjour/mDNS connectivity.

It was created to help diagnose situations where HomePods are visible or usable
only from certain Wi-Fi bands, access points or network paths.

The tool is especially useful in Wi-Fi environments with multiple access points,
2.4 GHz / 5 GHz / 6 GHz networks, multicast filtering, IGMP snooping or other
network infrastructure that may affect Bonjour/mDNS traffic.

This tool has been created with the help of chatgpt.

Original project:

https://github.com/Skittel/AppleHomePodDiag


## Why this project exists

Apple HomePod connectivity issues can be difficult to troubleshoot.

A network may appear to work normally:

- Internet access works
- Wi-Fi coverage is good
- clients receive valid IP addresses
- normal IP communication works
- HomePods are associated with the Wi-Fi network

while Apple Home, AirPlay or HomePod setup still fails.

One possible cause is Bonjour/mDNS traffic not being transported correctly
between:

- different Wi-Fi bands
- different access points
- different switches
- different network segments

AppleHomePodDiag provides a reproducible way to test the network independently
of the Apple Home app.


## Features

AppleHomePodDiag can:

- Discover AirPlay devices using Bonjour / mDNS
- Browse `_airplay._tcp.local`
- Detect Apple HomePods from their AirPlay service records
- Identify known HomePod generations
- Read HomePod software version information
- Read AirPlay TXT records
- Resolve `.local` hostnames through mDNS
- Determine IPv4 addresses
- Determine Layer-2 MAC addresses using the Windows neighbor / ARP table
- Test ICMP/ping connectivity
- Measure ping response time
- Test the advertised AirPlay TCP port
- Record the current Wi-Fi connection of the Windows test computer
- Record:
  - SSID
  - BSSID
  - Wi-Fi band
  - channel
  - radio type
  - signal strength
  - local IPv4 address
- Optionally check the installed HomePod software version against Apple's
  public support information
- Export scan results as:
  - JSON
  - CSV
  - HTML
- Compare results from multiple Windows test nodes


## Typical diagnostic scenario

A useful troubleshooting setup consists of three Windows devices:

1. Management computer
2. Test node connected to 2.4 GHz / Access Point 1
3. Test node connected to 5 GHz / Access Point 2

For example:

```text
Windows Test Node A
2.4 GHz
Access Point 1
      |
      |
LAN / Switch
      |
      |
Access Point 2
5 GHz
Windows Test Node B
```

AppleHomePodDiag can be run on both test nodes.

The resulting scan files can then be compared to determine whether both
network paths can discover and communicate with the same HomePods.


## What this can help diagnose

The tool may help distinguish between:

- general IP connectivity problems
- Wi-Fi client isolation
- multicast problems
- mDNS / Bonjour problems
- communication problems between access points
- communication problems between Wi-Fi bands
- switch multicast handling problems
- IGMP snooping related problems
- AirPlay service reachability problems
- Apple/HomePod-specific behavior


## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or newer
- Apple Bonjour / `dns-sd.exe`

The script searches common Bonjour installation paths and also checks whether
`dns-sd.exe` is available through the Windows `PATH`.


## Installing Bonjour on Windows

AppleHomePodDiag uses Apple's `dns-sd.exe` utility for Bonjour / DNS-SD service
discovery.

After Bonjour has been installed, you can verify that `dns-sd.exe` is
available with:

```cmd
where dns-sd
```

You can also test Bonjour manually:

```cmd
dns-sd -B _airplay._tcp local
```

A working network may return entries similar to:

```text
Galerie
Kitchen
Living Room
Bedroom
```

To inspect a single AirPlay device manually:

```cmd
dns-sd -L "Galerie" _airplay._tcp local
```

A HomePod may return TXT records similar to:

```text
model=AudioAccessory1,1
osvers=26.6
srcvers=960.13.1
deviceid=76:A9:A1:C4:76:44
```

AppleHomePodDiag automates these steps.


## Basic usage

Open PowerShell in the directory containing the script:

```powershell
.\AppleHomePodDiag.ps1
```

The tool automatically performs a Bonjour/AirPlay scan and creates diagnostic
reports.


## Name a test node

When testing multiple network paths, give every Windows computer a descriptive
name:

```powershell
.\AppleHomePodDiag.ps1 -NodeName "AP1-24GHz"
```

On another computer:

```powershell
.\AppleHomePodDiag.ps1 -NodeName "AP2-5GHz"
```

The node name is stored in the report and makes later comparisons easier.


## Change scan duration

The default Bonjour discovery period can be changed:

```powershell
.\AppleHomePodDiag.ps1 -ScanSeconds 10
```

Longer scans may be useful when devices advertise their services less
frequently.


## Scan only HomePods

To hide other AirPlay-capable devices such as televisions or Apple TVs:

```powershell
.\AppleHomePodDiag.ps1 -HomePodsOnly
```


## Skip the online HomePod version check

By default the tool can attempt to determine the current HomePod software
version from Apple's public support website.

To disable this:

```powershell
.\AppleHomePodDiag.ps1 -SkipOnlineVersionCheck
```


## Specify an expected HomePod version manually

For controlled or offline testing environments:

```powershell
.\AppleHomePodDiag.ps1 -ExpectedHomePodVersion "26.6"
```

This can also be useful if Apple's support website changes and automatic
version detection temporarily stops working.


## Output files

By default the tool creates a directory named:

```text
HomePodDiag-Results
```

Each scan produces:

```text
JSON
CSV
HTML
```

Example:

```text
HomePodDiag-AP1-24GHz-20261006-120000.json
HomePodDiag-AP1-24GHz-20261006-120000.csv
HomePodDiag-AP1-24GHz-20261006-120000.html
```

The JSON file contains the complete machine-readable scan information and can
be used for comparisons.


## Compare two scans

Run a scan on Test Node A:

```powershell
.\AppleHomePodDiag.ps1 -NodeName "AP1-24GHz"
```

Run another scan on Test Node B:

```powershell
.\AppleHomePodDiag.ps1 -NodeName "AP2-5GHz"
```

Copy both JSON files to one computer and compare them:

```powershell
.\AppleHomePodDiag.ps1 -Compare `
    ".\HomePodDiag-AP1-24GHz-20261006-120000.json", `
    ".\HomePodDiag-AP2-5GHz-20261006-120500.json"
```

The comparison can reveal situations such as:

```text
HomePod "Galerie"

                         AP1 / 2.4 GHz   AP2 / 5 GHz
mDNS discovery           YES             NO
IPv4 address             available       -
Ping                     OK              -
AirPlay TCP              OK              -
```

This is a strong indication that Bonjour/mDNS traffic is not reaching both
network paths correctly.


## Example of a healthy comparison

A healthy network might show:

```text
                         AP1 / 2.4 GHz   AP2 / 5 GHz
mDNS discovery           YES             YES
IPv4 resolution          OK              OK
Ping                     OK              OK
AirPlay TCP              OK              OK
```

This suggests that the basic network path and Bonjour discovery work from both
test locations.


## HomePod identification

Apple HomePods advertise a model identifier through their AirPlay Bonjour TXT
record.

Currently recognized identifiers include:

| Model identifier | Device |
|---|---|
| `AudioAccessory1,1` | HomePod (1st generation) |
| `AudioAccessory5,1` | HomePod mini |
| `AudioAccessory6,1` | HomePod (2nd generation) |

Unknown AirPlay devices are still displayed but may not receive a specific
product name.

Future Apple hardware may require new model identifiers to be added to the
script.


## HomePod software version

HomePods advertise an `osvers` value through their AirPlay Bonjour TXT record.

Example:

```text
model=AudioAccessory1,1
osvers=26.6
srcvers=960.13.1
```

The important values are:

```text
model
```

Apple hardware model identifier.

```text
osvers
```

Installed HomePod software version.

```text
srcvers
```

AirPlay software component version.

`srcvers` should not be confused with the installed HomePod operating system
version.


## Firmware update check

AppleHomePodDiag can optionally compare the installed `osvers` value with
information retrieved from Apple's public support website.

Possible states include:

```text
AKTUELL
UPDATE
NICHT GEPRUEFT
UNBEKANNT
```

The online version check is best-effort.

Apple may change the structure of its public support website at any time. If
automatic detection fails, the installed HomePod version is still shown and
the expected version can be specified manually.


## Network information collected

For the Windows test computer, the tool records information including:

```text
SSID
BSSID
Wi-Fi band
channel
radio type
signal strength
IPv4 address
```

The BSSID is particularly useful because it identifies the specific access
point radio to which the Windows computer is currently connected.

This makes it possible to document a test such as:

```text
Test Node A
SSID: Office
Band: 2.4 GHz
Channel: 6
BSSID: AA:BB:CC:DD:EE:01
```

and compare it with:

```text
Test Node B
SSID: Office
Band: 5 GHz
Channel: 44
BSSID: AA:BB:CC:DD:EE:02
```


## Device information collected

For discovered AirPlay devices, AppleHomePodDiag may collect:

- Bonjour instance name
- detected device type
- Apple model identifier
- `.local` hostname
- IPv4 address
- Layer-2 MAC address
- AirPlay `deviceid`
- Bluetooth address advertised through AirPlay
- HomePod software version
- AirPlay software version
- advertised AirPlay TCP port
- ping result
- ping latency
- TCP port reachability
- DNS-SD interface index


## MAC addresses

The MAC address shown by AppleHomePodDiag is obtained through the local Windows
neighbor / ARP table after IP communication with the device.

This is useful when matching a HomePod to a Wi-Fi controller such as:

- TP-Link Omada
- UniFi
- Aruba
- Cisco
- other WLAN management systems

The MAC address advertised as an AirPlay `deviceid` may not necessarily be the
same address shown by the WLAN infrastructure.


## Network traffic generated

AppleHomePodDiag does not modify the network configuration.

It performs diagnostic operations including:

- Bonjour/mDNS service discovery
- DNS-SD queries
- `.local` hostname resolution
- ICMP echo requests
- ARP / neighbor-table inspection
- TCP connection tests

When online software-version checking is enabled, the script also connects to
Apple's public support website.


## Credentials and privacy

AppleHomePodDiag does not require or collect:

- Apple Account credentials
- HomePod credentials
- Wi-Fi passwords
- Apple Home credentials

The tool operates using information already available on the local network
through Bonjour/mDNS and normal IP networking.


## Important limitation: Bonjour visibility

Bonjour/mDNS is intentionally local-network oriented.

A HomePod that does not advertise its AirPlay service to a particular test
computer may not appear in the scan even if:

- the HomePod is powered on
- it has an IP address
- direct IP communication might otherwise work

This is not necessarily a limitation of the tool.

In fact, a device being visible from one Wi-Fi path but missing from another
can itself be an important diagnostic result.


## Important limitation: missing devices

AppleHomePodDiag discovers devices that are visible through the network.

It cannot determine how many HomePods physically exist in a building.

For example:

```text
Physical HomePods: 12
Discovered HomePods: 10
```

The tool can show the 10 network-visible devices, but it cannot automatically
identify the two physically present devices that are completely disconnected
from the network.

Physical inventory information such as room name and serial number may still
be required in such cases.


## Important limitation: serial numbers

HomePod serial numbers are not normally included in the AirPlay Bonjour TXT
records used by this tool.

A physical HomePod can therefore not always be matched directly to a network
entry using its serial number alone.


## Important limitation: Apple Home

AppleHomePodDiag tests network behavior.

It does not reproduce every internal function of:

- Apple Home
- HomeKit
- Siri
- AirPlay authentication
- HomePod setup
- iCloud

A successful AppleHomePodDiag test therefore demonstrates that basic network,
Bonjour and AirPlay connectivity works, but it does not guarantee that every
Apple Home feature will work correctly.


## Recommended troubleshooting methodology

When troubleshooting complex WLAN environments, change only one variable at a
time.

A useful test sequence is:

1. Verify that the HomePod is visible through Bonjour.
2. Verify `.local` name resolution.
3. Verify IP connectivity.
4. Verify the advertised AirPlay TCP port.
5. Repeat the test from the same access point but another Wi-Fi band.
6. Repeat the test from another access point.
7. Compare the resulting JSON reports.
8. Only then change WLAN configuration such as:
   - IGMP snooping
   - multicast filtering
   - client isolation
   - WPA2/WPA3 transition mode
   - band steering
   - roaming options


## Example troubleshooting matrix

| Test node | Wi-Fi band | Access point | Bonjour | Ping | AirPlay TCP |
|---|---:|---|---|---|---|
| Node A | 2.4 GHz | AP1 | OK | OK | OK |
| Node B | 5 GHz | AP1 | OK | OK | OK |
| Node C | 2.4 GHz | AP2 | OK | OK | OK |
| Node D | 5 GHz | AP2 | FAIL | - | - |

Such a result may indicate a band-specific or access-point-specific multicast
problem.


## Safety

The script is designed as a read-only diagnostic tool.

It does not intentionally:

- change WLAN settings
- change IP settings
- restart devices
- reset HomePods
- modify Apple Home
- modify firewall rules
- modify router configuration


## PowerShell execution policy

Depending on the Windows PowerShell configuration, Windows may prevent locally
downloaded PowerShell scripts from running.

You can inspect the current policy with:

```powershell
Get-ExecutionPolicy
```

If a downloaded script is blocked, you can also inspect or unblock the specific
file:

```powershell
Unblock-File .\AppleHomePodDiag.ps1
```

Always review scripts before running them with administrative privileges.


## Administrative privileges

Most diagnostic functions should work without running PowerShell as
Administrator.

Depending on the local Windows configuration, some network information may be
more complete when PowerShell is started with appropriate permissions.


## Contributing

Bug reports, test results and pull requests are welcome.

If you discover:

- a new HomePod model identifier
- different Bonjour TXT records
- compatibility problems
- incorrect model detection
- issues with Windows Wi-Fi detection
- problems in multi-AP environments

please open an issue or submit a pull request.

Repository:

https://github.com/Skittel/AppleHomePodDiag


## Redistribution and modified versions

This project may be:

- used privately
- used commercially
- copied
- modified
- redistributed

Modified and redistributed versions must retain the project information
required by the license.

See:

```text
PROJECT_INFO.txt
```

and:

```text
LICENSE
```


## Original project

AppleHomePodDiag was originally published at:

https://github.com/Skittel/AppleHomePodDiag

Original author:

Stefan Kittel


## License

AppleHomePodDiag is distributed under the license included in the `LICENSE`
file.

The software may be used, modified, redistributed and used commercially,
subject to the conditions defined there.

Redistributions must retain the attribution information contained in
`PROJECT_INFO.txt`.

See [LICENSE](LICENSE) for the complete license terms.


## Disclaimer

AppleHomePodDiag is an independent diagnostic project.

It is not affiliated with, endorsed by, sponsored by or supported by Apple Inc.

Apple, HomePod, AirPlay, HomeKit and related names are trademarks of Apple Inc.

The software is provided without warranty. Use it at your own risk.
