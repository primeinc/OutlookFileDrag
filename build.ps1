<#
.SYNOPSIS
    Builds the OutlookFileDrag add-in and both WiX MSI installers from the command line.

.DESCRIPTION
    Replaces the legacy Visual Studio Deployment Projects. Steps:
      1. Restore NuGet packages (packages.config -> needs nuget.exe, not `dotnet restore`).
      2. Ensure a code-signing certificate exists (VSTO requires signed ClickOnce
         manifests). A self-signed cert is generated on first run; identity is
         irrelevant because the MSI installs per-machine into Program Files, a
         location the VSTO runtime trusts without validating the manifest signature.
      3. Build the add-in with full MSBuild (VSTO targets are absent from the dotnet SDK).
      4. Build OutlookFileDrag-$Version-x86.msi and -x64.msi with `wix build`.

    Unsigned/self-signed output by design. Run from the repository root.

.NOTES
    Outputs land in .\dist\. Requires: VS 2026 (Office/VSTO + .NET desktop workloads),
    .NET 10 SDK (for the `wix` global tool), internet access for first-run restore/tool install.
#>
[CmdletBinding()]
param(
    [string]$Version       = "1.0.13",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot
Set-Location $repo

function Resolve-MSBuild {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found; Visual Studio is required." }
    $vsPath = & $vswhere -latest -prerelease -requires Microsoft.Component.MSBuild -property installationPath
    if (-not $vsPath) { throw "No Visual Studio install with MSBuild found." }
    $msb = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"
    if (-not (Test-Path $msb)) { throw "MSBuild.exe not found under $vsPath." }
    return $msb
}

function Resolve-NuGet {
    # Pinned version + SHA-256 so the auto-download is reproducible and auditable (versioned
    # dist.nuget.org URLs are immutable, unlike .../latest/). A pre-supplied .tools\nuget.exe or
    # a nuget.exe on PATH is trusted and used as-is.
    $nugetVersion = "6.11.0"
    $nugetSha256  = "133B9C1EFDC8D86BDCCAE9E296C9E4BC45A6D6472368611AA96B51B3E75FD2E3"

    $local = Join-Path $repo ".tools\nuget.exe"
    if (Test-Path $local) { return $local }
    $onPath = Get-Command nuget.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    Write-Host "Downloading nuget.exe $nugetVersion ..."
    New-Item -ItemType Directory -Force (Join-Path $repo ".tools") | Out-Null
    Invoke-WebRequest "https://dist.nuget.org/win-x86-commandline/v$nugetVersion/nuget.exe" -OutFile $local
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $local).Hash
    if ($actual -ne $nugetSha256) {
        Remove-Item -LiteralPath $local -Force
        throw "nuget.exe $nugetVersion SHA-256 mismatch: expected $nugetSha256, got $actual"
    }
    return $local
}

function Resolve-SigningThumbprint {
    # A self-signed code-signing cert in CurrentUser\My, persisted to .tools\SigningCert.pfx
    # for reproducibility. Idempotent: re-imports the pfx into the store if missing.
    $subject = "CN=OutlookFileDrag (Self-Signed Build)"
    $pfx     = Join-Path $repo ".tools\SigningCert.pfx"

    $cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $subject } | Select-Object -First 1
    if ($cert) { return $cert.Thumbprint }

    if (Test-Path $pfx) {
        $cert = Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:\CurrentUser\My -Exportable
        return $cert.Thumbprint
    }

    Write-Host "Generating self-signed code-signing certificate ..."
    New-Item -ItemType Directory -Force (Join-Path $repo ".tools") | Out-Null
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
        -KeyExportPolicy Exportable -CertStoreLocation Cert:\CurrentUser\My `
        -NotAfter (Get-Date).AddYears(10)
    [System.IO.File]::WriteAllBytes($pfx, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, ""))
    return $cert.Thumbprint
}

# --- 1. Restore -----------------------------------------------------------
$nuget = Resolve-NuGet
Write-Host "Restoring NuGet packages ..."
& $nuget restore "OutlookFileDrag.sln"
if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed." }

# --- 2. Signing cert ------------------------------------------------------
$thumb = Resolve-SigningThumbprint
Write-Host "Signing manifests with certificate $thumb"

# --- 3. Build add-in ------------------------------------------------------
$msbuild = Resolve-MSBuild
Write-Host "Building add-in ($Configuration) ..."
& $msbuild "OutlookFileDrag\OutlookFileDrag.csproj" `
    /t:Build /p:Configuration=$Configuration /p:Platform=AnyCPU `
    /p:ManifestCertificateThumbprint=$thumb /v:m /nologo
if ($LASTEXITCODE -ne 0) { throw "Add-in build failed." }

# --- 4. WiX tool + extensions --------------------------------------------
# Pinned to WiX v5: v6/v7 require accepting the Open Source Maintenance Fee EULA,
# which adds interactive friction unsuitable for an unattended build.
$wixVersion = "5.0.2"
$env:PATH = "$env:PATH;$env:USERPROFILE\.dotnet\tools"
$wixOk = (Get-Command wix -ErrorAction SilentlyContinue) -and ((wix --version) -like "5.*")
if (-not $wixOk) {
    Write-Host "Installing WiX $wixVersion global tool ..."
    dotnet tool uninstall --global wix 2>$null | Out-Null
    dotnet tool install --global wix --version $wixVersion
    if ($LASTEXITCODE -ne 0) { throw "Failed to install wix $wixVersion." }
}
# Extension versions must match the tool's major version.
wix extension add -g "WixToolset.UI.wixext/$wixVersion"
if ($LASTEXITCODE -ne 0) { throw "Failed to add WixToolset.UI.wixext." }
wix extension add -g "WixToolset.Netfx.wixext/$wixVersion"
if ($LASTEXITCODE -ne 0) { throw "Failed to add WixToolset.Netfx.wixext." }

# --- 5. Build MSIs --------------------------------------------------------
# File/@Source names resolve against bind paths (-b): the build output dir for
# payload assemblies, and the repo root for License.rtf.
New-Item -ItemType Directory -Force (Join-Path $repo "dist") | Out-Null
foreach ($arch in @("x86", "x64")) {
    $out = "dist\OutlookFileDrag-$Version-$arch.msi"
    Write-Host "Building $out ..."
    wix build "installer\OutlookFileDrag.wxs" -arch $arch `
        -d Version=$Version `
        -b "OutlookFileDrag\bin\$Configuration" -b "." `
        -ext WixToolset.UI.wixext -ext WixToolset.Netfx.wixext `
        -o $out
    if ($LASTEXITCODE -ne 0) { throw "wix build failed for $arch." }
}

Write-Host "`nDone. Installers:" -ForegroundColor Green
Get-ChildItem "dist\*.msi" | ForEach-Object { Write-Host "  $($_.FullName)" }
