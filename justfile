# OutlookFileDrag — justfile
#
# The VSTO add-in and the WiX MSIs build on WINDOWS ONLY: the add-in needs full
# MSBuild (the VSTO build targets are absent from the .NET SDK), so those recipes
# carry the [windows] attribute and have [unix] stubs that fail with a clear
# message. The interop-core `compile-check` builds on any OS via `dotnet build`.
#
# Run the Windows recipes from a "Developer PowerShell for VS 2022" (which puts
# `msbuild` on PATH). Visual Studio does NOT ship a standalone `nuget.exe`; the
# `restore` recipe installs Microsoft's portable nuget.exe via winget the first
# time it isn't already on PATH (falling back to a direct download only where
# winget is unavailable), so a clean dev box builds with no manual setup. CI
# provides msbuild + nuget + dotnet via microsoft/setup-msbuild + NuGet/setup-nuget
# + actions/setup-dotnet and then calls these same recipes (see
# .github/workflows/build-windows.yml).

CONFIGURATION := "Release"
# MinVer (minver-cli, pinned in .config/dotnet-tools.json) derives the version from
# git tags: tag `v1.0.13` -> 1.0.13; commits after a tag -> 1.0.14-alpha.0.N. `-t v`
# matches release.yml's tag prefix; `-m 1.0` floors the version before the first tag.
MINVER := "dotnet minver -t v -m 1.0"
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

# --- Versioning (MinVer, from git tags) -----------------------------------

# Print the version MinVer derives from git tags (run `dotnet tool restore` first).
[group('version')]
version:
    @{{ MINVER }}

# Create + push an annotated release tag (e.g. `just tag 1.0.14`); triggers release.yml.
[confirm("Tag and push v{{ ver }} -- this triggers a release build. Continue?")]
[group('version')]
tag ver:
    git tag -a v{{ ver }} -m "v{{ ver }}"
    git push origin v{{ ver }}

# --- Cross-platform -------------------------------------------------------

# Compile-check the platform-independent interop core (no VSTO; builds on any OS).
[group('check')]
compile-check:
    dotnet build ci/compile-check/OutlookFileDrag.Core.CompileCheck.csproj -c {{ CONFIGURATION }}

# --- Windows: build the VSTO add-in + WiX MSIs ----------------------------

# Restore NuGet packages for the solution (packages.config needs nuget.exe, not
# `dotnet restore`).
[doc('Restore NuGet packages (bootstraps nuget.exe if absent)')]
[group('build')]
[windows]
restore:
    #!pwsh
    $ErrorActionPreference = 'Stop'
    # packages.config restore needs nuget.exe (not `dotnet restore`, which only
    # understands PackageReference). Use one already on PATH (e.g. CI's
    # NuGet/setup-nuget); otherwise install Microsoft's portable nuget.exe via
    # winget so a clean dev box restores with no manual download.
    $nuget = (Get-Command nuget.exe -ErrorAction SilentlyContinue).Source
    if (-not $nuget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host 'nuget.exe not on PATH; installing Microsoft.NuGet via winget...'
            winget install -e --id Microsoft.NuGet --accept-source-agreements --accept-package-agreements --disable-interactivity
            # winget shims portables into %LOCALAPPDATA%\Microsoft\WinGet\Links;
            # that dir is only on PATH for *new* sessions, so resolve it directly.
            $links = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\nuget.exe'
            if (Test-Path $links) {
                $nuget = $links
            } else {
                $pkgs = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
                $nuget = (Get-ChildItem $pkgs -Recurse -Filter nuget.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
            }
        }
        if (-not $nuget) {
            # No winget (e.g. minimal box): fetch from the IMMUTABLE versioned URL,
            # pinned + SHA-256 verified (matches the original build.ps1; `.../latest/`
            # is mutable and can't be hash-checked).
            $nugetVersion = '6.11.0'
            $nugetSha256  = '133B9C1EFDC8D86BDCCAE9E296C9E4BC45A6D6472368611AA96B51B3E75FD2E3'
            $cache = Join-Path $env:LOCALAPPDATA 'OutlookFileDrag\tools'
            $nuget = Join-Path $cache 'nuget.exe'
            if (-not (Test-Path $nuget)) {
                New-Item -ItemType Directory -Force $cache | Out-Null
                Write-Host "winget unavailable; downloading nuget.exe $nugetVersion -> $nuget"
                Invoke-WebRequest "https://dist.nuget.org/win-x86-commandline/v$nugetVersion/nuget.exe" -OutFile $nuget -UseBasicParsing
            }
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $nuget).Hash
            if ($actual -ne $nugetSha256) {
                Remove-Item -LiteralPath $nuget -Force -ErrorAction SilentlyContinue
                throw "nuget.exe $nugetVersion SHA-256 mismatch: expected $nugetSha256, got $actual"
            }
        }
    }
    if (-not $nuget) { throw 'could not locate or install nuget.exe' }
    & $nuget restore OutlookFileDrag.sln
    if ($LASTEXITCODE -ne 0) { throw "nuget restore failed (exit $LASTEXITCODE)" }

[group('build')]
[unix]
restore:
    @echo 'restore is Windows-only (packages.config needs nuget.exe + MSBuild).'; exit 1

# Build the add-in with MSBuild, signing the ClickOnce manifest with an ephemeral
# self-signed cert. Trust comes from the per-machine Program Files MSI install,
# not the cert identity (see docs/AUDIT-IAT-REDIRECT.md), so a self-signed cert
# is correct here. Cert + build run in one shebang script so the thumbprint
# persists between the two steps.
[doc('Build + sign the VSTO add-in (MSBuild)')]
[group('build')]
[windows]
build: restore
    #!pwsh
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true   # msbuild non-zero exit => terminating
    # Generate Properties/VersionInfo.cs from the MinVer (git-tag) version.
    dotnet tool restore | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool restore failed (exit $LASTEXITCODE)" }
    $full = ({{ MINVER }}).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $full) { throw "MinVer failed to derive a version (exit $LASTEXITCODE)" }
    $core = ($full -split '-', 2)[0]
    Set-Content -Encoding UTF8 -Path OutlookFileDrag/Properties/VersionInfo.cs -Value @(
        '// <auto-generated/> Written by `just build` from MinVer (git tags). Do not edit; git-ignored.',
        'using System.Reflection;',
        "[assembly: AssemblyVersion(""${core}.0"")]",
        "[assembly: AssemblyFileVersion(""${core}.0"")]",
        "[assembly: AssemblyInformationalVersion(""$full"")]")
    Write-Host "version: $full (assembly ${core}.0)"
    # Reuse an existing self-signed cert; don't mint one per build (store bloat).
    $subject = 'CN=OutlookFileDrag (Build)'
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date) } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
            -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(5)
    }
    msbuild OutlookFileDrag\OutlookFileDrag.csproj /t:Build `
        /p:Configuration={{ CONFIGURATION }} /p:Platform=AnyCPU `
        /p:ManifestCertificateThumbprint=$($cert.Thumbprint) /v:m /nologo
    if ($LASTEXITCODE -ne 0) { throw "msbuild failed (exit $LASTEXITCODE)" }

[group('build')]
[unix]
build:
    @echo 'build (VSTO add-in) is Windows-only; off-Windows run: just compile-check'; exit 1

# Build the add-in then both (x86 + x64) MSIs with WiX. The version comes from
# MinVer (git tags) unless you pass one explicitly (e.g. `just msi 1.2.3`).
[doc('Build the add-in, then the x86 + x64 MSIs')]
[group('release')]
[windows]
msi version='': build
    #!pwsh
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true   # native non-zero exit => terminating
    dotnet tool restore | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool restore failed (exit $LASTEXITCODE)" }
    $ver = '{{ version }}'
    if (-not $ver) {
        $ver = ({{ MINVER }}).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $ver) { throw "MinVer failed to derive a version (exit $LASTEXITCODE)" }
    }
    $core = ($ver -split '-', 2)[0]   # MSI ProductVersion must be numeric major.minor.patch
    dotnet wix extension add -acceptEula {{ WIX_EULA }} -g WixToolset.UI.wixext/7.0.0
    dotnet wix extension add -acceptEula {{ WIX_EULA }} -g WixToolset.Netfx.wixext/7.0.0
    New-Item -ItemType Directory -Force dist | Out-Null
    foreach ($arch in @('x86','x64')) {
        dotnet wix build installer/OutlookFileDrag.wxs -acceptEula {{ WIX_EULA }} -arch $arch `
            -d Version=$core -b OutlookFileDrag/bin/{{ CONFIGURATION }} -b . `
            -ext WixToolset.UI.wixext -ext WixToolset.Netfx.wixext `
            -o "dist/OutlookFileDrag-$core-$arch.msi"
        if ($LASTEXITCODE -ne 0) { throw "wix build failed for $arch (exit $LASTEXITCODE)" }
    }
    Write-Host "built MSIs $core (from $ver)"

[group('release')]
[unix]
msi version='':
    @echo 'msi (WiX build) is Windows-only.'; exit 1

# Full release: the add-in + both MSIs (`just release`; version from MinVer). `msi`
# already depends on `build`, so this is the friendly name CI invokes.
[doc('Build the add-in + both MSIs (CI entry point)')]
[group('release')]
[windows]
release version='': (msi version)

[group('release')]
[unix]
release version='':
    @echo 'release is Windows-only; off-Windows run: just compile-check'; exit 1

# --- Maintenance ----------------------------------------------------------

# Remove build output (asks for confirmation; CI passes --yes).
[confirm("Delete dist/, OutlookFileDrag/bin, OutlookFileDrag/obj. Continue?")]
[doc('Remove build output (dist/, bin/, obj/)')]
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
