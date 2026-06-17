# OutlookFileDrag — justfile
#
# The VSTO add-in and the WiX MSIs build on WINDOWS ONLY: the add-in needs full
# MSBuild (the VSTO build targets are absent from the .NET SDK), so those recipes
# carry the [windows] attribute and have [unix] stubs that fail with a clear
# message. The interop-core `compile-check` builds on any OS via `dotnet build`.
#
# Run the Windows recipes from a "Developer PowerShell for VS 2022" (which puts
# `msbuild` and `nuget` on PATH); CI provisions the same tools via
# microsoft/setup-msbuild + NuGet/setup-nuget + actions/setup-dotnet and then
# calls these same recipes (see .github/workflows/build-windows.yml).

# Keep in sync with installer/OutlookFileDrag.wxs (?define Version default).
VERSION := "1.0.13"
CONFIGURATION := "Release"
# OSMF EULA id required by WiX v7 = "wix" + major version. Accepting is free for
# non-revenue use; passed to every `wix` command so builds are non-interactive.
# (Verified: CommandLine.cs requires acceptance for every non-help/version/eula
# command; EulaCommand.cs derives the id as "wix" + Major.)
WIX_EULA := "wix7"

# just defaults to `sh` even on Windows; use PowerShell (cross-platform pwsh /
# PowerShell 7) for recipe lines there. (casey/just examples/powershell.just.)
set windows-shell := ["pwsh", "-NoLogo", "-Command"]

# List available recipes (runs when `just` is invoked with no arguments).
default:
    @just --list

# --- Cross-platform -------------------------------------------------------

# Compile-check the platform-independent interop core (no VSTO; builds on any OS).
[group('check')]
compile-check:
    dotnet build ci/compile-check/OutlookFileDrag.Core.CompileCheck.csproj -c {{ CONFIGURATION }}

# --- Windows: build the VSTO add-in + WiX MSIs ----------------------------

# Restore NuGet packages for the solution (packages.config needs nuget.exe, not
# `dotnet restore`).
[group('build')]
[windows]
restore:
    nuget restore OutlookFileDrag.sln

[group('build')]
[unix]
restore:
    @echo 'restore is Windows-only (packages.config needs nuget.exe + MSBuild).'; exit 1

# Build the add-in with MSBuild, signing the ClickOnce manifest with an ephemeral
# self-signed cert. Trust comes from the per-machine Program Files MSI install,
# not the cert identity (see docs/AUDIT-IAT-REDIRECT.md), so a self-signed cert
# is correct here. Cert + build run in one shebang script so the thumbprint
# persists between the two steps.
[group('build')]
[windows]
build: restore
    #!pwsh
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true   # msbuild non-zero exit => terminating
    # Reuse an existing self-signed cert; don't mint one per build (store bloat).
    $subject = 'CN=OutlookFileDrag (Build)'
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject } | Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
            -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(5)
    }
    msbuild OutlookFileDrag\OutlookFileDrag.csproj /t:Build `
        /p:Configuration={{ CONFIGURATION }} /p:Platform=AnyCPU `
        /p:ManifestCertificateThumbprint=$($cert.Thumbprint) /v:m /nologo

[group('build')]
[unix]
build:
    @echo 'build (VSTO add-in) is Windows-only; off-Windows run: just compile-check'; exit 1

# Build the add-in then both (x86 + x64) MSIs with WiX (e.g. `just msi 1.0.13`).
# Depends on `build`, so it works end-to-end on a clean tree.
[group('release')]
[windows]
msi version=VERSION: build
    #!pwsh
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true   # native non-zero exit => terminating
    dotnet tool restore
    dotnet wix extension add -acceptEula {{ WIX_EULA }} -g WixToolset.UI.wixext/7.0.0
    dotnet wix extension add -acceptEula {{ WIX_EULA }} -g WixToolset.Netfx.wixext/7.0.0
    New-Item -ItemType Directory -Force dist | Out-Null
    foreach ($arch in @('x86','x64')) {
        dotnet wix build installer/OutlookFileDrag.wxs -acceptEula {{ WIX_EULA }} -arch $arch `
            -d Version={{ version }} -b OutlookFileDrag/bin/{{ CONFIGURATION }} -b . `
            -ext WixToolset.UI.wixext -ext WixToolset.Netfx.wixext `
            -o "dist/OutlookFileDrag-{{ version }}-$arch.msi"
        if ($LASTEXITCODE -ne 0) { throw "wix build failed for $arch (exit $LASTEXITCODE)" }
    }

[group('release')]
[unix]
msi version=VERSION:
    @echo 'msi (WiX build) is Windows-only.'; exit 1

# Full release: the add-in + both MSIs (e.g. `just release 1.0.13`). `msi`
# already depends on `build`, so this is the friendly name CI invokes.
[group('release')]
[windows]
release version=VERSION: (msi version)

[group('release')]
[unix]
release version=VERSION:
    @echo 'release is Windows-only; off-Windows run: just compile-check'; exit 1

# --- Maintenance ----------------------------------------------------------

# Remove build output (asks for confirmation; CI passes --yes).
[confirm("Delete dist/, OutlookFileDrag/bin, OutlookFileDrag/obj. Continue?")]
[group('maintenance')]
[windows]
clean:
    #!pwsh
    Remove-Item -Recurse -Force dist, OutlookFileDrag\bin, OutlookFileDrag\obj -ErrorAction SilentlyContinue
    dotnet clean ci/compile-check/OutlookFileDrag.Core.CompileCheck.csproj -c {{ CONFIGURATION }}

[confirm("Delete dist/, OutlookFileDrag/bin, OutlookFileDrag/obj. Continue?")]
[group('maintenance')]
[unix]
clean:
    rm -rf dist OutlookFileDrag/bin OutlookFileDrag/obj
    dotnet clean ci/compile-check/OutlookFileDrag.Core.CompileCheck.csproj -c {{ CONFIGURATION }}
