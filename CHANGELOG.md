# Changelog

All notable changes to AppleHomePodDiag are documented in this file.

## 1.1.2

- Split the console output into two separate sections:
  - `AirPlay devices - HomePods`
  - `AirPlay devices - Other devices`
- Sort both device lists alphabetically by:
  1. device type
  2. device name
- Applied the same grouping and sorting to the HTML report.
- Sort CSV output by type and name.
- Added the current version number directly at the top of the PowerShell source file so it is immediately visible when opened in an editor.

## 1.1.1

- Improved ping diagnostics for Wi-Fi devices.
- The first ping is now treated as a wake-up / warm-up ping and is discarded.
- Three additional pings are measured.
- Console output now shows a latency range such as `17-37ms`.
- Partial packet loss is shown, for example `17-37ms / 1 lost`.
- `NO REPLY` is shown when all measured pings fail.
- Added ping minimum, maximum, average, loss count and individual samples to diagnostic results.

## 1.1.0

- Added focused single-device diagnostics.
- A device can be selected by Bonjour / AirPlay name, IPv4 address or MAC address.
- Added the parameters `-Name`, `-IP` and `-MAC`.
- Focused diagnostics show additional information including Bonjour TXT records.
- IP and MAC based diagnostics attempt to correlate the selected device with Bonjour data.
- Direct IP connectivity can still be tested even when Bonjour discovery fails.
- Added MAC address normalization for common `:` and `-` formats.

## 1.0.2

- Fixed handling of Unicode AirPlay device names such as `Küche`, `Gäste WC` and `Joni‘s Zimmer`.
- Improved parsing of `dns-sd -Z _airplay._tcp local`.
- Added Unicode-safe decoding of DNS-SD escaped names such as `\032`.
- Improved `dns-sd.exe` process handling by reading stdout and stderr asynchronously.
- Added fallback to `dns-sd -L` when a zone snapshot is incomplete.
- Fixed a regression where devices such as NAD M10 could lose detailed information.
- Fixed HTML report generation caused by a PowerShell alias collision with the helper function name `H`.
- Changed ICMP wording so missing ping replies do not automatically imply that the device is unreachable.

## 1.0.1

- Fixed Windows PowerShell 5.1 compatibility problems when exporting generic lists.
- Improved JSON, CSV and HTML report generation.
- Added more robust internal result handling.
- Added reference scan support for testing known IP addresses of devices missing from mDNS.
- Improved scan comparison handling.

## 1.0.0

- Initial public release.
- Discover AirPlay devices using Bonjour / mDNS.
- Identify Apple HomePods from Bonjour TXT records.
- Read HomePod model and software information.
- Resolve `.local` hostnames.
- Determine IPv4 and Layer-2 MAC addresses.
- Test ping and AirPlay TCP connectivity.
- Record local Windows Wi-Fi information.
- Export scan results to JSON, CSV and HTML.
- Compare scan reports from multiple Windows test nodes.
- Support reference scans for troubleshooting mDNS visibility problems.
