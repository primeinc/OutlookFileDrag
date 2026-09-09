<#
.SYNOPSIS
Prove that the deployed publisher certificate is what makes Office trust the
add-in, by removing it and putting it back.

.DESCRIPTION
Check-AddInTrust.ps1 reports the current state. That alone cannot separate "the
certificate is why this works" from "something else is why this works". This runs
the same probe three times against one changed variable:

    A  certificate present   -> expect VSTOInstaller exit 0
    B  certificate removed   -> expect exit -300, with a VSTO 4.0 trust event
    A' certificate restored  -> expect exit 0

Only the installer exit code counts. The store conditions the probe also reports
are the variable being changed, so reading those back proves the change landed and
nothing else; a run that gets no installer verdict exits 2 as INVALID.

Run it in an ELEVATED INTERACTIVE session. Administrator, for
LocalMachine\TrustedPublisher; interactive, because ClickOnce installs into the
caller's user store and a profile-less context (a service, `qm guest exec` as
SYSTEM) fails in IsolationInterop.GetUserStore with -400 before trust is
evaluated.

DESTRUCTIVE while it runs. It removes the publisher certificate from
LocalMachine\TrustedPublisher and LocalMachine\Root, and restores it in a finally
block. Between B and the restore, the add-in genuinely does not load. Run it on a
lab machine, never on one somebody is using.

.PARAMETER Manifest
Manifest to test. Default: read from the machine add-in registration.
#>
[CmdletBinding()]
param(
    [string] $Manifest
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'Check-AddInTrust.ps1'
if (-not (Test-Path $probe)) { throw "probe not found beside this script: $probe" }

# Write-Host, not the output stream: this function's return value is the installer
# exit code, and anything else it emits would be returned along with it.
function Invoke-Probe([string] $Tag) {
    Write-Host ""
    Write-Host "########## CASE $Tag ##########"
    # -ExecutionPolicy Bypass: the probe is shipped to the machine under test and
    # a stock client is Restricted, which refuses -File on any .ps1.
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probe, '-SinceHours', '1')
    if ($Manifest) { $argv += @('-Manifest', $Manifest) }
    $out = & powershell.exe @argv
    $out | ForEach-Object { Write-Host "  $_" }
    # The installer exit code is the whole point of an arm: it runs the same trust
    # manager Office runs. Store membership is the variable being changed, so
    # reading that back proves only that the change landed.
    $line = @($out | Where-Object { $_ -like 'INSTALLER:*' })
    if (-not $line) { return 'none' }
    $line[-1].Split(':')[1].Trim()
}

# Resolve the signer before touching anything, so the restore has the exact bytes.
$resolve = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -SkipInstallerProbe -SinceHours 1
$thumbLine = @($resolve | Where-Object { $_ -like 'thumbprint*' })
$thumb = if ($thumbLine) { $thumbLine[0].Split(':')[1].Trim() } else { $null }
if (-not $thumb) { throw "could not resolve the manifest signer thumbprint" }
"signer under test : $thumb"

$removed = @()
try {
    $a = Invoke-Probe 'A  certificate present'

    "";  "--- removing $thumb to establish the negative control ---"
    foreach ($name in 'TrustedPublisher', 'Root') {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store $name, 'LocalMachine'
        $store.Open('ReadWrite')
        foreach ($c in @($store.Certificates.Find('FindByThumbprint', $thumb, $false))) {
            $removed += , @($name, $c)
            $store.Remove($c)
            "  removed from LocalMachine\$name"
        }
        $store.Close()
    }
    if (-not $removed) { throw "certificate $thumb was not in either store; nothing to control against" }

    $b = Invoke-Probe 'B  certificate removed'
} finally {
    "";  "--- restoring $thumb ---"
    foreach ($pair in $removed) {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store $pair[0], 'LocalMachine'
        $store.Open('ReadWrite')
        $store.Add($pair[1])
        $store.Close()
        "  restored to LocalMachine\$($pair[0])"
    }
}

$c = Invoke-Probe "A' certificate restored"

"";  "########## RESULT ##########"
"A  present  : VSTOInstaller exit $a"
"B  removed  : VSTOInstaller exit $b"
"A' restored : VSTOInstaller exit $c"
if ($a -eq 'none' -or $b -eq 'none' -or $c -eq 'none' -or $a -eq '-400' -or $b -eq '-400' -or $c -eq '-400') {
    "CONTROL INVALID: no trust decision from the installer, so nothing was controlled."
    "Run this in an ELEVATED INTERACTIVE session: it needs a loaded user profile for"
    "the ClickOnce store and administrator rights for LocalMachine\TrustedPublisher."
    exit 2
}
if ($a -eq '0' -and $b -eq '-300' -and $c -eq '0') {
    "CONTROL PASS: the publisher certificate is the variable that decides trust"
    exit 0
}
"CONTROL FAIL: expected 0 / -300 / 0; the trust decision does not track the certificate"
exit 1
