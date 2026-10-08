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

# Azure Artifact Signing: the Public Trust profile that signs a release -- the add-in
# assembly, both ClickOnce manifests and the MSIs. Auth is the Azure CLI login (`az login`);
# that identity needs "Artifact Signing Certificate Profile Signer" on the profile. The
# service keeps the private key and issues a new 72-hour certificate daily, so each release
# is signed by a different certificate under one subject; `deploy::*` carries that release's
# certificate to the fleet.
export ARTIFACT_SIGNING_ENDPOINT := env('ARTIFACT_SIGNING_ENDPOINT', 'https://eus.codesigning.azure.net/')
export ARTIFACT_SIGNING_ACCOUNT := env('ARTIFACT_SIGNING_ACCOUNT', 'cs-wc-prod')
export ARTIFACT_SIGNING_PROFILE := env('ARTIFACT_SIGNING_PROFILE', 'cp-public-trust')
export SIGNING_PUBLISHER := env('SIGNING_PUBLISHER', 'Title Solutions Agency LLC')
export PROJECT_URL := "https://github.com/primeinc/OutlookFileDrag"

# just defaults to `sh` even on Windows; use PowerShell (cross-platform pwsh /
# PowerShell 7) for recipe lines there. (casey/just examples/powershell.just.)
set windows-shell := ["pwsh", "-NoLogo", "-Command"]

# List available recipes (runs when `just` is invoked with no arguments).
default:
    @just --list

# Intune publishing: ClickOnce publisher trust for the signed VSTO manifests.
mod deploy

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

# Build the add-in with MSBuild, signing the ClickOnce manifests with a
# self-signed cert.
#
# A per-machine Program Files install grants the add-in NO trust. Office runs
# every vstolocal add-in through the ClickOnce trust manager, which trusts a
# manifest only if the signing certificate is in the machine's TrustedPublisher
# store, or if a user accepted the trust prompt for that exact manifest URL and
# public key. Silent MDM installs never see a prompt, so the certificate must be
# deployed: `just deploy::trust-deploy`. The inclusion-list entry is keyed on
# URL *and* key, so changing the install path or the cert revokes prior trust.
#
# Cert + build run in one shebang script so the thumbprint persists between the
# two steps.
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
    $core, $pre = $full.Split([char]'-', 2)
    # Windows Installer keeps an installed file whose version equals or exceeds the incoming
    # one, so no two builds may share a file version. A tagged release is <core>.0. A build N
    # commits after tag 1.0.13 (MinVer 1.0.14-alpha.0.N) is 1.0.13.N: above the release it
    # follows, below the release it precedes. v1.0.13 predates this: its release build and
    # every build after it carried 1.0.13.0, and a machine holding one kept its DLL when the
    # other installed.
    $fileVersion = "$core.0"
    if ($pre) {
        $v = [version]$core
        $height = 0
        if (-not [int]::TryParse($pre.Split([char]'.')[-1], [ref]$height) -or $height -lt 1 -or $height -gt 65535 -or $v.Build -lt 1) {
            throw "cannot place pre-release '$full' between two release file versions"
        }
        $fileVersion = "$($v.Major).$($v.Minor).$($v.Build - 1).$height"
    }
    Set-Content -Encoding UTF8 -Path OutlookFileDrag/Properties/VersionInfo.cs -Value @(
        '// <auto-generated/> Written by `just build` from MinVer (git tags). Do not edit; git-ignored.',
        'using System.Reflection;',
        "[assembly: AssemblyVersion(""${core}.0"")]",
        "[assembly: AssemblyFileVersion(""$fileVersion"")]",
        "[assembly: AssemblyInformationalVersion(""$full"")]")
    Write-Host "version: $full (assembly ${core}.0, file $fileVersion)"
    # The manifest signing key. ClickOnce trust is keyed on the manifest URL AND
    # the public key, so the key that signs a release decides whether every grant
    # already on the fleet still covers it. A key minted on the build machine
    # makes each machine -- and each CI runner -- a different publisher: v1.0.13
    # was signed by a GitHub Actions runner and that private key no longer exists,
    # so nothing can ever re-sign as that publisher again.
    #
    # SIGNING_PFX / SIGNING_PFX_PASSWORD, or SIGNING_THUMBPRINT for a key already
    # in CurrentUser\My, pin it. With neither, the build still works and still
    # signs -- it just signs as this machine, which is fine for development and
    # is NOT a release. Say so rather than leaving it to be discovered by a fleet
    # that stops loading the add-in.
    $subject = 'CN=OutlookFileDrag (Build)'
    $durable = $true
    if ($env:SIGNING_PFX) {
        if (-not (Test-Path $env:SIGNING_PFX)) { throw "SIGNING_PFX is set but there is no file at $($env:SIGNING_PFX)" }
        $pw = if ($env:SIGNING_PFX_PASSWORD) { ConvertTo-SecureString $env:SIGNING_PFX_PASSWORD -AsPlainText -Force } else { $null }
        $cert = Import-PfxCertificate -FilePath $env:SIGNING_PFX -CertStoreLocation Cert:\CurrentUser\My -Password $pw
        if (-not $cert) { throw "could not import $($env:SIGNING_PFX)" }
    } elseif ($env:SIGNING_THUMBPRINT) {
        $want = $env:SIGNING_THUMBPRINT.Replace(' ', '').ToUpperInvariant()
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $want } | Select-Object -First 1
        if (-not $cert) { throw "SIGNING_THUMBPRINT $want is not in CurrentUser\My on this machine" }
        if (-not $cert.HasPrivateKey) { throw "SIGNING_THUMBPRINT $want has no private key here, so it cannot sign" }
    } else {
        $durable = $false
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date) } | Sort-Object NotAfter -Descending | Select-Object -First 1
        if (-not $cert) {
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
                -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(5)
        }
    }
    Write-Host "signing key: $($cert.Thumbprint)  $($cert.Subject)"
    if (-not $durable) {
        Write-Host "  MACHINE-LOCAL KEY -- development build."
        Write-Host "  No other machine can reproduce this signature and no grant on the fleet"
        Write-Host "  covers it. ``just release-signed`` replaces it with the Artifact Signing"
        Write-Host "  certificate; that, not this build, is what ships."
    }
    # Rebuild, not Build: `sign-addin` rewrites the assembly and both manifests in bin, and an
    # incremental build over that leaves whichever of them it judges up to date.
    msbuild OutlookFileDrag\OutlookFileDrag.csproj /t:Rebuild `
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
msi version='': build (wix version)

# Pack OutlookFileDrag/bin/<configuration> as it stands into both MSIs.
[private]
[windows]
wix version='':
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

# --- Signed release (Azure Artifact Signing) ------------------------------

# Sign the built add-in in place: Authenticode on OutlookFileDrag.dll, then both ClickOnce
# manifests. The assembly goes first because the application manifest carries its hash;
# `sign` re-hashes every file that manifest names (mage -update), signs it, then updates and
# signs the deployment manifest.
#
# The file list names the deployment manifest by extension: `sign` works on a copy under a
# temporary name and signs only what the list matches. It also keeps the Microsoft and
# log4net assemblies as their publishers shipped them.
[doc('Sign the add-in assembly and both manifests with Azure Artifact Signing (needs az login)')]
[group('release')]
[windows]
sign-addin:
    #!pwsh
    $ErrorActionPreference = 'Stop'
    dotnet tool restore | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool restore failed (exit $LASTEXITCODE)" }
    $bin = (Resolve-Path 'OutlookFileDrag/bin/{{ CONFIGURATION }}').Path
    $common = @('code', 'artifact-signing',
        '-ase', $env:ARTIFACT_SIGNING_ENDPOINT, '-asa', $env:ARTIFACT_SIGNING_ACCOUNT, '-ascp', $env:ARTIFACT_SIGNING_PROFILE,
        '-act', 'azure-cli', '-b', $bin, '-d', 'Outlook File Drag', '-u', $env:PROJECT_URL, '-v', 'warning')
    dotnet sign @common OutlookFileDrag.dll
    if ($LASTEXITCODE -ne 0) { throw "signing OutlookFileDrag.dll failed (exit $LASTEXITCODE)" }
    $list = Join-Path ([IO.Path]::GetTempPath()) "outlookfiledrag-sign-$PID.txt"
    Set-Content -LiteralPath $list -Encoding ascii -Value '**/*.vsto', '**/OutlookFileDrag.dll.manifest'
    try {
        dotnet sign @common -fl $list -pn $env:SIGNING_PUBLISHER OutlookFileDrag.vsto
        if ($LASTEXITCODE -ne 0) { throw "signing the manifests failed (exit $LASTEXITCODE)" }
    } finally {
        Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
    }
    Write-Host "signed OutlookFileDrag.dll, OutlookFileDrag.dll.manifest and OutlookFileDrag.vsto in $bin"

[group('release')]
[unix]
sign-addin:
    @echo 'sign-addin is Windows-only.'; exit 1

# Authenticode-sign dist/OutlookFileDrag-<version>-*.msi.
[doc('Sign both MSIs with Azure Artifact Signing (needs az login)')]
[group('release')]
[positional-arguments]
[windows]
sign-msi version='':
    #!pwsh
    $ErrorActionPreference = 'Stop'
    dotnet tool restore | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool restore failed (exit $LASTEXITCODE)" }
    $ver = $args[0]
    if (-not $ver) {
        $ver = ({{ MINVER }}).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $ver) { throw "MinVer failed to derive a version (exit $LASTEXITCODE)" }
    }
    $core = $ver.Split([char]'-', 2)[0]
    $dist = (Resolve-Path 'dist').Path
    $msis = @(Get-ChildItem -LiteralPath $dist -Filter "OutlookFileDrag-$core-*.msi")
    if ($msis.Count -eq 0) { throw "no dist/OutlookFileDrag-$core-*.msi -- run: just msi $ver" }
    dotnet sign code artifact-signing `
        -ase $env:ARTIFACT_SIGNING_ENDPOINT -asa $env:ARTIFACT_SIGNING_ACCOUNT -ascp $env:ARTIFACT_SIGNING_PROFILE `
        -act azure-cli -b $dist -d 'Outlook File Drag' -u $env:PROJECT_URL -v warning @($msis.Name)
    if ($LASTEXITCODE -ne 0) { throw "signing the MSIs failed (exit $LASTEXITCODE)" }
    Write-Host "signed $($msis.Name -join ', ')"

[group('release')]
[unix]
sign-msi version='':
    @echo 'sign-msi is Windows-only.'; exit 1

# Read back what ships. Each MSI is expanded with an administrative install and its payload
# checked, because bin/ can be rebuilt after the MSI was packed and the MSI is what installs:
#   - the MSI and OutlookFileDrag.dll carry a valid Authenticode signature of SIGNING_PUBLISHER
#   - both manifests are signed by that same certificate, with a timestamp
#   - every file hash in the application manifest, and the application manifest's hash in the
#     deployment manifest, equals the file in the payload
#   - OutlookFileDrag.dll has the file version this commit builds
# Prints the signing certificate: `deploy::*` must carry exactly that one to the fleet.
[doc('Verify the signatures, manifest hashes and file version inside both MSIs')]
[group('release')]
[positional-arguments]
[windows]
verify-signed version='':
    #!pwsh
    $ErrorActionPreference = 'Stop'
    dotnet tool restore | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "dotnet tool restore failed (exit $LASTEXITCODE)" }
    $full = ({{ MINVER }}).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $full) { throw "MinVer failed to derive a version (exit $LASTEXITCODE)" }
    $ver = if ($args[0]) { $args[0] } else { $full }
    $core = $ver.Split([char]'-', 2)[0]
    $want = (Select-String -LiteralPath 'OutlookFileDrag/Properties/VersionInfo.cs' -SimpleMatch 'AssemblyFileVersion' | Select-Object -First 1).Line.Split([char]'"')[1]
    $msis = @(Get-ChildItem -LiteralPath 'dist' -Filter "OutlookFileDrag-$core-*.msi")
    if ($msis.Count -eq 0) { throw "no dist/OutlookFileDrag-$core-*.msi" }
    function Get-Sha256([string] $Path) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) } finally { $sha.Dispose() }
    }
    function Assert-Authenticode([string] $Path) {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        if ($sig.Status -ne 'Valid') { throw "$Path signature is $($sig.Status): $($sig.StatusMessage)" }
        if ($sig.SignerCertificate.GetNameInfo('SimpleName', $false) -ne $env:SIGNING_PUBLISHER) { throw "$Path is signed by $($sig.SignerCertificate.Subject), not $($env:SIGNING_PUBLISHER)" }
        if (-not $sig.TimeStamperCertificate) { throw "$Path signature has no timestamp" }
        $sig.SignerCertificate
    }
    $signers = @{}
    foreach ($msi in $msis) {
        $outer = Assert-Authenticode $msi.FullName
        $work = Join-Path ([IO.Path]::GetTempPath()) ("ofd-verify-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        try {
            $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @('/a', "`"$($msi.FullName)`"", "TARGETDIR=`"$work`"", '/qn')
            if ($p.ExitCode -ne 0) { throw "msiexec /a $($msi.Name) failed with $($p.ExitCode)" }
            $vsto = Get-ChildItem -LiteralPath $work -Recurse -Filter 'OutlookFileDrag.vsto' | Select-Object -First 1
            if (-not $vsto) { throw "no OutlookFileDrag.vsto inside $($msi.Name)" }
            $dir = $vsto.Directory.FullName
            $dll = Assert-Authenticode (Join-Path $dir 'OutlookFileDrag.dll')
            $got = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $dir 'OutlookFileDrag.dll')).FileVersion
            if ($got -ne $want) { throw "$($msi.Name): OutlookFileDrag.dll is file version $got, this commit builds $want" }
            foreach ($name in 'OutlookFileDrag.dll.manifest', 'OutlookFileDrag.vsto') {
                $doc = New-Object Xml.XmlDocument
                $doc.PreserveWhitespace = $true
                $doc.Load((Join-Path $dir $name))
                $ns = New-Object Xml.XmlNamespaceManager($doc.NameTable)
                $ns.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')
                $ns.AddNamespace('asmv2', 'urn:schemas-microsoft-com:asm.v2')
                $ns.AddNamespace('as', 'http://schemas.microsoft.com/windows/pki/2005/Authenticode')
                $node = $doc.SelectSingleNode('//ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate', $ns)
                if (-not $node) { throw "$($msi.Name): $name carries no signature certificate" }
                $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, [Convert]::FromBase64String($node.InnerText))
                if ($cert.Thumbprint -ne $dll.Thumbprint) { throw "$($msi.Name): $name is signed by $($cert.Thumbprint), the assembly by $($dll.Thumbprint)" }
                if (-not $doc.SelectSingleNode('//as:Timestamp', $ns)) { throw "$($msi.Name): $name signature has no timestamp" }
                $deps = @($doc.SelectNodes('//asmv2:dependentAssembly[@codebase]', $ns))
                if ($deps.Count -eq 0) { throw "$($msi.Name): $name names no files" }
                foreach ($dep in $deps) {
                    $file = Join-Path $dir $dep.codebase
                    $digest = $dep.SelectSingleNode('.//ds:DigestValue', $ns)
                    if (-not $digest -or -not (Test-Path -LiteralPath $file)) { throw "$($msi.Name): $name names $($dep.codebase), which has no hash or is not in the payload" }
                    if ($digest.InnerText -ne (Get-Sha256 $file)) { throw "$($msi.Name): $name carries a hash for $($dep.codebase) that is not the file in the payload" }
                }
            }
            $signers[$dll.Thumbprint] = $dll
            Write-Host "$($msi.Name): MSI signed by $($outer.Thumbprint); payload file version $got, assembly and both manifests signed by $($dll.Thumbprint), hashes match"
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($signers.Count -ne 1) { throw "the MSIs carry manifests signed by $($signers.Count) different certificates: $($signers.Keys -join ', ')" }
    $s = @($signers.Values)[0]
    Write-Host "manifest signer: $($s.Thumbprint)  $($s.Subject)"
    Write-Host "  issued by $($s.Issuer), valid $($s.NotBefore.ToUniversalTime().ToString('u')) to $($s.NotAfter.ToUniversalTime().ToString('u'))"

[group('release')]
[unix]
verify-signed version='':
    @echo 'verify-signed is Windows-only.'; exit 1

# The release that ships: build, sign the add-in, pack, sign the MSIs, read both back.
[doc('Build, sign and verify both MSIs (needs az login)')]
[group('release')]
[windows]
release-signed version='': build sign-addin (wix version) (sign-msi version) (verify-signed version)

[group('release')]
[unix]
release-signed version='':
    @echo 'release-signed is Windows-only.'; exit 1

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
