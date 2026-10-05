# AppleHomePodDiag

AppleHomePodDiag is a Windows PowerShell diagnostic tool for troubleshooting
Apple HomePod, AirPlay and Bonjour/mDNS connectivity.

It is designed for cases where HomePods work only from certain Wi-Fi bands,
access points or network paths, while normal network connectivity appears to
work correctly.

This tool has been created with the help of chatgpt.

Original project:

https://github.com/Skittel/AppleHomePodDiag


## Why this project exists

HomePod connectivity problems can be difficult to diagnose.

A network may appear healthy:

- Internet access works
- Wi-Fi coverage is good
- clients receive valid IP addresses
- normal IP communication works
- HomePods are connected to Wi-Fi

while Apple Home, AirPlay or HomePod setup still fails.

One possible cause is that Bonjour/mDNS traffic is not transported correctly
between:

- 2.4 GHz and 5 GHz
- different access points
- different switches
- different network segments
- WLAN clients with isolation or multicast restrictions

AppleHomePodDiag provides a reproducible way to test the network independently
of the Apple Home app.


## Features

AppleHomePodDiag can:

- discover AirPlay devices using Bonjour / mDNS
- browse `_airplay._tcp.local`
- identify Apple HomePods from their AirPlay service records
- identify known HomePod generations
- read Bonjour TXT records such as:
  - `model`
  - `osvers`
  - `srcvers`
  - `deviceid`
  - `btaddr`
- resolve `.local` hostnames through mDNS
- determine IPv4 addresses
- determine Layer-2 MAC addresses through the Windows neighbor / ARP table
- test ICMP/ping connectivity
- measure ping response time
- test the AirPlay TCP port advertised by the device
- record the current Wi-Fi connection of the Windows test computer:
  - SSID
  - BSSID
  - Wi-Fi band
  - channel
  - radio type
  - signal strength
  - local IPv4 address
- optionally compare the installed HomePod software version with Apple's public
  HomePod software information
- export scan results as:
  - JSON
  - CSV
  - HTML
- compare scans from multiple Windows test nodes
- use a previous scan as a reference to test known HomePod IP addresses even
  when Bonjour discovery fails on the current test node
- run a focused diagnostic for a single device by:
  - Bonjour/AirPlay name
  - IPv4 address
  - MAC address


## Recommended test setup

For complex WLAN troubleshooting, a useful setup consists of three Windows
devices:

1. Management computer
2. Test node connected to 2.4 GHz / Access Point 1
3. Test node connected to 5 GHz / Access Point 2

Example:

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

Run AppleHomePodDiag on both test nodes.

This makes it possible to determine whether both network paths can discover and
communicate with the same HomePods.


## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or newer
- Apple Bonjour / `dns-sd.exe`

The script searches common Bonjour installation paths and also checks whether
`dns-sd.exe` is available through the Windows `PATH`.


## Installing Bonjour on Windows

AppleHomePodDiag uses Apple's `dns-sd.exe` utility for Bonjour / DNS-SD service
discovery.

After Bonjour has been installed, verify that `dns-sd.exe` is available:

```cmd
where dns-sd
```

A manual AirPlay discovery test can be performed with:

```cmd
dns-sd -B _airplay._tcp local
```

To inspect a single AirPlay device:

```cmd
dns-sd -L "Living Room" _airplay._tcp local
```

A HomePod may return records similar to:

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

The tool performs a Bonjour/AirPlay scan and writes its reports to:

```text
HomePodDiag-Results
```


## Name a test node

When testing multiple network paths, give each Windows test computer a
descriptive name:

```powershell
.\AppleHomePodDiag.ps1 -NodeName "AP1-24GHz"
```

On another computer:

```powershell
.\AppleHomePodDiag.ps1 -NodeName "AP2-5GHz"
```


## Change the discovery time

The default Bonjour discovery period can be changed:

```powershell
.\AppleHomePodDiag.ps1 -ScanSeconds 10
```

Longer scans may help if devices advertise services less frequently.


## Show only HomePods

To hide other AirPlay-capable devices such as televisions or Apple TVs:

```powershell
.\AppleHomePodDiag.ps1 -HomePodsOnly
```


## Focused device diagnostics

Version 1.1.0 adds a focused diagnostic mode for a single device.

Use exactly one of the following selectors:

### By Bonjour / AirPlay name

```powershell
.\AppleHomePodDiag.ps1 -Name "Küche"
```

### By IPv4 address

```powershell
.\AppleHomePodDiag.ps1 -IP "192.168.2.67"
```

### By MAC address

```powershell
.\AppleHomePodDiag.ps1 -MAC "50-BC-96-03-A8-54"
```

Colon-separated MAC addresses are also accepted:

```powershell
.\AppleHomePodDiag.ps1 -MAC "50:BC:96:03:A8:54"
```

In focused mode, AppleHomePodDiag performs the same diagnostic checks for the
selected device and prints additional details, including:

- Bonjour/AirPlay name
- device type
- model identifier
- `.local` hostname
- IPv4 address
- Layer-2 MAC address
- AirPlay `deviceid`
- Bluetooth address advertised through AirPlay
- installed HomePod software version
- detected public HomePod software version
- firmware status
- AirPlay software version
- AirPlay TCP port
- mDNS discovery status
- `.local` resolution status
- ping result and latency
- TCP reachability
- DNS-SD interface index
- complete Bonjour TXT records

For `-IP` and `-MAC`, the script still performs a Bonjour snapshot so that the
network address can be correlated with device name, model and software version.

If the device is reachable by IP but is not visible through Bonjour, the tool
can still show a useful result such as:

```text
mDNS discovered : False
Ping             : True
TCP 7000         : True
```

This strongly suggests a Bonjour/mDNS or multicast discovery problem rather
than a general IP connectivity problem.


## Skip the online HomePod version check

The script can try to determine the latest public HomePod software version from
Apple's support website.

To disable this check:

```powershell
.\AppleHomePodDiag.ps1 -SkipOnlineVersionCheck
```


## Specify an expected HomePod version manually

For controlled or offline testing:

```powershell
.\AppleHomePodDiag.ps1 -ExpectedHomePodVersion "26.6"
```

This is also useful if Apple changes the structure of its public support page.


## Reference scan mode

This is one of the most useful features for troubleshooting mDNS problems.

First run a scan from one network path:

```powershell
.\AppleHomePodDiag.ps1 -NodeName "AP1-24GHz"
```

Then copy the generated JSON report to another test node and run:

```powershell
.\AppleHomePodDiag.ps1 `
    -NodeName "AP2-5GHz" `
    -ReferenceJson ".\AppleHomePodDiag-AP1-24GHz-20261006-120000.json"
```

If a HomePod is not discovered by Bonjour on the second node, the script can
still use the known IP address from the reference report and test:

- ping
- Layer-2 neighbor / ARP information
- the advertised AirPlay TCP port

This can produce an important diagnostic result such as:

```text
HomePod: Galerie

mDNS discovery : NO
IP              : 192.168.2.73
Ping            : OK
AirPlay TCP     : OK
```

That strongly suggests a Bonjour/mDNS or multicast discovery problem rather
than a general IP connectivity problem.


## Compare scan reports

Two or more JSON reports can be compared:

```powershell
.\AppleHomePodDiag.ps1 -Compare `
    ".\AP1.json", `
    ".\AP2.json"
```

The comparison can highlight devices that are visible on one Wi-Fi path but
missing on another.


## Example diagnostic result

A healthy network path may look like this:

```text
                         AP1 / 2.4 GHz   AP2 / 5 GHz
mDNS discovery           YES             YES
IPv4 resolution          OK              OK
Ping                     OK              OK
AirPlay TCP              OK              OK
```

A possible multicast/mDNS problem may look like this:

```text
                         AP1 / 2.4 GHz   AP2 / 5 GHz
mDNS discovery           YES             NO
Known IP connectivity    OK              OK
Ping                     OK              OK
AirPlay TCP              OK              OK
```

In the second example, normal IP communication works but Bonjour discovery does
not reach both clients.


## Output files

Each scan creates:

- JSON
- CSV
- HTML

Example:

```text
AppleHomePodDiag-AP1-24GHz-20261006-120000.json
AppleHomePodDiag-AP1-24GHz-20261006-120000.csv
AppleHomePodDiag-AP1-24GHz-20261006-120000.html
```

The JSON file contains the complete machine-readable scan data and is used for
reference scans and comparisons.


## HomePod identification

HomePods advertise a model identifier through their AirPlay Bonjour TXT
records.

Known identifiers currently handled by the script include:

| Model identifier | Device |
|---|---|
| `AudioAccessory1,1` | HomePod (1st generation) |
| `AudioAccessory1,2` | HomePod (1st generation variant) |
| `AudioAccessory5,1` | HomePod mini |
| `AudioAccessorySingle5,1` | HomePod mini |
| `AudioAccessory6,1` | HomePod (2nd generation) |

Unknown `AudioAccessory...` identifiers are still treated as HomePods and are
shown as unknown HomePod models.

Future Apple hardware may require new model mappings.


## HomePod software version

HomePods advertise an `osvers` value through their AirPlay Bonjour TXT record.

Example:

```text
model=AudioAccessory1,1
osvers=26.6
srcvers=960.13.1
```

Important values:

- `model` = Apple hardware model identifier
- `osvers` = installed HomePod software version
- `srcvers` = AirPlay software component version

`srcvers` should not be confused with the installed HomePod software version.


## Firmware version check

AppleHomePodDiag can optionally compare the installed `osvers` value with the
latest HomePod software version it can detect on Apple's public support page.

Possible states include:

```text
CURRENT
UPDATE AVAILABLE
NOT CHECKED
UNKNOWN
NEWER THAN PUBLIC
```

The online version check is best-effort.

Apple may change the structure of its public support website at any time. If
automatic detection fails, the installed HomePod software version is still
shown and the expected version can be specified manually.


## Wi-Fi information recorded

For the Windows test computer, the tool records:

- interface
- connection state
- SSID
- BSSID
- Wi-Fi band
- channel
- radio type
- signal strength
- IPv4 address

The BSSID is particularly useful because it identifies the specific access
point radio to which the test computer is associated.


## Device information recorded

For discovered AirPlay devices, the tool may record:

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
- mDNS discovery status
- `.local` resolution status
- ping result
- ping latency
- TCP port reachability
- DNS-SD interface index
- Bonjour TXT records


## MAC addresses

The Layer-2 MAC address shown by AppleHomePodDiag is obtained through the local
Windows neighbor / ARP table after IP communication with the device.

This can help match a HomePod to a WLAN controller such as:

- TP-Link Omada
- UniFi
- Aruba
- Cisco
- other WLAN management systems

The MAC address advertised as the AirPlay `deviceid` is not assumed to be the
same address used by the WLAN infrastructure.


## Network traffic generated

AppleHomePodDiag does not modify network configuration.

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

The tool operates using information already exposed on the local network
through Bonjour/mDNS and standard IP networking.


## Limitations

### Bonjour visibility

Bonjour/mDNS is local-network oriented.

A HomePod that does not advertise its AirPlay service to a particular test
computer may not appear in a normal scan even if direct IP connectivity would
otherwise work.

This is one reason the `-ReferenceJson` and focused diagnostic options exist.


### Missing physical devices

AppleHomePodDiag discovers network-visible devices.

It cannot determine how many HomePods physically exist in a building.

For example:

```text
Physical HomePods: 12
Discovered HomePods: 10
```

The tool can show the 10 visible devices, but it cannot automatically identify
the two physically present devices that are completely disconnected from the
network.


### Serial numbers

HomePod serial numbers are not normally present in the AirPlay Bonjour TXT
records used by this tool.

A physical HomePod therefore cannot always be matched directly to a network
entry using only its serial number.


### Apple Home / HomeKit behavior

AppleHomePodDiag tests network behavior.

It does not reproduce every internal function of:

- Apple Home
- HomeKit
- Siri
- AirPlay authentication
- HomePod setup
- iCloud

A successful scan therefore demonstrates that basic network, Bonjour and
AirPlay connectivity works, but it does not guarantee that every Apple Home
feature will work correctly.


## Recommended troubleshooting methodology

Change only one variable at a time.

A useful sequence is:

1. Verify that the HomePod is visible through Bonjour.
2. Verify `.local` name resolution.
3. Verify IP connectivity.
4. Verify the advertised AirPlay TCP port.
5. Repeat the test from the same access point on another Wi-Fi band.
6. Repeat the test from another access point.
7. Use a reference scan to test IP connectivity to devices missing from mDNS.
8. Compare the JSON reports.
9. Use focused diagnostics for individual devices when needed.
10. Only then change WLAN configuration such as:
    - IGMP snooping
    - multicast filtering
    - client isolation
    - WPA2/WPA3 transition mode
    - band steering
    - roaming options


## Safety

The script is intended to be a read-only diagnostic tool.

It does not intentionally:

- change WLAN settings
- change IP settings
- restart devices
- reset HomePods
- modify Apple Home
- modify firewall rules
- modify router configuration


## PowerShell execution policy

Windows may block downloaded PowerShell scripts.

Check the current policy with:

```powershell
Get-ExecutionPolicy
```

If the downloaded script is blocked, inspect and unblock that specific file:

```powershell
Unblock-File .\AppleHomePodDiag.ps1
```

Always review scripts before running them.


## Administrative privileges

Most diagnostic functions should work without running PowerShell as
Administrator.

Depending on local Windows configuration, some network information may be more
complete when PowerShell is started with appropriate permissions.


## Contributing

Bug reports, test results and pull requests are welcome.

Useful contributions include:

- new HomePod model identifiers
- additional Bonjour TXT record examples
- Windows compatibility fixes
- Wi-Fi band detection improvements
- test results from multi-AP environments
- additional comparison and reporting features

Repository:

https://github.com/Skittel/AppleHomePodDiag


## License

AppleHomePodDiag may be used, modified, redistributed and used commercially
subject to the conditions in the `LICENSE` file.

Redistributions and modified versions must retain the project information
required by the license, including `PROJECT_INFO.txt`.

See:

- `LICENSE`
- `PROJECT_INFO.txt`


## Original project

AppleHomePodDiag was originally published at:

https://github.com/Skittel/AppleHomePodDiag

Original author:

Stefan Kittel


## Disclaimer

AppleHomePodDiag is an independent diagnostic project.

It is not affiliated with, endorsed by, sponsored by or supported by Apple Inc.

Apple, HomePod, AirPlay, HomeKit and related names are trademarks of Apple Inc.

The software is provided without warranty. Use it at your own risk.
