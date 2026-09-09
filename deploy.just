# Intune publisher trust for the signed VSTO manifests.
#
# Office puts every `vstolocal` add-in through the ClickOnce trust manager. A
# manifest is trusted when its signing certificate is in the machine
# TrustedPublisher store AND its chain validates, or when the user's inclusion
# list holds an entry for that exact manifest URL *and* public key. Either path
# alone is sufficient; measured on lab VM 304, see docs/PUBLISHER-TRUST.md. Until
# one of them is in place the MSI reports Installed and the add-in does not load.
#
# An MDM install is silent, so it never produces a trust PROMPT -- but an Intune
# user-context script writes the inclusion entry directly, which is what
# inclusion-deploy does. That path needs no machine store, and so no self-signed
# certificate in Root.
#
# The inclusion-list entry is keyed on URL and key together, so changing either the
# install directory or the signing certificate revokes every prior grant.
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

# The per-user trust path. Measured on lab VM 304 with `lab-inclusion`: an entry
# under HKCU\Software\Microsoft\VSTO\Security\Inclusion earns trust with the
# certificate in NEITHER machine store and no chain that validates.
#
#   machine stores present            VSTOInstaller exit 0
#   no store, no inclusion            VSTOInstaller exit -300
#   inclusion only, literal spaces    VSTOInstaller exit 0
#   inclusion only, escaped spaces    VSTOInstaller exit 0
#
# That is what retires the self-signed root. TrustedPublisher plus a validating
# chain and a per-user inclusion entry are ALTERNATIVE paths to the same trust
# decision, and only the first requires standing authority to mint certificates
# on 57 machines. The grant here is the narrowest the platform offers: one
# manifest URL bound to one public key, and nothing else.
export INCLUSION_REMEDIATION := "dist/Install-PublisherInclusion.ps1"
export INCLUSION_NAME := "OutlookFileDrag publisher trust (per-profile)"
export RETIRE_REMEDIATION := "dist/Remove-PublisherTrust.ps1"
export RETIRE_NAME := "OutlookFileDrag publisher trust (retire machine stores)"

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
    # Which stores this has to write is a property of the CERTIFICATE, not a
    # constant. Measured with `lab-store-matrix`: TrustedPublisher membership and a
    # chain that validates are both necessary and neither is sufficient. A
    # self-signed certificate is its own chain root, so satisfying condition 2 means
    # installing it as a root -- standing authority to mint trust for anything that
    # key signs. A CA-issued certificate needs no such thing, and installing one
    # would be gratuitous. Decide from the certificate.
    $signer = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $env:CERT_OUT
    $selfSigned = $signer.Subject -eq $signer.Issuer
    $stores = if ($selfSigned) { "'TrustedPublisher','Root'" } else { "'TrustedPublisher'" }
    "signer     : $($signer.Subject)"
    "issuer     : $($signer.Issuer)"
    if ($selfSigned) {
        "stores     : TrustedPublisher + Root (self-signed, so it is its own chain root)"
    } else {
        "stores     : TrustedPublisher only (issued by $($signer.Issuer); no root deployment)"
    }
    # Purge any other certificate under the same subject before adding this one.
    # Every build machine mints its own key under one fixed subject name, so a
    # device can accumulate publisher trust for keys that signed nothing it runs.
    $lines = @(
        "`$ErrorActionPreference = 'Stop'"
        "`$raw = [Convert]::FromBase64String('$cer')"
        "`$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(`$raw)"
        "foreach (`$name in $stores) {"
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
trust-status $stale_days='7' $script_name=SCRIPT_NAME:
    $ErrorActionPreference = 'Stop'
    $graph = $env:GRAPH
    $staleDays = [int]$env:stale_days
    $name = $env:script_name
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
        Where-Object { $_.displayName -eq $name } | Select-Object -First 1
    if (-not $script) { "no script named '$name' in this tenant"; exit 1 }
    "script     : $($script.id) ($($script.runAsAccount) context)"
    # "awaiting" is only meaningful against how long it has been waiting.
    "assigned   : $($script.lastModifiedDateTime)"
    $states = Invoke-GraphAll "$graph/deviceManagement/deviceManagementScripts/$($script.id)/deviceRunStates?`$expand=managedDevice"
    # A user-context script may report under userRunStates instead. An empty
    # deviceRunStates would then print a fleet where nothing ran, which is a
    # false zero, not a result. Say so and refuse rather than draw the ledger.
    if (-not $states) {
        $users = Invoke-GraphAll "$graph/deviceManagement/deviceManagementScripts/$($script.id)/userRunStates"
        if ($users) {
            "deviceRunStates is empty but userRunStates holds $($users.Count) entries:"
            $users | Group-Object -Property { "$($_.successDeviceCount) ok / $($_.errorDeviceCount) error" } |
                ForEach-Object { "  {0,-28} {1} user(s)" -f $_.Name, $_.Count }
            ""
            "this script reports PER USER; the per-device ledger cannot close it"
            exit 2
        }
    }
    "run states : $($states.Count)"
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


# Render the device-side script that grants trust from user hives alone.
#
# It carries the shipping certificate as one base64 literal, exactly like
# trust-script, so `Get-DeployedThumbprint` reads this script's binding too.
# Everything else is derived on the device: the manifest URL comes from the
# machine add-in registration, so the entry names whatever path the MSI actually
# installed to, and the public key is computed from the carried certificate.
#
# It runs as SYSTEM and writes into every profile hive on the machine, plus the
# Default hive so profiles created later inherit the grant. A user-context script
# would be a third of the code and would reach only whoever happens to be signed
# in -- on a fleet where most devices have nobody signed in at any given moment,
# that never converges, and the machine stores could never be retired.
[doc('Generate the per-profile inclusion-list script (no machine store)')]
[group('trust')]
[windows]
[script]
inclusion-script: cert-export
    $ErrorActionPreference = 'Stop'
    $cer = [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:CERT_OUT))
    $out = $env:INCLUSION_REMEDIATION
    $signer = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $env:CERT_OUT
    "signer     : $($signer.Subject)"
    "thumbprint : $($signer.Thumbprint)"
    "stores     : none -- one entry per profile hive, bound to this key and this URL"
    # No regex: the manifest value is a structured string with a known prefix and
    # a `|vstolocal` suffix, so Split and Substring read it exactly.
    $lines = @(
        "`$ErrorActionPreference = 'Stop'"
        "`$raw = [Convert]::FromBase64String('$cer')"
        "`$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(`$raw)"
        "`$key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey(`$cert).ToXmlString(`$false)"
        "`$reg = @("
        "    'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\OutlookFileDrag'"
        "    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\Outlook\Addins\OutlookFileDrag'"
        ")"
        "`$manifest = `$null"
        "foreach (`$r in `$reg) {"
        "    if (-not (Test-Path `$r)) { continue }"
        "    `$v = (Get-ItemProperty `$r).Manifest"
        "    if (`$v) { `$manifest = `$v; break }"
        "}"
        "if (-not `$manifest) {"
        "    Write-Output 'OutlookFileDrag is not registered on this machine; nothing to trust'"
        "    exit 0"
        "}"
        "`$path = `$manifest.Split('|')[0]"
        "if (`$path.StartsWith('file:///')) { `$path = `$path.Substring(8) }"
        "`$url = 'file:///' + `$path.Replace('\', '/')"
        "Write-Output `"manifest: `$url`""
        # reg.exe writes its diagnostics to stderr, and under
        # ErrorActionPreference = Stop a redirected native stderr line becomes a
        # TERMINATING error -- the script died on `ERROR: Access is denied.`
        # before it could read LASTEXITCODE and report which hive it was.
        "function Invoke-Reg([string[]] `$Argv) {"
        "    `$prev = `$ErrorActionPreference"
        "    `$ErrorActionPreference = 'Continue'"
        "    try {"
        "        `$o = (& reg.exe @Argv 2>&1 | Out-String).Trim()"
        "        return , @(`$LASTEXITCODE, `$o)"
        "    } finally { `$ErrorActionPreference = `$prev }"
        "}"
        # The .NET registry API, not the PowerShell provider. `reg unload` fails
        # with Access denied while ANY handle into the hive is open, and the
        # provider keeps its keys open past the statement that used them -- four
        # of seven hives refused to unload, and a hive left mounted BLOCKS THAT
        # USER'S SIGN-IN. Here every key is disposed on its own finally, so the
        # handles are gone before the unload rather than whenever GC decides.
        #
        # CreateSubKey is also the correct primitive: it creates missing parents
        # and LEAVES an existing key's children alone. `New-Item -Force` on an
        # existing registry key recreates it and drops every subkey under it --
        # here, every VSTO add-in's trust grant for that user.
        "function Grant-Trust([string] `$Hive, [string] `$Who) {"
        "    `$rel = `"`$Hive\Software\Microsoft\VSTO\Security\Inclusion`""
        "    `$base = `$null"
        "    try {"
        "        `$base = [Microsoft.Win32.Registry]::Users.CreateSubKey(`$rel)"
        "        `$hit = `$null"
        "        foreach (`$name in @(`$base.GetSubKeyNames())) {"
        "            `$sub = `$null"
        "            `$stale = `$false"
        "            try {"
        "                `$sub = `$base.OpenSubKey(`$name, `$false)"
        "                if (-not `$sub) { continue }"
        "                if (`$sub.GetValue('Url') -ne `$url) { continue }"
        "                if (`$sub.GetValue('PublicKey') -eq `$key) { `$hit = `$name; continue }"
        "                `$stale = `$true"
        "            } finally { if (`$sub) { `$sub.Dispose() } }"
        "            if (`$stale) {"
        "                `$base.DeleteSubKeyTree(`$name)"
        "                Write-Output `"`$Who : removed stale entry `$name`""
        "            }"
        "        }"
        "        if (`$hit) { Write-Output `"`$Who : already trusted (`$hit)`"; return }"
        "        `$g = [Guid]::NewGuid().ToString()"
        "        `$new = `$null"
        "        try {"
        "            `$new = `$base.CreateSubKey(`$g)"
        "            `$new.SetValue('Url', `$url, [Microsoft.Win32.RegistryValueKind]::String)"
        "            `$new.SetValue('PublicKey', `$key, [Microsoft.Win32.RegistryValueKind]::String)"
        "        } finally { if (`$new) { `$new.Dispose() } }"
        "        Write-Output `"`$Who : granted (`$g)`""
        "    } finally { if (`$base) { `$base.Dispose() } }"
        "}"
        # Every profile with a hive on disk, plus the Default hive so a profile
        # created after this runs inherits the grant instead of waiting a cycle.
        "`$targets = @()"
        "`$pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'"
        # LocalSystem, LocalService and NetworkService have profiles and hives,
        # and they never run Outlook. Writing a trust grant into them is pure
        # collateral. Skip them by SID, not by profile path, which varies.
        "`$service = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')"
        "foreach (`$k in @(Get-ChildItem `$pl)) {"
        "    if (`$service -contains `$k.PSChildName) { continue }"
        "    `$img = (Get-ItemProperty `$k.PSPath).ProfileImagePath"
        "    if (-not `$img) { continue }"
        "    if (-not (Test-Path (Join-Path `$img 'NTUSER.DAT'))) { continue }"
        "    `$targets += , @(`$k.PSChildName, `$img)"
        "}"
        "`$targets += , @('.DEFAULT-PROFILE', (Join-Path `$env:SystemDrive 'Users\Default'))"
        "`$failed = 0"
        "foreach (`$t in `$targets) {"
        "    `$sid = `$t[0]"
        "    `$dat = Join-Path `$t[1] 'NTUSER.DAT'"
        "    if (-not (Test-Path `$dat)) { continue }"
        "    if (Test-Path `"Registry::HKEY_USERS\`$sid`") {"
        "        Grant-Trust `$sid `$sid"
        "        continue"
        "    }"
        # An unloaded hive is a file. Mount it under a name of our own so nothing
        # collides with a profile signing in while this runs, and unmount it.
        "    `$tmp = 'OFD-' + `$sid"
        "    `$r = Invoke-Reg @('load', `"HKU\`$tmp`", `$dat)"
        "    if (`$r[0] -ne 0) {"
        "        `$failed++"
        "        Write-Output `"`$sid : COULD NOT LOAD HIVE (`$(`$r[1]))`""
        "        continue"
        "    }"
        "    try {"
        "        Grant-Trust `$tmp `$sid"
        "    } catch {"
        "        `$failed++"
        "        Write-Output `"`$sid : FAILED `$(`$_.Exception.Message)`""
        "    } finally {"
        "        `$u = Invoke-Reg @('unload', `"HKU\`$tmp`")"
        "        if (`$u[0] -ne 0) {"
        "            `$failed++"
        "            Write-Output `"`$sid : COULD NOT UNLOAD HIVE (`$(`$u[1]))`""
        "        }"
        "    }"
        "}"
        "if (`$failed) { throw `"`$failed profile(s) did not receive the grant`" }"
        "Write-Output `"profiles processed: `$(`$targets.Count)`""
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
    Set-Content -Path $out -Value $lines -Encoding UTF8
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($out, [ref]$null, [ref]$errs) | Out-Null
    if ($errs) { throw "generated script does not parse: $($errs[0].Message)" }
    "written    : $out (parses clean, $($lines.Count) lines)"

# Render the script that takes the machine stores back out.
#
# Removal is by SUBJECT, not thumbprint: the point is to leave no OutlookFileDrag
# publisher certificate in any machine store, including keys from build machines
# that no longer exist. It carries the shipping certificate anyway so the same
# binding gate applies to it.
[doc('Generate the script that removes the machine-store trust')]
[group('trust')]
[windows]
[script]
retire-script: cert-export
    $ErrorActionPreference = 'Stop'
    $cer = [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:CERT_OUT))
    $out = $env:RETIRE_REMEDIATION
    $signer = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $env:CERT_OUT
    "subject    : $($signer.Subject)"
    "removes    : LocalMachine\TrustedPublisher and LocalMachine\Root"
    $lines = @(
        "`$ErrorActionPreference = 'Stop'"
        "`$raw = [Convert]::FromBase64String('$cer')"
        "`$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(`$raw)"
        "foreach (`$name in 'TrustedPublisher', 'Root') {"
        "    `$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(`$name, 'LocalMachine')"
        "    `$store.Open('ReadWrite')"
        "    `$gone = 0"
        "    foreach (`$c in @(`$store.Certificates | Where-Object { `$_.Subject -eq `$cert.Subject })) {"
        "        `$store.Remove(`$c)"
        "        `$gone++"
        "        Write-Output `"removed `$(`$c.Thumbprint) from LocalMachine\`$name`""
        "    }"
        "    if (-not `$gone) { Write-Output `"nothing to remove from LocalMachine\`$name`" }"
        "    `$store.Close()"
        "}"
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
    Set-Content -Path $out -Value $lines -Encoding UTF8
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($out, [ref]$null, [ref]$errs) | Out-Null
    if ($errs) { throw "generated script does not parse: $($errs[0].Message)" }
    "written    : $out (parses clean, $($lines.Count) lines)"

# Publish the per-user grant. Same binding gate as trust-deploy: nothing targets
# a population until the key inside the uploaded script equals the key inside the
# shipping artifact.
[doc('Publish the per-profile inclusion grant to Intune (all devices, SYSTEM)')]
[group('trust')]
[confirm("Deploy the per-profile OutlookFileDrag trust grant to every managed device. Continue?")]
[windows]
[script]
inclusion-deploy: inclusion-script
    $ErrorActionPreference = 'Stop'
    $graph = $env:GRAPH
    $name = $env:INCLUSION_NAME
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:INCLUSION_REMEDIATION))
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
        '@odata.type'         = '#microsoft.graph.deviceManagementScript'
        displayName           = $name
        description           = 'Grants OutlookFileDrag ClickOnce trust in every profile hive via the VSTO inclusion list. No certificate is written to any machine store.'
        scriptContent         = $content
        runAsAccount          = 'system'
        enforceSignatureCheck = $false
        fileName              = 'Install-PublisherInclusion.ps1'
        runAs32Bit            = $false
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
                targetGroupId = $env:ALL_DEVICES
            }
        )
    }
    $tmp2 = New-TemporaryFile
    ($assign | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp2 -Encoding UTF8
    az rest --method post --url "$graph/deviceManagement/deviceManagementScripts/$id/assign" `
        --headers 'Content-Type=application/json' --body "@$tmp2" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "assign failed (az exit $LASTEXITCODE) for script $id" }
    Remove-Item $tmp2 -Force
    "assigned to All Devices"

# Take the self-signed certificate back out of the machine stores.
#
# ORDER IS LOAD-BEARING. Removing the machine stores while a user has no
# inclusion entry withdraws trust from that user: measured, exit -300. This
# refuses to run until the per-user grant has succeeded everywhere the machine
# script did, so the fleet is never between two models.
[doc('Retire the machine-store trust once the per-user grant has landed')]
[group('trust')]
[confirm("Remove the OutlookFileDrag publisher certificate from TrustedPublisher AND Root on every managed device. The per-user grant must already cover them. Continue?")]
[no-exit-message]
[windows]
[script]
retire-deploy: retire-script
    $ErrorActionPreference = 'Stop'
    $graph = $env:GRAPH
    function Invoke-Graph([string]$url) {
        $out = az rest --method get --url $url --output json
        if ($LASTEXITCODE -ne 0) { throw "graph GET failed (az exit $LASTEXITCODE): $url" }
        $out | ConvertFrom-Json
    }
    function Invoke-GraphAll([string]$url) {
        $all = @()
        while ($url) {
            $page = Invoke-Graph $url
            $all += $page.value
            $url = $page.'@odata.nextLink'
        }
        $all
    }
    $scripts = Invoke-GraphAll "$graph/deviceManagement/deviceManagementScripts"
    # GATE: the replacement must be in place and reporting success before the
    # thing it replaces is removed. A grant that was merely UPLOADED proves
    # nothing about the devices.
    $grant = $scripts | Where-Object { $_.displayName -eq $env:INCLUSION_NAME } | Select-Object -First 1
    if (-not $grant) {
        "REFUSING: no script named '$($env:INCLUSION_NAME)' in this tenant."
        "Run `just deploy::inclusion-deploy` and let it land before retiring the stores."
        exit 1
    }
    $old = $scripts | Where-Object { $_.displayName -eq $env:SCRIPT_NAME } | Select-Object -First 1
    $grantStates = @(Invoke-GraphAll "$graph/deviceManagement/deviceManagementScripts/$($grant.id)/deviceRunStates?`$expand=managedDevice")
    if (-not $grantStates) {
        $grantUsers = @(Invoke-GraphAll "$graph/deviceManagement/deviceManagementScripts/$($grant.id)/userRunStates")
        "REFUSING: the per-user grant has no device run states yet ($($grantUsers.Count) user states)."
        "Nothing has confirmed it ran, so removing the machine stores would withdraw trust."
        exit 1
    }
    $ok = @($grantStates | Where-Object { $_.runState -eq 'success' -and $_.managedDevice.id })
    $covered = @{}
    foreach ($s in $ok) { $covered[$s.managedDevice.id] = $true }
    "per-user grant : $($grant.id), $($covered.Count) device(s) succeeded"
    # The devices that must be covered are the ones the machine script reached.
    # Those are exactly the machines carrying a certificate this would remove.
    $need = @()
    if ($old) {
        $oldStates = @(Invoke-GraphAll "$graph/deviceManagement/deviceManagementScripts/$($old.id)/deviceRunStates?`$expand=managedDevice")
        $need = @($oldStates | Where-Object { $_.runState -eq 'success' -and $_.managedDevice.id })
        "machine script : $($old.id), $($need.Count) device(s) carry the certificate"
    }
    $gap = @($need | Where-Object { -not $covered[$_.managedDevice.id] })
    if ($gap) {
        ""
        "REFUSING: $($gap.Count) device(s) hold the machine-store trust with no per-user grant:"
        $gap | ForEach-Object { "  $($_.managedDevice.deviceName)" }
        ""
        "Removing the stores now would leave Office refusing to load the add-in there."
        exit 1
    }
    "coverage OK: every device carrying the certificate has the per-user grant"
    $name = $env:RETIRE_NAME
    $content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:RETIRE_REMEDIATION))
    $existing = $scripts | Where-Object { $_.displayName -eq $name } | Select-Object -First 1
    $payload = @{
        '@odata.type'         = '#microsoft.graph.deviceManagementScript'
        displayName           = $name
        description           = 'Removes the OutlookFileDrag publisher certificate from the machine stores. Trust comes from the per-user inclusion list instead.'
        scriptContent         = $content
        runAsAccount          = 'system'
        enforceSignatureCheck = $false
        fileName              = 'Remove-PublisherTrust.ps1'
        runAs32Bit            = $false
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
    $assign = @{ deviceManagementScriptGroupAssignments = @(
            @{ '@odata.type' = '#microsoft.graph.deviceManagementScriptGroupAssignment'
                targetGroupId = $env:ALL_DEVICES
            }
        )
    }
    $tmp2 = New-TemporaryFile
    ($assign | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp2 -Encoding UTF8
    az rest --method post --url "$graph/deviceManagement/deviceManagementScripts/$id/assign" `
        --headers 'Content-Type=application/json' --body "@$tmp2" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "assign failed (az exit $LASTEXITCODE) for script $id" }
    Remove-Item $tmp2 -Force
    "assigned to All Devices"
    # Unassign the script this replaces IN THE SAME RUN. Leaving it targeted
    # means the two fight: removal runs, then the machine-store script re-adds
    # the certificate on the next cycle, and the fleet never actually retires
    # anything. Telling a human to do it afterwards is not a rollout.
    if ($old) {
        $none = @{ deviceManagementScriptGroupAssignments = @() }
        $tmp3 = New-TemporaryFile
        ($none | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp3 -Encoding UTF8
        az rest --method post --url "$graph/deviceManagement/deviceManagementScripts/$($old.id)/assign" `
            --headers 'Content-Type=application/json' --body "@$tmp3" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not unassign the machine-store script $($old.id); it will re-add the certificate" }
        Remove-Item $tmp3 -Force
        $check = az rest --method get --url "$graph/deviceManagement/deviceManagementScripts/$($old.id)/assignments" --output json | ConvertFrom-Json
        "machine-store script $($old.id) now has $(@($check.value).Count) assignment(s)"
        if (@($check.value).Count -ne 0) { throw "the machine-store script is still assigned; it will put the certificate back" }
    }
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
    # ONE FILE PER CALL. Batching them shares one argv, so adding a file or
    # growing one silently pushes the batch over the limit and the failure
    # surfaces as "agent down" rather than "payload too big". Per-file, each
    # payload is bounded by the largest single file.
    $sent = 0
    # INCLUSION_REMEDIATION is the generated production script; it only exists
    # after `inclusion-script` has run, and lab-inclusion-prod needs the exact
    # bytes Intune will carry rather than a re-implementation of them.
    foreach ($p in $env:PROBE, $env:CONTROL, $env:INCLUSION_REMEDIATION) {
        if (-not (Test-Path $p)) { continue }
        $name = [IO.Path]::GetFileName($p)
        $hash = (Get-FileHash $p -Algorithm SHA256).Hash
        $raw = [IO.File]::ReadAllBytes($p)
        $ms = New-Object IO.MemoryStream
        $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
        $gz.Write($raw, 0, $raw.Length)
        $gz.Dispose()
        $b64 = [Convert]::ToBase64String($ms.ToArray())
        $lines = @(
            "`$d = 'C:\ProgramData\ofd-probe'"
            "New-Item -ItemType Directory -Force -Path `$d | Out-Null"
            "`$z = New-Object IO.MemoryStream(,[Convert]::FromBase64String('$b64'))"
            "`$o = New-Object IO.MemoryStream"
            "(New-Object IO.Compression.GZipStream(`$z, [IO.Compression.CompressionMode]::Decompress)).CopyTo(`$o)"
            "[IO.File]::WriteAllBytes((Join-Path `$d '$name'), `$o.ToArray())"
            "'$name ' + (Get-FileHash (Join-Path `$d '$name') -Algorithm SHA256).Hash"
        )
        # The transport puts the whole payload on one `qm guest exec` command
        # line as UTF-16LE base64, so the argv cost is roughly 8/3 of this.
        $argv = [int]([Text.Encoding]::Unicode.GetByteCount($lines -join "`n") * 4 / 3)
        if ($argv -gt 30000) {
            throw "$name would need ~$argv bytes of argv, past the 32 KB Windows limit; the transport cannot carry it"
        }
        $out = ($lines -join "`n") | & just --justfile "$env:MO_REPO/justfile" --working-directory $env:MO_REPO lab intune-ps $env:vm
        if ($LASTEXITCODE -ne 0) { throw "could not reach vm $env:vm pushing $name (exit $LASTEXITCODE)" }
        if (-not (($out -join "`n") -like "*$name $hash*")) { throw "guest copy of $name does not hash to $hash" }
        "  $name  $hash  (~$argv bytes argv)"
        $sent++
    }
    "pushed $sent file(s) to C:\ProgramData\ofd-probe on vm $env:vm, hashes match"

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
        if ($LASTEXITCODE -ne 0) {
            # Print what the guest said before throwing. Throwing on the captured
            # output discards the only description of the failure and leaves the
            # caller reading an exit code with no diagnosis.
            $out | ForEach-Object { Write-Host "  $_" }
            throw "$Recipe on vm $env:vm failed (exit $LASTEXITCODE)"
        }
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
        if ($LASTEXITCODE -ne 0) {
            # Print what the guest said before throwing. Throwing on the captured
            # output discards the only description of the failure and leaves the
            # caller reading an exit code with no diagnosis.
            $out | ForEach-Object { Write-Host "  $_" }
            throw "$Recipe on vm $env:vm failed (exit $LASTEXITCODE)"
        }
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

# Can trust come from the PER-USER inclusion list alone, with nothing in any
# machine store?
#
# Office has a third trust path beside TrustedPublisher and a validating chain:
# HKCU\Software\Microsoft\VSTO\Security\Inclusion. Windows writes an entry there
# when a user accepts a trust prompt. Each entry is a GUID-named key holding two
# REG_SZ values -- Url, the deployment manifest with forward slashes and no
# |vstolocal suffix, and PublicKey, RSA.ToXmlString($false) of the signer's
# public key. Both are derivable from the shipping manifest, so the entry can be
# written instead of prompted for.
#
# If it earns trust, publisher trust needs no machine store write at all: no
# TrustedPublisher, and above all no self-signed certificate in Root. That is
# the zero-cost alternative to a purchased signing certificate.
#
# The URL spelling of a path containing spaces is the open variable -- the
# entries Windows wrote here were for space-free paths, and the deployed path is
# C:\Program Files\4pp\Outlook File Drag. Both spellings are tried.
#
# Same two transports and the same restore-in-finally as lab-store-matrix.
[doc('Can HKCU alone earn trust, with no machine store? (lab VM)')]
[group('verify')]
[confirm("Temporarily remove the publisher certificate from BOTH machine stores on that machine and seed a per-user trust entry, restoring both after. Lab machines only. Continue?")]
[no-exit-message]
[windows]
[script]
lab-inclusion $vm=LAB_VM: (lab-push vm)
    $ErrorActionPreference = 'Stop'
    $jf = "$env:MO_REPO/justfile"
    function Invoke-Guest([string] $Recipe, [string] $Ps) {
        $out = $Ps | & just --justfile $jf --working-directory $env:MO_REPO lab $Recipe $env:vm
        if ($LASTEXITCODE -ne 0) {
            # Print what the guest said before throwing. Throwing on the captured
            # output discards the only description of the failure and leaves the
            # caller reading an exit code with no diagnosis.
            $out | ForEach-Object { Write-Host "  $_" }
            throw "$Recipe on vm $env:vm failed (exit $LASTEXITCODE)"
        }
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

    # Built in the guest from the guest's own registration, so the Url compared
    # against is the one Office resolves, not one assembled on this workstation.
    function Get-SeedPayload([string] $Encoding) {
        $l = @("`$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\Outlook\Addins\OutlookFileDrag').Manifest")
        $l += "`$path = `$p.Split('|')[0].Replace('file:///', '').Replace('/', '\')"
        $l += "`$url = 'file:///' + `$path.Replace('\', '/')"
        if ($Encoding -eq 'escaped') { $l += "`$url = `$url.Replace(' ', '%20')" }
        $l += "`$doc = New-Object System.Xml.XmlDocument"
        $l += "`$doc.Load(`$path)"
        $l += "`$ns = New-Object System.Xml.XmlNamespaceManager(`$doc.NameTable)"
        $l += "`$ns.AddNamespace('ds', 'http://www.w3.org/2000/09/xmldsig#')"
        $l += "`$n = `$doc.SelectSingleNode('//ds:Signature/ds:KeyInfo/ds:X509Data/ds:X509Certificate', `$ns)"
        $l += "`$c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String(`$n.InnerText.Trim()))"
        $l += "`$rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey(`$c)"
        $l += "`$g = [Guid]::NewGuid().ToString()"
        $l += "`$k = 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion\' + `$g"
        $l += "New-Item -Path `$k -Force | Out-Null"
        $l += "New-ItemProperty -Path `$k -Name 'Url' -Value `$url -PropertyType String -Force | Out-Null"
        $l += "New-ItemProperty -Path `$k -Name 'PublicKey' -Value `$rsa.ToXmlString(`$false) -PropertyType String -Force | Out-Null"
        $l += "'SEEDED: ' + `$g"
        $l += "'  url: ' + (Get-ItemProperty `$k).Url"
        $l -join "`n"
    }
    function Get-ClearPayload([string] $Guid) {
        $l = @("`$k = 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion\$Guid'")
        $l += "if (Test-Path `$k) { Remove-Item `$k -Recurse -Force }"
        $l += "'cleared $Guid : ' + (-not (Test-Path `$k))"
        $l -join "`n"
    }
    function Get-StorePayload([string] $Verb) {
        $l = @("foreach (`$n in 'TrustedPublisher', 'Root') {")
        $l += "    `$f = `"C:\ProgramData\ofd-probe\incl-`$n.cer`""
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
    # An entry left over from an earlier prompt would grant trust on its own and
    # every arm would read 0, so the run has to start from a known-empty list.
    $pre = @(Invoke-Guest 'intune-user-ps' "@(if (Test-Path 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion') { Get-ChildItem 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion' }) | ForEach-Object { 'PRE: ' + `$_.PSChildName }" | Where-Object { $_ -like 'PRE:*' })
    if ($pre) {
        $pre | ForEach-Object { Write-Host $_ }
        throw "the inclusion list on vm $env:vm is not empty; a pre-existing entry would decide every arm"
    }
    "inclusion list     : empty"
    $results = [ordered]@{}
    $results['machine stores present'] = Invoke-Arm 'BASELINE, MACHINE STORES PRESENT'
    try {
        Write-Host ""
        Write-Host "--- removing $thumb from both machine stores (SYSTEM) ---"
        Invoke-Guest 'intune-ps' (Get-StorePayload 'remove') | ForEach-Object { Write-Host $_ }
        $results['no store, no inclusion'] = Invoke-Arm 'NO MACHINE STORE, NO INCLUSION'
        foreach ($enc in 'literal', 'escaped') {
            $guid = $null
            try {
                Write-Host ""
                Write-Host "--- seeding the per-user inclusion entry, $enc spaces ---"
                $seeded = Invoke-Guest 'intune-user-ps' (Get-SeedPayload $enc)
                $seeded | ForEach-Object { Write-Host "  $_" }
                $line = @($seeded | Where-Object { $_ -like 'SEEDED:*' })
                if (-not $line) { throw "the inclusion entry was not written on vm $env:vm" }
                $guid = $line[0].Split(':')[1].Trim()
                $results["inclusion only, $enc spaces"] = Invoke-Arm "INCLUSION ONLY, $($enc.ToUpper()) SPACES"
            } finally {
                if ($guid) { Invoke-Guest 'intune-user-ps' (Get-ClearPayload $guid) | ForEach-Object { Write-Host $_ } }
            }
        }
    } finally {
        Write-Host ""
        Write-Host "--- restoring $thumb to both machine stores (SYSTEM) ---"
        Invoke-Guest 'intune-ps' (Get-StorePayload 'restore') | ForEach-Object { Write-Host $_ }
    }
    $results['machine stores restored'] = Invoke-Arm 'MACHINE STORES RESTORED'
    ""
    "########## RESULT ##########"
    foreach ($k in $results.Keys) { "  {0,-30} VSTOInstaller exit {1}" -f $k, $results[$k] }
    ""
    if ($results.Values -contains 'none' -or $results.Values -contains '-400') {
        "INVALID: an arm produced no trust decision"
        exit 2
    }
    if ($results['machine stores present'] -ne '0' -or $results['machine stores restored'] -ne '0') {
        "INVALID: the baseline arms did not both trust; the machine changed underneath the run"
        exit 2
    }
    if ($results['no store, no inclusion'] -ne '-300') {
        "INVALID: removing the certificate did not withdraw trust, so the seeded arms control nothing"
        exit 2
    }
    $won = @($results.Keys | Where-Object { $_ -like 'inclusion only*' -and $results[$_] -eq '0' })
    if ($won) {
        "PER-USER TRUST EARNS IT ($($won -join '; ')): no machine store write is required"
        exit 0
    }
    "the seeded entry did not earn trust in either URL spelling; the machine store stays"
    exit 1

# Run the SHIPPING per-user script on a lab guest and ask the trust manager.
#
# lab-inclusion proved the mechanism with an inline seed. This proves the
# artifact: the same bytes inclusion-deploy uploads to Intune are executed in the
# guest's user session, with the certificate in neither machine store.
#
# It also runs the script twice. An Intune platform script re-runs, and a grant
# that minted a fresh GUID every cycle would fill the hive; the second pass has to
# say "already trusted" and change nothing.
[doc('Run the shipping per-user script on a lab VM and verify trust (lab VM)')]
[group('verify')]
[confirm("Temporarily remove the publisher certificate from BOTH machine stores on that machine, run the shipping per-user grant, and restore after. Lab machines only. Continue?")]
[no-exit-message]
[windows]
[script]
lab-inclusion-prod $vm=LAB_VM: inclusion-script (lab-push vm)
    $ErrorActionPreference = 'Stop'
    $jf = "$env:MO_REPO/justfile"
    $remote = 'C:\ProgramData\ofd-probe\' + [IO.Path]::GetFileName($env:INCLUSION_REMEDIATION)
    function Invoke-Guest([string] $Recipe, [string] $Ps) {
        $out = $Ps | & just --justfile $jf --working-directory $env:MO_REPO lab $Recipe $env:vm
        if ($LASTEXITCODE -ne 0) {
            # Print what the guest said before throwing. Throwing on the captured
            # output discards the only description of the failure and leaves the
            # caller reading an exit code with no diagnosis.
            $out | ForEach-Object { Write-Host "  $_" }
            throw "$Recipe on vm $env:vm failed (exit $LASTEXITCODE)"
        }
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
    $thumb = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $env:CERT_OUT).Thumbprint
    "artifact signer : $thumb"
    "shipping script : $remote"
    function Get-StorePayload([string] $Verb) {
        $l = @("foreach (`$n in 'TrustedPublisher', 'Root') {")
        $l += "    `$f = `"C:\ProgramData\ofd-probe\prod-`$n.cer`""
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
    $clear = @(
        "`$b = 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion'"
        "if (Test-Path `$b) { Get-ChildItem `$b | Remove-Item -Recurse -Force }"
        "'inclusion entries: ' + @(if (Test-Path `$b) { Get-ChildItem `$b }).Count"
    ) -join "`n"
    $count = "`$b = 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion'; 'ENTRIES: ' + @(if (Test-Path `$b) { Get-ChildItem `$b }).Count"
    function Get-Count {
        $line = @(Invoke-Guest 'intune-user-ps' $count | Where-Object { $_ -like 'ENTRIES:*' })
        if (-not $line) { return 'unknown' }
        $line[0].Split(':')[1].Trim()
    }
    Invoke-Guest 'intune-user-ps' $clear | ForEach-Object { Write-Host $_ }
    $results = [ordered]@{}
    try {
        Write-Host ""
        Write-Host "--- removing $thumb from both machine stores (SYSTEM) ---"
        Invoke-Guest 'intune-ps' (Get-StorePayload 'remove') | ForEach-Object { Write-Host $_ }
        $results['no store, no grant'] = Invoke-Arm 'NO MACHINE STORE, NO GRANT'
        # A grant for an UNRELATED add-in, planted before the passes and checked
        # after. The inclusion list is shared by every VSTO add-in on the machine,
        # so a script that rebuilt the parent key would silently revoke trust for
        # all of them. It did: `New-Item -Force` on an existing registry key
        # recreates it and drops its subkeys. This is the control for that.
        Write-Host ""
        Write-Host "--- planting a decoy grant for an unrelated add-in ---"
        $decoy = @(
            "`$b = 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion'"
            "`$k = Join-Path `$b 'decoy-0000-0000-0000-000000000000'"
            "New-Item -Path `$k -Force | Out-Null"
            "New-ItemProperty -Path `$k -Name 'Url' -Value 'file:///C:/Decoy/Other.vsto' -PropertyType String -Force | Out-Null"
            "New-ItemProperty -Path `$k -Name 'PublicKey' -Value 'decoy' -PropertyType String -Force | Out-Null"
            "'planted decoy'"
        ) -join "`n"
        $decoyCheck = "`$k = 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion\decoy-0000-0000-0000-000000000000'; 'DECOY: ' + (Test-Path `$k)"
        $profileAudit = @(
            "`$pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'"
            "`$service = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')"
            "foreach (`$k in @(Get-ChildItem `$pl)) {"
            "    if (`$service -contains `$k.PSChildName) { continue }"
            "    `$img = (Get-ItemProperty `$k.PSPath).ProfileImagePath"
            "    if (-not `$img) { continue }"
            "    `$dat = Join-Path `$img 'NTUSER.DAT'"
            "    if (-not (Test-Path `$dat)) { continue }"
            "    `$hive = `$k.PSChildName"
            "    `$tmp = `$null"
            "    if (-not (Test-Path `"Registry::HKEY_USERS\`$hive`")) {"
            "        `$tmp = 'AUD-' + `$k.PSChildName"
            "        & reg.exe load `"HKU\`$tmp`" `"`$dat`" 2>&1 | Out-Null"
            "        if (`$LASTEXITCODE -ne 0) { `"PROFILE: `$img : busy`"; continue }"
            "        `$hive = `$tmp"
            "    }"
            "    try {"
            # .NET keys with explicit disposal, never the PowerShell provider:
            # the provider holds its handles open and `reg unload` then fails
            # with Access denied, leaving the hive mounted and that user unable
            # to sign in.
            "        `$urls = @()"
            "        `$b = `$null"
            "        try {"
            "            `$b = [Microsoft.Win32.Registry]::Users.OpenSubKey(`"`$hive\Software\Microsoft\VSTO\Security\Inclusion`", `$false)"
            "            if (`$b) {"
            "                foreach (`$n in @(`$b.GetSubKeyNames())) {"
            "                    `$s = `$null"
            "                    try { `$s = `$b.OpenSubKey(`$n, `$false); if (`$s) { `$urls += `$s.GetValue('Url') } }"
            "                    finally { if (`$s) { `$s.Dispose() } }"
            "                }"
            "            }"
            "        } finally { if (`$b) { `$b.Dispose() } }"
            "        `$ofd = @(`$urls | Where-Object { `$_ -like '*OutlookFileDrag.vsto' })"
            "        if (`$ofd) { `"PROFILE: `$img : `$(`$ofd[0])`" } else { `"PROFILE: `$img : none`" }"
            "    } finally {"
            "        if (`$tmp) {"
            "            `$uu = & reg.exe unload `"HKU\`$tmp`" 2>&1"
            "            if (`$LASTEXITCODE -ne 0) { `"PROFILE: `$img : LEFT MOUNTED (`$uu)`" }"
            "        }"
            "    }"
            "}"
        ) -join "`n"
        Invoke-Guest 'intune-user-ps' $decoy | ForEach-Object { Write-Host "  $_" }
        # The two passes run back to back, with no probe between them. The probe
        # is not passive: it installs with VSTOInstaller and uninstalls to clean
        # up after itself, and that uninstall DELETES the inclusion entry. Probing
        # between the passes made pass 2 re-grant from an empty hive and read as
        # non-idempotent when it was not.
        Write-Host ""
        # SYSTEM, exactly as Intune runs it -- not the interactive session. That
        # is the whole point of the script: it reaches profiles nobody is signed
        # in to, so the rollout converges on devices sitting at a lock screen.
        Write-Host "--- running the shipping script as SYSTEM, pass 1 ---"
        $p1 = Invoke-Guest 'intune-ps' "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$remote'"
        $p1 | ForEach-Object { Write-Host "  $_" }
        $n1 = Get-Count
        Write-Host ""
        Write-Host "--- running the shipping script as SYSTEM, pass 2 (idempotence) ---"
        $p2 = Invoke-Guest 'intune-ps' "& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$remote'"
        $p2 | ForEach-Object { Write-Host "  $_" }
        $n2 = Get-Count
        $granted = ($p1 -join ' ') -like '*granted*'
        $idem = -not (($p2 -join ' ') -like '*granted (*')
        $survived = @(Invoke-Guest 'intune-user-ps' $decoyCheck | Where-Object { $_ -like 'DECOY:*' })
        $decoyLives = $survived -and $survived[0].Split(':')[1].Trim() -eq 'True'
        # The lab users are the point of the exercise: nobody is signed in as them
        # and their hives are files on disk. Read those files back and show the
        # grant landed in the profile of a person who never touched the machine.
        Write-Host ""
        Write-Host "--- auditing every profile hive, including the signed-out lab users ---"
        $audit = @(Invoke-Guest 'intune-ps' $profileAudit | Where-Object { $_ -like 'PROFILE:*' })
        $audit | ForEach-Object { Write-Host "  $_" }
        $granted_profiles = @($audit | Where-Object { $_ -notlike '*: none' })
        $results['after two passes'] = Invoke-Arm 'AFTER TWO PASSES OF THE SHIPPING SCRIPT'
        # Measure what the probe leaves behind rather than inferring it. The
        # script re-runs on its own IME cycle and repairs this, but the window is
        # real and belongs in the docs.
        $n3 = Get-Count
        ""
        "pass 1 granted              : $granted"
        "pass 2 changed nothing      : $idem"
        "entries in the live hive    : $n1 then $n2 (the decoy is one of them)"
        "unrelated grant survived    : $decoyLives"
        "profiles holding the grant  : $($granted_profiles.Count) of $($audit.Count)"
        "entries after the probe     : $n3"
    } finally {
        Write-Host ""
        Write-Host "--- restoring $thumb and clearing the seeded grant ---"
        Invoke-Guest 'intune-ps' (Get-StorePayload 'restore') | ForEach-Object { Write-Host $_ }
        Invoke-Guest 'intune-user-ps' $clear | ForEach-Object { Write-Host $_ }
    }
    $results['machine stores restored'] = Invoke-Arm 'MACHINE STORES RESTORED'
    ""
    "########## RESULT ##########"
    foreach ($k in $results.Keys) { "  {0,-28} VSTOInstaller exit {1}" -f $k, $results[$k] }
    ""
    if ($results.Values -contains 'none' -or $results.Values -contains '-400') {
        "INVALID: an arm produced no trust decision"
        exit 2
    }
    if ($results['no store, no grant'] -ne '-300') {
        "INVALID: trust survived removing the certificate, so the grant controls nothing"
        exit 2
    }
    if ($results['machine stores restored'] -ne '0') {
        "INVALID: the machine did not come back to its starting state"
        exit 2
    }
    if ($results['after two passes'] -ne '0') {
        "FAIL: the shipping script did not earn trust from HKCU alone"
        exit 1
    }
    if (-not $granted -or -not $idem -or $n1 -ne '2' -or $n2 -ne '2') {
        "FAIL: not idempotent -- granted=$granted, second pass inert=$idem, entries $n1 then $n2"
        exit 1
    }
    if (-not $decoyLives) {
        "FAIL: the grant destroyed an unrelated add-in's trust entry"
        exit 1
    }
    # A grant that only ever reaches the signed-in profile cannot retire the
    # machine stores, because most devices have nobody signed in when the script
    # runs. Every profile hive on the machine must hold it.
    if (-not $audit -or $granted_profiles.Count -ne $audit.Count) {
        "FAIL: $($audit.Count - $granted_profiles.Count) profile(s) did not receive the grant"
        exit 1
    }
    "PASS: the shipping script earns trust with no machine store, is idempotent,"
    "      leaves other add-ins' grants alone, and reaches every profile on the"
    "      machine including users who are not signed in"
    "note: VSTOInstaller /Uninstall removes the entry ($n3 left after the probe);"
    "      the user-context script re-grants on its next cycle"

# Put a lab guest back the way the control recipes found it.
#
# The control recipes restore in a `finally`, but a killed process runs no
# finally: an interrupted run leaves the machine with no publisher certificate in
# either store. This is idempotent and safe to run at any time.
[doc('Restore a lab VM after an interrupted control run: lab-restore 304')]
[group('verify')]
[no-exit-message]
[windows]
[script]
lab-restore $vm=LAB_VM: cert-export
    $ErrorActionPreference = 'Stop'
    $jf = "$env:MO_REPO/justfile"
    $cer = [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:CERT_OUT))
    $lines = @(
        "`$raw = [Convert]::FromBase64String('$cer')"
        "`$c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,`$raw)"
        "foreach (`$n in 'TrustedPublisher', 'Root') {"
        "    `$s = New-Object Security.Cryptography.X509Certificates.X509Store `$n, 'LocalMachine'"
        "    `$s.Open('ReadWrite')"
        "    if (-not `$s.Certificates.Find('FindByThumbprint', `$c.Thumbprint, `$false).Count) { `$s.Add(`$c) }"
        "    `"LocalMachine\`$n holds `$(`$c.Thumbprint) : `" + (`$s.Certificates.Find('FindByThumbprint', `$c.Thumbprint, `$false).Count -gt 0)"
        "    `$s.Close()"
        "}"
        "Get-ChildItem 'C:\ProgramData\ofd-probe' -Filter '*.cer' -ErrorAction SilentlyContinue | Remove-Item -Force"
        # A hive left mounted by an interrupted grant or audit BLOCKS THAT USER'S
        # SIGN-IN, so it is the most damaging thing a failed run can leave behind.
        # Both prefixes are ours; nothing else on the machine mounts under them.
        "foreach (`$h in @(Get-ChildItem 'Registry::HKEY_USERS' | Where-Object { `$_.PSChildName -like 'OFD-*' -or `$_.PSChildName -like 'AUD-*' })) {"
        "    `$n = `$h.PSChildName"
        "    `$h.Dispose()"
        "    `$o = & reg.exe unload `"HKU\`$n`" 2>&1"
        "    `"unmounted `$n : `$(`$LASTEXITCODE -eq 0) `$o`""
        "}"
    )
    ($lines -join "`n") | & just --justfile $jf --working-directory $env:MO_REPO lab intune-ps $env:vm
    if ($LASTEXITCODE -ne 0) { throw "restore on vm $env:vm failed (exit $LASTEXITCODE)" }
    $clear = @(
        "`$b = 'HKCU:\Software\Microsoft\VSTO\Security\Inclusion'"
        "if (Test-Path `$b) { Get-ChildItem `$b | Remove-Item -Recurse -Force }"
        "'inclusion entries: ' + @(if (Test-Path `$b) { Get-ChildItem `$b }).Count"
    )
    ($clear -join "`n") | & just --justfile $jf --working-directory $env:MO_REPO lab intune-user-ps $env:vm
    if ($LASTEXITCODE -ne 0) { throw "clearing the inclusion list on vm $env:vm failed (exit $LASTEXITCODE)" }
