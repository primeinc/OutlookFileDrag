# Outlook File Drag

*Drag and drop Outlook items as files into any application*

## Read This First!

Microsoft Edge (as of Windows 10 1709) and Google Chrome (as of version 76) 
natively support drag and drop from Outlook on Windows.  If you use one of these 
browsers, then this plugin is not necessary.

## Overview

Outlook File Drag is an add-in for Outlook 2013 and 2016 that allows you to drag
and drop Outlook items (messages, attachments, contacts, tasks, appointments, 
meetings, etc) to applications that allow physical files to be dropped, such as
web browsers.

## How Does it Work?

When you try to drag and drop from Outlook, Outlook correctly identifies the 
format as virtual files (CFSTR_FILEDESCRIPTORW) since the files do not exist 
directly on disk.  Instead, they are contained in a PST file, OST file, or on 
an Exchange server.

However, many applications do not support this format, such as web browers and 
most .NET/Java applications.

To work around this issue, Outlook File Drag hooks the Outlook drag and drop
process and adds support for physical files (CF_HDROP).  When the receiving 
application asks for the physical files, the files are saved to a temp folder 
and those filenames are returned to the application.  The application processes
the files (such as uploading them).  Outlook File Drag deletes the temp files 
later in a cleanup process.

## Features

- Works with Chrome, Firefox, Internet Explorer, Edge, and other applications that accept files to be dropped
- Allows drag and drop into HTML5-based web applications
- Drag e-mails, attachments, contacts, calendar items, and more
- Drag multiple items at once
- Supports Unicode characters

## Fork hardening notes

This fork includes additional drag/drop hardening for environments that still require physical-file drops:

- Fixed `ReadHGlobalIntoStream` so HGLOBAL reads advance by offset instead of repeatedly copying the first 4 KB.
- Fixed temporary folder cleanup so only folders older than `TempFileExpiration` are removed.
- Added optional temporary filename normalization through `ReplaceSpecialChars` in `App.config`.
- Added an `OutputDebugStringAppender` for live drag/drop diagnostics with DebugView or a debugger.

Logs are written to `%APPDATA%\OutlookFileDrag\OutlookFileDrag.log`.

## Building from source

Builds are driven by a [`justfile`](https://just.systems) — the same recipes run
locally and in CI. List them with `just`:

| Recipe | Platform | What it does |
| --- | --- | --- |
| `just version` | any OS | Print the MinVer-derived version (from git tags). |
| `just compile-check` | any OS | `dotnet build` of the platform-independent interop core (`ci/compile-check/`) — a fast compile gate, no Visual Studio. |
| `just test` | any OS | `dotnet test` of the portable interop-core unit tests (`tests/`) — path-containment, descriptor-count, and `IEnumFORMATETC` invariants. |
| `just build` | Windows | Builds the VSTO add-in with MSBuild (signs the ClickOnce manifest with an ephemeral self-signed cert), version-stamped from MinVer. |
| `just msi [version]` | Windows | Builds the x86 + x64 MSIs with WiX into `dist/` (version from MinVer unless one is given). |
| `just release [version]` | Windows | `build` then `msi` — the full set of artifacts. |
| `just tag <version>` | any OS | Create + push an annotated `v<version>` tag, triggering a release. |

**Prerequisites**

- [`just`](https://just.systems/man/en/installation.html) — `winget install Casey.Just` / `choco install just` (Windows), `brew install just` / `apt install just` (macOS/Linux).
- The [.NET SDK](https://dotnet.microsoft.com/download) (6.0+) — for `compile-check` and for the pinned WiX tool (`.config/dotnet-tools.json`, restored with `dotnet tool restore`).
- **For the Windows add-in + MSI build only:** Visual Studio 2022 with the *Office/SharePoint development* workload (the VSTO build targets are Windows/VS-only and absent from the .NET SDK) and PowerShell 7 (`pwsh`), run from a *Developer PowerShell for VS 2022* so `msbuild` is on `PATH`. (`restore` bootstraps `nuget.exe` itself — via winget, or a pinned, SHA-256-verified download — since Visual Studio doesn't ship one.)

WiX is pinned to v7 via `.config/dotnet-tools.json`. The recipes pass
`-acceptEula wix7` to every `wix` command so the build is non-interactive
(accepting the WiX Open-Source Maintenance Fee EULA is free for non-revenue use).

**Versioning**

The version is derived from git tags by [MinVer](https://github.com/adamralph/minver)
(`minver-cli`, pinned in `.config/dotnet-tools.json`) — nothing is hardcoded in the
repo. An annotated tag `v1.2.3` yields version `1.2.3`; commits after a tag yield
`1.2.4-alpha.0.N`. It flows to the MSI `ProductVersion` (numeric `major.minor.patch`)
and to the assembly (`AssemblyVersion`/`FileVersion`/`InformationalVersion`, generated
into the git-ignored `OutlookFileDrag/Properties/VersionInfo.cs` by `just build`).

- Print the current version: `just version`.
- Cut a release: `just tag 1.2.3` (creates + pushes `v1.2.3`, triggering `release.yml`).
- One-time baseline — this fork has no version tags yet, so anchor MinVer by tagging the
  current state once, e.g. `just tag 1.0.13`; until then builds report `1.0.0-alpha.0.N`.

**CI / releases** (`.github/workflows/`)

- `ci.yml` — on every push/PR the Linux job compiles the interop core (`compile-check`) **and** runs the portable unit tests (`dotnet test`); the full Windows add-in + MSI build (`build-windows.yml`, on `windows-2022`) runs on pushes to `master` / `release/**` only (gated off PRs to keep them fast). Release tags are covered by `release.yml`.
- `release.yml` — on a pushed `v*` tag: builds the MSIs (version derived from the tag by MinVer) and publishes a GitHub Release with them attached.

## Installation

Download the MSI that matches your Windows build from the
[Releases page](https://github.com/primeinc/OutlookFileDrag/releases/latest) and run it:

- `OutlookFileDrag-<version>-x64.msi` — 64-bit Windows (Outlook 32-bit or 64-bit)
- `OutlookFileDrag-<version>-x86.msi` — 32-bit Windows

After installing, restart Outlook for the add-in to take effect.

## Automated (Silent) Installation

For administrators, OutlookFileDrag supports automated (silent) installation and uninstallation using `msiexec` with command line parameters.

### Silent Installation

To silently install OutlookFileDrag, use this command:

`msiexec.exe /i <pathtomsi> /qn /log <pathtolog>`

- `<pathtomsi>`: Path to MSI file
- `<pathtolog>`: Path to log file (if folder is not specified, MSI path is used)

Example:

`msiexec.exe /i C:\Install\OutlookFileDrag-1.2.3-x64.msi /qn /log C:\Logs\OutlookFileDragInstall.log`

After installing, restart Outlook for the add-in to take effect.

### Silent Uninstallation

The MSI uses a per-build `ProductCode`, so uninstall with the same MSI file used to install
(or by the product's stable `UpgradeCode`):

`msiexec.exe /x C:\Install\OutlookFileDrag-1.2.3-x64.msi /qn /log C:\Logs\OutlookFileDragUninstall.log`

Stable `UpgradeCode`s for scripted removal: 64-bit `{65870D9B-6652-4150-830B-C5199F26E62C}`,
32-bit `{2F626147-8F83-4FC1-9190-32AA4F25D487}`.

## Acknowledgements

Outlook File Drag uses these open source projects:

- [log4net](http://logging.apache.org/log4net/)

Drag interception is performed by an in-process `ole32!DoDragDrop` import-address-table (IAT)
redirect (see [`docs/AUDIT-IAT-REDIRECT.md`](docs/AUDIT-IAT-REDIRECT.md)); the earlier EasyHook
dependency has been removed.

## Feedback/Contribute

You can view the source code, report issues, and contribute on [GitHub](https://github.com/primeinc/OutlookFileDrag).

## Donate

If you find this project useful, please consider donating.  Your donations are appreciated. =)

[![Donate](https://www.paypalobjects.com/en_US/i/btn/btn_donateCC_LG.gif)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=BSAGCF5VAJLN2)

## Version History

### Fork hardening
- Fixed HGLOBAL stream-copy offset for descriptor payloads over 4 KB.
- Fixed temp cleanup expiration comparison.
- Added optional temp filename normalization.
- Added debug-output logging appender.

### 1.0.11
- Fixed drag and drop of embedded RTF attachments (thanks chrisv2)

### 1.0.10
- Fixed System.ArgumentException bug in ReadHGlobalIntoStream method when reading more than 4 KB introduced in version 1.0.8.

### 1.0.9
- If files were dropped and drop effect was "move", then override to "copy" so original item is not deleted

### 1.0.8
- Fixed releasing of unmanaged resources 
- Memory usage improvements
- Added more details to log file

### 1.0.5
- Fixed crash when dragging calendar items

### 1.0.4
- Added additional debug logging
- Fixed issue where STGMEDIUM was not being released after reading filenames
- Fixed issue that where reading filenames sometimes failed
- Fixed hooking process to allow starting and stopping hook without disposing and recreating hook

### 1.0.3
- Fixed issue that prevented dragging items from one group to another

### 1.0.2
- Fixed PathTooLong exception when temporary filename was longer than MAX_PATH

### 1.0.1
- Fixed issues with 64-bit Outlook
- Added self-signed certificate

### 1.0
- Initial Release

## Copyright

Outlook File Drag is copyright (c) 2018 [Tony Federer](https://github.com/tonyfederer), with fork
updates (c) 2019–2020 Four Pillar Productions / primeinc, and is released under the MIT License.
