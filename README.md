# NekoCoffee for MWEF

Keeping a small cat—or perhaps a neko—comfortable on a Xiaomi router. This is a lightweight playground for a local traffic companion, shaped to feel at home in the stock Xiaomi WebUI.

NekoCoffee uses authenticated MWEF/LuCI routes and ships without a frontend framework or third-party browser assets.

## What the cat can do

- Show the companion's health, version, core build, and current route persona
- Start, stop, or gently restart the local neko service
- Move between Rule, Global, and Direct runtime personas without a restart
- Tune traffic interception and choose a redirect-host or fake-address DNS persona
- Enable or disable IPv6 handling and QUIC handling
- Discover LAN clients and choose per device whether traffic uses the proxy
- Upload local YAML profiles, import one from a public HTTPS address, and switch profiles
- Open the local dashboard in one click
- Compare the router exit with the neko-mixed-port exit using multiple fallback observers
- Speak Simplified Chinese or English in the router UI

## Safety notes

- Every endpoint stays behind the Xiaomi LuCI `;stok=` session; no additional listener is opened.
- Mutating endpoints accept fixed actions and allow-listed values. Web input is never used as an unchecked command or path.
- YAML uploads are limited to 2 MiB and safe `.yaml` / `.yml` names. The routing core performs a semantic check before a profile switch.
- HTTPS imports must resolve to a public IPv4 address. Redirects are disabled and the validated address is pinned for the download.
- Profile activation replaces only the manager's expected symbolic link. A failed restart restores the previous target and attempts recovery.
- Device policy reuses ShellCrash's native MAC black/white list. Values are normalized and allow-listed, writes are atomic, and a failed reload restores the previous policy.
- Exit checks use a small built-in list of HTTPS observers, with strict time and response-size limits.
- No firmware partitions, boot components, block devices, or other high-risk router areas are touched.
- If the local dashboard has no secret, NekoCoffee shows a warning and leaves the existing setup unchanged.

## Compatibility

The current build has been exercised with a common neko shell manager in the 1.9.5 beta family and a Meta-style routing core. It also recognizes several conventional persistent-data locations used by similar cat setups. Per-device routing uses the manager's `configs/mac` and `macfilter_type` support, so it follows the same iptables/nftables, DNS interception, and restart lifecycle as the shell menu. MWEF `0.2.0` or newer is required.

## Build

From this repository:

```powershell
.\build.ps1
```

Or use the MWEF builder directly from the framework repository:

```powershell
.\tools\build-plugin.ps1 `
  -Source ..\mwef-app-nekocoffee `
  -OutputDirectory ..\mwef-app-nekocoffee\dist
```

The resulting archive is written to `dist/mwef-app-nekocoffee-1.2.0.tar.gz`.

## Install

Upload the archive from MWEF Framework Settings, review the requested permissions, and enable the plugin. Changes that require a neko restart always ask for confirmation first.

## License

[MIT](LICENSE) © 2026 VlHash

