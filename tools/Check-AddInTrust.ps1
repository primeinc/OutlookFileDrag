<#
.SYNOPSIS
Report whether Office will load the OutlookFileDrag VSTO add-in on this machine.

.DESCRIPTION
Office runs every `vstolocal` add-in through the ClickOnce trust manager. Trust is
granted only when the manifest's signing certificate is in the machine
TrustedPublisher store and its chain validates, or when that user already accepted
the trust prompt for this exact manifest URL and public key. A silent MDM install
never sees a prompt, so the certificate has to be deployed. See
learn.microsoft.com/en-us/visualstudio/vsto/granting-trust-to-office-solutions.

This reports the inputs to that decision, then asks Microsoft's own installer for
the verdict. VSTOInstaller.exe accepts only /Install, /Uninstall and /Silent;
anything else returns -101, which is an argument error and says nothing about
trust. 0 means installed, -300 means security exception. See
learn.microsoft.com/en-us/previous-versions/visualstudio/visual-studio-2010/bb757423.

Run it in the session you are diagnosing. The live add-in state needs Windows
PowerShell 5.1, because .NET Core dropped Marshal.GetActiveObject.

.PARAMETER Manifest
Manifest to test. Default: read from the machine add-in registration.

.PARAMETER SkipInstallerProbe
Skip the VSTOInstaller verdict. The probe installs and immediately uninstalls the
customization, so it is not read-only; skip it on a machine in use.

.PARAMETER SinceHours
Window for VSTO runtime events. Default 24.

.OUTPUTS
Exit code 0 when the add-in is trusted, 1 when it is not, 2 when undetermined.
#>
[CmdletBinding()]
param(
    [string] $Manifest,
    [switch] $SkipInstallerProbe,
    [int] $SinceHours = 24
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Write-Section([string] $Name) { "";  "=== $Name ===" }

$verdict = 'UNDETERMINED'
$exit = 2

Write-Section 'context'
"host    : $env:COMPUTERNAME"
"user    : $(& whoami.exe)"
"psedition: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"

Write-Section 'registered add-in manifests'
$registered = @()
foreach ($view in 'Registry64', 'Registry32') {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
    $key = $base.OpenSubKey('SOFTWARE\Microsoft\Office\Outlook\Addins\OutlookFileDrag')
    if (-not $key) { "HKLM $view : (absent)"; continue }
    $m = $key.GetValue('Manifest')
    $lb = $key.GetValue('LoadBehavior')
    "HKLM $view : LoadBehavior=$lb Manifest=$m"
    $registered += $m
}
$hkcu = 'HKCU:\Software\Microsoft\Office\Outlook\Addins\OutlookFileDrag'
if (Test-Path $hkcu) {
    $p = Get-ItemProperty $hkcu
    "HKCU        : LoadBehavior=$($p.LoadBehavior) Manifest=$($p.Manifest)"
    $registered += $p.Manifest
} else { "HKCU        : (absent)" }

if (-not $Manifest) {
    # The registry value carries a file: URL with the |vstolocal suffix.
    $raw = $registered | Where-Object { $_ } | Select-Object -First 1
    if ($raw) {
        $Manifest = ($raw -split '\|')[0] -replace '^file:///', '' -replace '/', '\'
    }
}
if (-not $Manifest -or -not (Test-Path -LiteralPath $Manifest)) {
    "FAILED: no readable manifest (looked for '$Manifest')"
    "VERDICT: UNDETERMINED"
    exit 2
}
"manifest    : $Manifest"

Write-Section 'manifest signer'
# XML-DSIG lives in its own namespace. Dotted property access silently returns
# nothing across namespaces, so select with a namespace manager.
$doc = New-Object System.Xml.XmlDocument
$doc.Load($Manifest)
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')
$node = $doc.SelectSingleNode('//ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate', $ns)
if (-not $node) {
    "FAILED: the manifest carries no signature certificate"
    "VERDICT: UNDETERMINED"
    exit 2
}
$bytes = [Convert]::FromBase64String(($node.InnerText -replace '\s', ''))
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, $bytes)
"subject     : $($cert.Subject)"
"thumbprint  : $($cert.Thumbprint)"
"notAfter    : $($cert.NotAfter)"

Write-Section 'condition 1: certificate in LocalMachine\TrustedPublisher'
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store 'TrustedPublisher', 'LocalMachine'
$store.Open('ReadOnly')
$inTp = $store.Certificates.Find('FindByThumbprint', $cert.Thumbprint, $false).Count -gt 0
$stale = @($store.Certificates | Where-Object { $_.Subject -eq $cert.Subject -and $_.Thumbprint -ne $cert.Thumbprint })
$store.Close()
"in TrustedPublisher : $inTp"
foreach ($s in $stale) { "  STALE under the same subject: $($s.Thumbprint)" }

Write-Section 'condition 2: certificate chain validates'
$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
$chain.ChainPolicy.RevocationMode = 'NoCheck'
$built = $chain.Build($cert)
"chain builds : $built"
foreach ($s in $chain.ChainStatus) { "  $($s.Status): $($s.StatusInformation.Trim())" }

Write-Section 'per-user ClickOnce trust decisions'
# Keyed on manifest URL AND public key together, so moving the install directory
# or re-signing revokes every decision already stored here.
$incl = 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion'
$inclusions = @()
if (Test-Path $incl) {
    $inclusions = @(Get-ChildItem $incl | ForEach-Object { (Get-ItemProperty $_.PSPath).Url })
    foreach ($u in $inclusions) { "  $u" }
} else { "  none" }

Write-Section 'Outlook resiliency'
foreach ($k in 'DisabledItems', 'CrashingAddinList') {
    $path = "HKCU:\Software\Microsoft\Office\16.0\Outlook\Resiliency\$k"
    if (Test-Path $path) { "  $k : $((Get-Item $path).GetValueNames() -join ', ')" } else { "  $k : (absent)" }
}

Write-Section 'live Outlook add-in state'
$liveConnect = $null
if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
    "  Outlook is not running; start it as the affected user to test the load path"
} elseif ($PSVersionTable.PSEdition -eq 'Core') {
    "  needs Windows PowerShell 5.1: .NET Core has no Marshal.GetActiveObject"
} else {
    try {
        $ol = [Runtime.InteropServices.Marshal]::GetActiveObject('Outlook.Application')
        foreach ($a in $ol.COMAddIns) {
            "  {0,-32} Connect={1}" -f $a.ProgId, $a.Connect
            if ($a.ProgId -eq 'OutlookFileDrag') { $liveConnect = [bool]$a.Connect }
        }
    } catch {
        "  could not attach to Outlook: $($_.Exception.Message)"
    }
}

if (-not $SkipInstallerProbe) {
    Write-Section 'VSTOInstaller verdict'
    $inst = Get-ChildItem 'C:\Program Files\Common Files\microsoft shared\VSTO',
                          'C:\Program Files (x86)\Common Files\microsoft shared\VSTO' `
            -Recurse -Filter VSTOInstaller.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $inst) {
        "  VSTOInstaller.exe not found"
    } else {
        "  installer : $($inst.FullName)"
        $p = Start-Process $inst.FullName -Wait -PassThru -ArgumentList @('/Install', "`"$Manifest`"", '/Silent')
        $meaning = switch ($p.ExitCode) {
            0 { 'installed, so the publisher is trusted' }
            -100 { 'invalid or repeated command-line option' }
            -101 { 'invalid command-line option (NOT a trust result)' }
            -200 { 'deployment manifest URI is not valid' }
            -201 { 'deployment manifest is not valid' }
            -202 { 'application manifest VSTO section is invalid' }
            -203 { 'download error' }
            -300 { 'SECURITY EXCEPTION: publisher not trusted' }
            -400 { 'install failed for a reason that is not trust' }
            -500 { 'operation cancelled' }
            default { 'undocumented' }
        }
        "  exit $($p.ExitCode): $meaning"
        if ($p.ExitCode -eq -400) {
            # ClickOnce installs into the calling identity's user store. Run with no
            # loaded profile — `qm guest exec` as SYSTEM, a service — and it fails in
            # IsolationInterop.GetUserStore with FileNotFoundException before trust is
            # ever evaluated. Read -400 as "wrong context", never as an answer.
            "  no verdict from the installer: rerun it in a real interactive session"
        }
        "INSTALLER: $($p.ExitCode)"
        if ($p.ExitCode -eq 0) {
            $q = Start-Process $inst.FullName -Wait -PassThru -ArgumentList @('/Uninstall', "`"$Manifest`"", '/Silent')
            "  cleanup uninstall exit $($q.ExitCode)"
        }
        if ($p.ExitCode -eq 0) { $verdict = 'TRUSTED (installer)'; $exit = 0 }
        elseif ($p.ExitCode -eq -300) { $verdict = 'NOT TRUSTED (installer)'; $exit = 1 }
    }
}

Write-Section "VSTO runtime events, last $SinceHours h"
# Source 'VSTO 4.0', Application log, event 4096. See
# learn.microsoft.com/en-us/visualstudio/vsto/event-logging-for-office-solutions
$since = (Get-Date).AddHours(-$SinceHours)
$events = Get-WinEvent -FilterHashtable @{LogName = 'Application'; ProviderName = 'VSTO 4.0'; StartTime = $since } -ErrorAction SilentlyContinue
if (-not $events) { "  none" }
foreach ($e in $events) {
    $first = (($e.Message -split "`r?`n") | Where-Object { $_ -match 'Exception:' } | Select-Object -First 1)
    "  [$($e.Id)] $($e.TimeCreated)  $first"
}

if ($verdict -eq 'UNDETERMINED') {
    # No verdict from the installer: fall back to the two documented conditions.
    # Say so in the verdict — this reads the same inputs Office reads, but nothing
    # here executed the trust manager.
    if ($inTp -and $built) { $verdict = 'TRUSTED (store conditions, not the installer)'; $exit = 0 }
    elseif ($inclusions | Where-Object { $_ -and $Manifest -and $_ -like "*$([IO.Path]::GetFileName($Manifest))*" }) { $verdict = 'TRUSTED (per-user inclusion entry)'; $exit = 0 }
    else { $verdict = 'NOT TRUSTED (store conditions, not the installer)'; $exit = 1 }
}

""
if ($null -ne $liveConnect) { "LIVE   : Outlook reports OutlookFileDrag Connect=$liveConnect" }
# Trust is evaluated when Outlook loads the add-in, so a running Outlook keeps a
# customization it already loaded even after the certificate goes away. A live
# Connect=True describes the session that started, not the machine as it stands.
if ($liveConnect -and $exit -eq 1) { "NOTE   : Outlook loaded this before trust changed; the next start would not" }
"VERDICT: $verdict"
exit $exit
