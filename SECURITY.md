# Security

Report vulnerabilities privately through this repository's GitHub Security
Advisories.

VoidrauVPN launches its tunnel core as a local SOCKS5 process and, in device-VPN
mode, routes a TUN adapter through that proxy. The SOCKS listener is
`127.0.0.1:1819` unless LAN sharing is enabled — never expose it on an untrusted
network.

Release artifacts should be verified against `SHA256SUMS.txt` on the GitHub
Release.
