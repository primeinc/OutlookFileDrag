# Intune publisher trust for the signed VSTO manifests.
#
# Office puts every `vstolocal` add-in through the ClickOnce trust manager. A
# manifest is trusted only when its signing certificate sits in the machine
# TrustedPublisher store, or when a user accepted the trust prompt for that exact
# manifest URL *and* public key. An MDM install is silent, so it can never create
# the second kind. Until the certificate is deployed the MSI reports Installed and
# the add-in does not load.
#
# The inclusion-list entry is keyed on URL and key together, so changing either the
# install directory or the signing certificate revokes every prior user decision.
#
# `az` authenticates these recipes; point AZURE_CONFIG_DIR at the profile holding
# the Intune credential before running the trust-* recipes.
#
# The verify-* group answers "will Office load this here", never "did the MSI
# install". Its oracle is VSTOInstaller, which runs the same ClickOnce trust
# manager Office runs; the registry and certificate readings around it are inputs,
# not the answer. verify-local reports one machine, lab-verify reports a lab guest
# through the mo transport, and lab-control removes the certificate and puts it
# back to show the answer tracks that one variable — and nothing else.

[windows]
set shell := ["pwsh", "-NoLogo", "-Command"]
set script-interpreter := ["pwsh", "-NoLogo", "-NoProfile", "-File"]

# The certificate MUST come from the artifact that actually ships, never from a
# local cert store. `just build` mints a self-signed cert per BUILD MACHINE under
# one fixed subject name, so the workstation and the CI runner hold different keys
# with identical subjects. Deploying the local one publishes trust for a key that
# signed nothing the fleet runs: measured 2026-09-09, workstation
# 59CD6867CE8D9619ADF2F260C546D917B2659F88 against released
# 20ED4E09B4D4775A571B70514442C8752EE672E4.
export MSI_SOURCE := env('MSI_SOURCE', "https://github.com/primeinc/OutlookFileDrag/releases/download/v1.0.13/OutlookFileDrag-1.0.13-x64.msi")
export CERT_OUT := "dist/OutlookFileDrag-publisher.cer"
export REMEDIATION := "dist/Install-PublisherTrust.ps1"
export SCRIPT_NAME := "OutlookFileDrag publisher trust"
export GRAPH := "https://graph.microsoft.com/beta"
# adadadad-… is Intune's built-in All Devices virtual group.
export ALL_DEVICES := "adadadad-808e-44e2-905a-0b7873a8a531"

# The probes run under Windows PowerShell, not pwsh: the live add-in check needs
# Marshal.GetActiveObject, which .NET Core dropped.
export PROBE := "tools/Check-AddInTrust.ps1"
export CONTROL := "tools/Test-TrustControl.ps1"
# The lab runners reach a Proxmox guest through the mo repo's transport, which
# owns the SSH keys and the fleet table.
export MO_REPO := env('MO_REPO', replace(justfile_directory(), '\', '/') + '/../mo')
export LAB_VM := env('LAB_VM', '304')

# Read back what Intune will actually run, and report the certificate IN IT.
# The first rollout of this script shipped the workstation's key — same Subject as
# the released one, different private key, signed nothing the fleet runs. Subject
# is not identity; the thumbprint is. Nothing may target All Devices until the
# thumbprint inside the uploaded script equals the one inside the shipping MSI.
export binding_src := '''
function Get-DeployedThumbprint([string] $Graph, [string] $ScriptId) {
    $full = az rest --method get --url "$Graph/deviceManagement/deviceManagementScripts/$ScriptId" --output json
    if ($LASTEXITCODE -ne 0) { throw "graph GET failed reading script $ScriptId" }
    $body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($full | ConvertFrom-Json).scriptContent))
    # The script carries the certificate as one base64 literal in a FromBase64String
    # call. Parse it out of the AST rather than pattern-matching the source.
    $ast = [Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$null)
    $lit = $ast.FindAll({
            param($n)
            $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Length -gt 400
        }, $true) | Select-Object -First 1
    if (-not $lit) { throw "no certificate literal in the deployed script $ScriptId" }
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, [Convert]::FromBase64String($lit.Value))
    $cert.Thumbprint
}
'''

[private]
default:
    @just --list deploy

# Pull the public half of the manifest signing certificate out of the shipping MSI.
# Override the artifact with `MSI_SOURCE=<path-or-url> just deploy::cert-export`:
# a module variable is not settable with just's `NAME=value` syntax, which targets
# the root justfile, so this one reads the environment.
[doc('Extract the ClickOnce publisher certificate from the shipping MSI')]
[group('trust')]
[windows]
[script]
cert-export:
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $src = $env:MSI_SOURCE
    $out = $env:CERT_OUT
    $work = Join-Path ([IO.Path]::GetTempPath()) ("ofd-cert-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        if ($src -match '^https?://') {
            $msi = Join-Path $work 'source.msi'
            Invoke-WebRequest -Uri $src -OutFile $msi -UseBasicParsing
        } else {
            $msi = (Resolve-Path $src).Path
        }
        "artifact   : $src"
        "bytes      : $((Get-Item $msi).Length)"
        # /a is an administrative install: it expands the payload without
        # installing, so the manifest can be read on a machine that ships nothing.
        $ex = Join-Path $work 'x'
        $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
            '/a', "`"$msi`"", "TARGETDIR=`"$ex`"", '/qn')
        if ($p.ExitCode -ne 0) { throw "msiexec /a failed with $($p.ExitCode)" }
        $vsto = Get-ChildItem $ex -Recurse -Filter *.vsto | Select-Object -First 1
        if (-not $vsto) { throw "no .vsto manifest inside $src" }
        # XML-DSIG has its own namespace; dotted property access silently
        # returns nothing across it, so bind the prefix and use SelectSingleNode.
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($vsto.FullName)
        $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $ns.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')
        $node = $doc.SelectSingleNode('//ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate', $ns)
        if (-not $node) { throw "the manifest in $src carries no signature certificate" }
        $bytes = [Convert]::FromBase64String(($node.InnerText -replace '\s', ''))
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$bytes)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
        [IO.File]::WriteAllBytes($out, $cert.Export('Cert'))
        "subject    : $($cert.Subject)"
        "thumbprint : $($cert.Thumbprint)"
        "notAfter   : $($cert.NotAfter)"
        "written    : $out"
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

# Render the device-side script that installs publisher trust.
[doc('Generate the TrustedPublisher remediation script')]
[group('trust')]
[windows]
[script]
trust-script: cert-export
    $ErrorActionPreference = 'Stop'
    $cer = [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:CERT_OUT))
    $out = $env:REMEDIATION
    # The certificate is self-signed, so it is its own chain root. TrustedPublisher
    # alone leaves the chain unvalidated and the trust manager still refuses.
    # Purge any other certificate under the same subject before adding this one.
    # Every build machine mints its own key under one fixed subject name, so a
    # device can accumulate publisher trust for keys that signed nothing it runs.
    $lines = @(
        "`$ErrorActionPreference = 'Stop'"
        "`$raw = [Convert]::FromBase64String('$cer')"
        "`$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(`$raw)"
        "foreach (`$name in 'TrustedPublisher','Root') {"
        "    `$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(`$name, 'LocalMachine')"
        "    `$store.Open('ReadWrite')"
        "    foreach (`$old in @(`$store.Certificates | Where-Object { `$_.Subject -eq `$cert.Subject -and `$_.Thumbprint -ne `$cert.Thumbprint })) {"
        "        `$store.Remove(`$old)"
        "        Write-Output `"removed stale `$(`$old.Thumbprint) from LocalMachine\`$name`""
        "    }"
        "    if (-not `$store.Certificates.Find('FindByThumbprint', `$cert.Thumbprint, `$false).Count) {"
        "        `$store.Add(`$cert)"
        "        Write-Output `"added `$(`$cert.Thumbprint) to LocalMachine\`$name`""
        "    } else {"
        "        Write-Output `"already present in LocalMachine\`$name`""
        "    }"
        "    `$store.Close()"
        "}"
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
    Set-Content -Path $out -Value $lines -Encoding UTF8
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($out, [ref]$null, [ref]$errs) | Out-Null
    if ($errs) { throw "generated script does not parse: $($errs[0].Message)" }
    "written : $out (parses clean, $($lines.Count) lines)"

# Create or update the Intune platform script and target every managed device.
[doc('Publish publisher trust to Intune (all devices, SYSTEM context)')]
[group('trust')]
[confirm("Deploy the OutlookFileDrag signing certificate to TrustedPublisher AND Root on every managed device. Continue?")]
[windows]
[script]
trust-deploy: trust-script
    $ErrorActionPreference = 'Stop'
    $graph = $env:GRAPH
    $name = $env:SCRIPT_NAME
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:REMEDIATION))
    # A failed `az rest` prints to stderr and emits nothing, so an unguarded
    # pipeline turns Forbidden into an empty result. Here that would read as
    # "no script exists" and create a SECOND copy of it.
    function Invoke-Graph([string]$url) {
        $out = az rest --method get --url $url --output json
        if ($LASTEXITCODE -ne 0) {
            throw "graph GET failed (az exit $LASTEXITCODE): $url`nPoint AZURE_CONFIG_DIR at the profile holding the Intune credential; this call needs DeviceManagementScripts.Read.All."
        }
        $out | ConvertFrom-Json
    }
    $existing = (Invoke-Graph "$graph/deviceManagement/deviceManagementScripts").value |
        Where-Object { $_.displayName -eq $name } | Select-Object -First 1
    $payload = @{
        '@odata.type'   = '#microsoft.graph.deviceManagementScript'
        displayName     = $name
        description     = 'Adds the OutlookFileDrag ClickOnce publisher certificate so Office trusts the VSTO manifests.'
        scriptContent   = $content
        runAsAccount    = 'system'
        enforceSignatureCheck = $false
        fileName        = 'Install-PublisherTrust.ps1'
        runAs32Bit      = $false
    }
    $tmp = New-TemporaryFile
    ($payload | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp -Encoding UTF8
    if ($existing) {
        az rest --method patch --url "$graph/deviceManagement/deviceManagementScripts/$($existing.id)" `
            --headers 'Content-Type=application/json' --body "@$tmp" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "patch failed (az exit $LASTEXITCODE) for script $($existing.id)" }
        $id = $existing.id
        "updated script $id"
    } else {
        $created = az rest --method post --url "$graph/deviceManagement/deviceManagementScripts" `
            --headers 'Content-Type=application/json' --body "@$tmp" --output json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $created.id) { throw "create failed (az exit $LASTEXITCODE)" }
        $id = $created.id
        "created script $id"
    }
    Remove-Item $tmp -Force
    # GATE: prove what Intune now holds carries the SHIPPING artifact's key, before
    # a single device is targeted. cert-export wrote CERT_OUT from MSI_SOURCE.
    Invoke-Expression $env:binding_src
    $artifact = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $env:CERT_OUT).Thumbprint
    $deployed = Get-DeployedThumbprint $graph $id
    "artifact   : $artifact"
    "deployed   : $deployed"
    if ($artifact -ne $deployed) {
        throw "REFUSING TO ASSIGN: the uploaded script carries $deployed, the artifact at $($env:MSI_SOURCE) is signed by $artifact"
    }
    "binding OK, assigning"
    $assign = @{ deviceManagementScriptGroupAssignments = @(
        @{ '@odata.type' = '#microsoft.graph.deviceManagementScriptGroupAssignment'
           targetGroupId = $env:ALL_DEVICES }
    ) }
    $tmp2 = New-TemporaryFile
    ($assign | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp2 -Encoding UTF8
    az rest --method post --url "$graph/deviceManagement/deviceManagementScripts/$id/assign" `
        --headers 'Content-Type=application/json' --body "@$tmp2" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "assign failed (az exit $LASTEXITCODE) for script $id" }
    Remove-Item $tmp2 -Force
    "assigned to All Devices"

# Does what the fleet is running still match the artifact the fleet installs?
# Run it after any release, any re-sign, and before believing a green rollout:
# every device can report success for a certificate that signed nothing.
[doc('Prove the deployed script carries the shipping artifact key')]
[group('trust')]
[no-exit-message]
[windows]
[script]
trust-audit: cert-export
    $ErrorActionPreference = 'Stop'
    $graph = $env:GRAPH
    Invoke-Expression $env:binding_src
    $list = az rest --method get --url "$graph/deviceManagement/deviceManagementScripts" --output json
    if ($LASTEXITCODE -ne 0) { throw "graph GET failed listing scripts; this call needs DeviceManagementScripts.Read.All." }
    $script = ($list | ConvertFrom-Json).value | Where-Object { $_.displayName -eq $env:SCRIPT_NAME } | Select-Object -First 1
    if (-not $script) { "no script named '$($env:SCRIPT_NAME)' in this tenant"; exit 1 }
    $artifact = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $env:CERT_OUT).Thumbprint
    $deployed = Get-DeployedThumbprint $graph $script.id
    "artifact ($($env:MSI_SOURCE))"
    "  $artifact"
    "deployed (script $($script.id))"
    "  $deployed"
    if ($artifact -eq $deployed) { "BINDING OK"; exit 0 }
    "BINDING BROKEN: the fleet trusts a key the shipping artifact does not use"
    exit 1

# Close the rollout over the WHOLE population, not over the devices that happened
# to answer. Every Windows device resolves to exactly one state, and a device that
# has never reported is separated from one that failed, and from one that has not
# talked to Intune in days and cannot run anything.
#
# Exit 1 while any device is unresolved, so this can gate a close-out.
[doc('Per-device publisher-trust ledger over every Windows device')]
[group('trust')]
[no-exit-message]
[windows]
[script]
trust-status $stale_days='7':
    $ErrorActionPreference = 'Stop'
    $graph = $env:GRAPH
    $staleDays = [int]$env:stale_days
    # A failed `az rest` emits nothing, which an unguarded pipeline reports as an
    # empty tenant. Absence and no-permission must not print the same line.
    function Invoke-Graph([string]$url) {
        $out = az rest --method get --url $url --output json
        if ($LASTEXITCODE -ne 0) {
            throw "graph GET failed (az exit $LASTEXITCODE): $url`nPoint AZURE_CONFIG_DIR at the profile holding the Intune credential; this call needs DeviceManagementScripts.Read.All."
        }
        $out | ConvertFrom-Json
    }
    # Graph pages silently: a bare .value is the FIRST page, and a fleet that grows
    # past the page size would start reporting a shrinking denominator.
    function Invoke-GraphAll([string]$url) {
        $all = @()
        while ($url) {
            $page = Invoke-Graph $url
            $all += $page.value
            $url = $page.'@odata.nextLink'
        }
        $all
    }
    $script = (Invoke-GraphAll "$graph/deviceManagement/deviceManagementScripts") |
        Where-Object { $_.displayName -eq $env:SCRIPT_NAME } | Select-Object -First 1
    if (-not $script) { "no script named '$($env:SCRIPT_NAME)' in this tenant"; exit 1 }
    "script     : $($script.id)"
    # "awaiting" is only meaningful against how long it has been waiting.
    "assigned   : $($script.lastModifiedDateTime)"
    $states = Invoke-GraphAll "$graph/deviceManagement/deviceManagementScripts/$($script.id)/deviceRunStates?`$expand=managedDevice"
    # The population is every Windows device: the script is assigned to All Devices
    # and the agent that runs platform scripts is Windows-only.
    $fleet = Invoke-GraphAll "$graph/deviceManagement/managedDevices?`$filter=operatingSystem eq 'Windows'&`$select=id,deviceName,lastSyncDateTime"
    "population : $($fleet.Count) Windows managed devices"
    $byDevice = @{}
    foreach ($s in $states) { if ($s.managedDevice.id) { $byDevice[$s.managedDevice.id] = $s } }
    # Graph timestamps are UTC; Get-Date is local. Subtracting one from the other
    # printed "last sync -0.2d ago" — a device that had synced in the future.
    $now = (Get-Date).ToUniversalTime()
    $ledger = foreach ($d in $fleet) {
        $s = $byDevice[$d.id]
        $age = if ($d.lastSyncDateTime) {
            ($now - [datetime]::Parse($d.lastSyncDateTime, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)).TotalDays
        } else { [double]::PositiveInfinity }
        $state =
            if ($s -and $s.runState -eq 'success') { 'success' }
            elseif ($s -and $s.runState -in @('fail', 'scriptError')) { 'FAILED' }
            elseif ($s) { 'reported, not run' }
            elseif ($age -gt $staleDays) { "not checked in ({0:n0}d)" -f $age }
            else { 'awaiting its IME cycle' }
        [pscustomobject]@{ Device = $d.deviceName; State = $state; SyncDays = $age; Error = $s.errorDescription }
    }
    ""
    $ledger | Group-Object State | Sort-Object Count -Descending | ForEach-Object {
        "  {0,-28} {1}" -f $_.Name, $_.Count
    }
    $open = @($ledger | Where-Object { $_.State -ne 'success' })
    if ($open) {
        ""
        # A device that is not checking in receives NO policy at all, so it is not a
        # symptom of this rollout and there is nothing here to repair. The script is
        # assigned to All Devices with no expiry: it lands on the next check-in.
        # Devices that never come back are a device-lifecycle decision, not this one.
        "unresolved devices (stale = cannot receive any policy until it checks in):"
        $open | Sort-Object SyncDays | ForEach-Object {
            "  {0,-28} {1,-24} last sync {2:n1}d ago {3}" -f $_.State, $_.Device, $_.SyncDays, $_.Error
        }
    }
    ""
    "resolved   : $($ledger.Count - $open.Count) of $($ledger.Count) succeeded"
    if ($open) { exit 1 }

# Report whether Office will load the add-in here, and why. Exit 0 trusted, 1 not.
[doc('Diagnose add-in trust on the current machine')]
[group('verify')]
[no-exit-message]
[windows]
[script]
verify-local:
    $ErrorActionPreference = 'Stop'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $env:PROBE
    exit $LASTEXITCODE

# Copy the probes into a lab guest, as SYSTEM, and prove the copies by hash.
#
# Gzipped, because the transport puts the entire payload on one `qm guest exec`
# command line: 7 KB of PowerShell base64-expands past the Windows 32 KB argv
# limit and qemu-ga answers "Failed to execute helper program (Invalid
# argument)", which reads like a dead agent rather than an oversized argument.
[private]
[windows]
[script]
lab-push $vm:
    $ErrorActionPreference = 'Stop'
    $lines = @("`$d = 'C:\ProgramData\ofd-probe'", "New-Item -ItemType Directory -Force -Path `$d | Out-Null")
    $expect = @{}
    foreach ($p in $env:PROBE, $env:CONTROL) {
        $name = [IO.Path]::GetFileName($p)
        $expect[$name] = (Get-FileHash $p -Algorithm SHA256).Hash
        $raw = [IO.File]::ReadAllBytes($p)
        $ms = New-Object IO.MemoryStream
        $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($raw, 0, $raw.Length)
        $gz.Dispose()
        $lines += "`$z = New-Object IO.MemoryStream(,[Convert]::FromBase64String('$([Convert]::ToBase64String($ms.ToArray()))'))"
        $lines += "`$o = New-Object IO.MemoryStream"
        $lines += "(New-Object IO.Compression.GZipStream(`$z, [IO.Compression.CompressionMode]::Decompress)).CopyTo(`$o)"
        $lines += "[IO.File]::WriteAllBytes((Join-Path `$d '$name'), `$o.ToArray())"
        $lines += "'$name ' + (Get-FileHash (Join-Path `$d '$name') -Algorithm SHA256).Hash"
    }
    $out = ($lines -join "`n") | & just --justfile "$env:MO_REPO/justfile" --working-directory $env:MO_REPO lab intune-ps $env:vm
    $out
    if ($LASTEXITCODE -ne 0) { throw "could not reach vm $env:vm (exit $LASTEXITCODE)" }
    $joined = $out -join "`n"
    foreach ($e in $expect.GetEnumerator()) {
        if (-not ($joined -like "*$($e.Key) $($e.Value)*")) { throw "guest copy of $($e.Key) does not hash to $($e.Value)" }
    }
    "pushed $($expect.Count) file(s) to C:\ProgramData\ofd-probe on vm $env:vm, hashes match"

# Same probe, in a lab guest's INTERACTIVE session, so the live Outlook add-in
# state is visible. Sign a user in and start Outlook first: an add-in that never
# loaded because nobody ran Outlook is not evidence about trust.
[doc('Diagnose add-in trust in a lab VM user session: lab-verify 304')]
[group('verify')]
[no-exit-message]
[windows]
[script]
lab-verify $vm=LAB_VM: (lab-push vm)
    $ErrorActionPreference = 'Stop'
    $out = "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\ofd-probe\Check-AddInTrust.ps1'" |
        & just --justfile "$env:MO_REPO/justfile" --working-directory $env:MO_REPO lab intune-user-ps $env:vm
    $out
    if ($LASTEXITCODE -ne 0) { throw "could not reach the user session on vm $env:vm (exit $LASTEXITCODE)" }
    # The interactive hop returns the task's captured output, not its exit code,
    # so the verdict line is the result.
    $v = @($out | Where-Object { $_ -like 'VERDICT:*' })
    if (-not $v) { throw "the probe produced no verdict; is anyone signed in on vm $env:vm?" }
    if ($v[-1] -like 'VERDICT: TRUSTED*') { exit 0 }
    exit 1

# Prove the publisher certificate is the variable that decides trust, by removing
# it and putting it back. Between the two the add-in genuinely stops loading.
#
# Two transports, because no single one can do it. The lab persona is a standard
# user, so the certificate has to move as SYSTEM; VSTOInstaller installs into the
# caller's ClickOnce user store and SYSTEM under `qm guest exec` has no profile,
# so it answers -400 there before trust is evaluated. Cert edits go through
# intune-ps, every probe arm through intune-user-ps. Only the installer exit code
# decides — store membership is the variable being changed, so reading it back
# proves the change landed and nothing more.
#
# The restore is not conditional on the arms succeeding: it runs in `finally`, off
# a copy exported before the removal, and the recipe re-reads the stores after.
[doc('Run the remove/restore trust control on a lab VM: lab-control 304')]
[group('verify')]
[confirm("Temporarily REMOVE the publisher certificate from that machine's TrustedPublisher and Root stores, then restore it. Lab machines only. Continue?")]
[no-exit-message]
[windows]
[script]
lab-control $vm=LAB_VM: (lab-push vm)
    $ErrorActionPreference = 'Stop'
    $jf = "$env:MO_REPO/justfile"
    function Invoke-Guest([string] $Recipe, [string] $Ps) {
        $out = $Ps | & just --justfile $jf --working-directory $env:MO_REPO lab $Recipe $env:vm
        if ($LASTEXITCODE -ne 0) { throw "$Recipe on vm $env:vm failed (exit $LASTEXITCODE)" }
        $out
    }
    # Write-Host, not the output stream: this function's return value is the exit
    # code, and anything else it emits would be returned along with it.
    function Invoke-Arm([string] $Tag) {
        Write-Host ""
        Write-Host "########## CASE $Tag ##########"
        $out = Invoke-Guest 'intune-user-ps' "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\ofd-probe\Check-AddInTrust.ps1' -SinceHours 1"
        $out | ForEach-Object { Write-Host "  $_" }
        $line = @($out | Where-Object { $_ -like 'INSTALLER:*' })
        if (-not $line) { return 'none' }
        $line[-1].Split(':')[1].Trim()
    }
    # A just recipe body is indentation-delimited and a PowerShell here-string
    # terminator has to sit at column 0, so these payloads are line arrays.
    $read = @(
        "`$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\OutlookFileDrag').Manifest"
        "`$m = `$p.Split('|')[0].Replace('file:///', '').Replace('/', '\')"
        "`$doc = New-Object System.Xml.XmlDocument"
        "`$doc.Load(`$m)"
        "`$ns = New-Object System.Xml.XmlNamespaceManager(`$doc.NameTable)"
        "`$ns.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')"
        "`$n = `$doc.SelectSingleNode('//ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate', `$ns)"
        "`$c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String(`$n.InnerText.Trim()))"
        "'THUMB: ' + `$c.Thumbprint"
    )
    $thumb = @(Invoke-Guest 'intune-ps' ($read -join "`n") | Where-Object { $_ -like 'THUMB:*' })
    if (-not $thumb) { throw "could not read the manifest signer on vm $env:vm" }
    $thumb = $thumb[0].Split(':')[1].Trim()
    "signer under test : $thumb"

    $remove = @(
        "foreach (`$n in 'TrustedPublisher', 'Root') {"
        "    `$s = New-Object Security.Cryptography.X509Certificates.X509Store `$n, 'LocalMachine'"
        "    `$s.Open('ReadWrite')"
        "    foreach (`$c in @(`$s.Certificates.Find('FindByThumbprint', '$thumb', `$false))) {"
        "        [IO.File]::WriteAllBytes(`"C:\ProgramData\ofd-probe\restore-`$n.cer`", `$c.Export('Cert'))"
        "        `$s.Remove(`$c)"
        "        `"removed from LocalMachine\`$n`""
        "    }"
        "    `$s.Close()"
        "}"
    )
    $restore = @(
        "foreach (`$n in 'TrustedPublisher', 'Root') {"
        "    `$f = `"C:\ProgramData\ofd-probe\restore-`$n.cer`""
        "    if (-not (Test-Path `$f)) { continue }"
        "    `$c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 `$f"
        "    `$s = New-Object Security.Cryptography.X509Certificates.X509Store `$n, 'LocalMachine'"
        "    `$s.Open('ReadWrite')"
        "    if (-not `$s.Certificates.Find('FindByThumbprint', '$thumb', `$false).Count) { `$s.Add(`$c) }"
        "    `$s.Close()"
        "    Remove-Item `$f -Force"
        "    `$s.Open('ReadOnly')"
        "    `"LocalMachine\`$n holds $thumb : `" + (`$s.Certificates.Find('FindByThumbprint', '$thumb', `$false).Count -gt 0)"
        "    `$s.Close()"
        "}"
    )

    $a = Invoke-Arm 'A  certificate present'
    try {
        "";  "--- removing $thumb (SYSTEM) ---"
        Invoke-Guest 'intune-ps' ($remove -join "`n")
        $b = Invoke-Arm 'B  certificate removed'
    } finally {
        "";  "--- restoring $thumb (SYSTEM) ---"
        Invoke-Guest 'intune-ps' ($restore -join "`n")
    }
    $c = Invoke-Arm "A' certificate restored"

    "";  "########## RESULT ##########"
    "A  present  : VSTOInstaller exit $a"
    "B  removed  : VSTOInstaller exit $b"
    "A' restored : VSTOInstaller exit $c"
    if ('none' -in @($a, $b, $c) -or '-400' -in @($a, $b, $c)) {
        "CONTROL INVALID: an arm produced no trust decision, so nothing was controlled"
        exit 2
    }
    if ($a -eq '0' -and $b -eq '-300' -and $c -eq '0') {
        "CONTROL PASS: the publisher certificate is the variable that decides trust"
        exit 0
    }
    "CONTROL FAIL: expected 0 / -300 / 0; the trust decision does not track the certificate"
    exit 1

# WHICH store earns the trust: TrustedPublisher, Root, or both together.
#
# The remediation writes the certificate to both, and a self-signed certificate is
# its own chain root, so `both` cannot separate them. This strips one store at a
# time and asks the installer each way. The answer decides what a durable signing
# model has to deploy: a certificate that chains to a public root would still need
# whatever this proves TrustedPublisher does, but nothing in Root.
#
# Same two transports and the same restore-in-finally as lab-control.
[doc('Which store earns trust: TrustedPublisher, Root, or both (lab VM)')]
[group('verify')]
[confirm("Temporarily remove the publisher certificate from ONE store at a time on that machine, restoring after each. Lab machines only. Continue?")]
[no-exit-message]
[windows]
[script]
lab-store-matrix $vm=LAB_VM: (lab-push vm)
    $ErrorActionPreference = 'Stop'
    $jf = "$env:MO_REPO/justfile"
    function Invoke-Guest([string] $Recipe, [string] $Ps) {
        $out = $Ps | & just --justfile $jf --working-directory $env:MO_REPO lab $Recipe $env:vm
        if ($LASTEXITCODE -ne 0) { throw "$Recipe on vm $env:vm failed (exit $LASTEXITCODE)" }
        $out
    }
    function Invoke-Arm([string] $Tag) {
        Write-Host ""
        Write-Host "########## $Tag ##########"
        $out = Invoke-Guest 'intune-user-ps' "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\ProgramData\ofd-probe\Check-AddInTrust.ps1' -SinceHours 1"
        $out | ForEach-Object { Write-Host "  $_" }
        $line = @($out | Where-Object { $_ -like 'INSTALLER:*' })
        if (-not $line) { return 'none' }
        $line[-1].Split(':')[1].Trim()
    }
    $read = @(
        "`$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\OutlookFileDrag').Manifest"
        "`$m = `$p.Split('|')[0].Replace('file:///', '').Replace('/', '\')"
        "`$doc = New-Object System.Xml.XmlDocument"
        "`$doc.Load(`$m)"
        "`$ns = New-Object System.Xml.XmlNamespaceManager(`$doc.NameTable)"
        "`$ns.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')"
        "`$n = `$doc.SelectSingleNode('//ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate', `$ns)"
        "`$c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String(`$n.InnerText.Trim()))"
        "'THUMB: ' + `$c.Thumbprint"
    )
    $thumb = @(Invoke-Guest 'intune-ps' ($read -join "`n") | Where-Object { $_ -like 'THUMB:*' })
    if (-not $thumb) { throw "could not read the manifest signer on vm $env:vm" }
    $thumb = $thumb[0].Split(':')[1].Trim()
    "signer under test : $thumb"
    function Get-StorePayload([string] $Verb, [string[]] $Stores) {
        $l = @("foreach (`$n in $(($Stores | ForEach-Object { "'$_'" }) -join ', ')) {")
        $l += "    `$f = `"C:\ProgramData\ofd-probe\restore-`$n.cer`""
        $l += "    `$s = New-Object Security.Cryptography.X509Certificates.X509Store `$n, 'LocalMachine'"
        if ($Verb -eq 'remove') {
            $l += "    `$s.Open('ReadWrite')"
            $l += "    foreach (`$c in @(`$s.Certificates.Find('FindByThumbprint', '$thumb', `$false))) {"
            $l += "        [IO.File]::WriteAllBytes(`$f, `$c.Export('Cert'))"
            $l += "        `$s.Remove(`$c)"
            $l += "        `"removed from LocalMachine\`$n`""
            $l += "    }"
        } else {
            $l += "    if (-not (Test-Path `$f)) { `$s.Dispose(); continue }"
            $l += "    `$c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 `$f"
            $l += "    `$s.Open('ReadWrite')"
            $l += "    if (-not `$s.Certificates.Find('FindByThumbprint', '$thumb', `$false).Count) { `$s.Add(`$c) }"
            $l += "    Remove-Item `$f -Force"
            $l += "    `"restored to LocalMachine\`$n : `" + (`$s.Certificates.Find('FindByThumbprint', '$thumb', `$false).Count -gt 0)"
        }
        $l += "    `$s.Close()"
        $l += "}"
        $l -join "`n"
    }
    $results = [ordered]@{}
    $results['both present'] = Invoke-Arm 'BOTH STORES PRESENT'
    foreach ($case in @(, @('Root')), @(, @('TrustedPublisher')), @(, @('TrustedPublisher', 'Root'))) {
        $stores = $case[0]
        $label = "without " + ($stores -join ' and ')
        try {
            Write-Host ""
            Write-Host "--- removing $thumb from $($stores -join ', ') (SYSTEM) ---"
            Invoke-Guest 'intune-ps' (Get-StorePayload 'remove' $stores) | ForEach-Object { Write-Host $_ }
            $results[$label] = Invoke-Arm $label.ToUpper()
        } finally {
            Write-Host ""
            Write-Host "--- restoring $thumb (SYSTEM) ---"
            Invoke-Guest 'intune-ps' (Get-StorePayload 'restore' $stores) | ForEach-Object { Write-Host $_ }
        }
    }
    $results['both restored'] = Invoke-Arm 'BOTH STORES RESTORED'
    ""
    "########## RESULT ##########"
    foreach ($k in $results.Keys) { "  {0,-34} VSTOInstaller exit {1}" -f $k, $results[$k] }
    ""
    if ($results.Values -contains 'none' -or $results.Values -contains '-400') {
        "MATRIX INVALID: an arm produced no trust decision"
        exit 2
    }
    if ($results['both present'] -ne '0' -or $results['both restored'] -ne '0') {
        "MATRIX INVALID: the baseline arms did not both trust; the machine changed underneath the run"
        exit 2
    }
    if ($results['without Root'] -eq '0') {
        "TrustedPublisher alone is sufficient: the Root deployment is not what earns trust"
    } else {
        "Root is required for THIS certificate: self-signed, so it is its own chain root"
    }
    if ($results['without TrustedPublisher'] -eq '0') {
        "TrustedPublisher is NOT required: a validating chain alone is enough"
    } else {
        "TrustedPublisher is required: a validating chain alone does not earn silent trust"
    }
