# Publisher trust for the VSTO manifests

## What Office requires

Office runs every `vstolocal` add-in through the ClickOnce trust manager. There
are two independent ways to satisfy it, and either one alone is enough.

**Machine stores.** Measured on lab VM 304 with `just deploy::lab-store-matrix`,
one store changed per arm, VSTOInstaller as the oracle:

| arm | chain builds | in TrustedPublisher | VSTOInstaller |
| --- | --- | --- | --- |
| both stores present | yes | yes | `0` |
| without Root | no, `UntrustedRoot` | yes | `-300` |
| without TrustedPublisher | yes | no | `-300` |
| neither | no | no | `-300` |

Within that path both conditions are necessary and neither is sufficient. Root
is required only because the signer is self-signed, so it is its own chain root.

**The per-user inclusion list.** `HKCU\Software\Microsoft\VSTO\Security\Inclusion`
holds GUID-named keys with two REG_SZ values: `Url`, the deployment manifest with
forward slashes and no `|vstolocal` suffix, and `PublicKey`, the signer's
`RSA.ToXmlString($false)`. Measured with `just deploy::lab-inclusion`:

| arm | VSTOInstaller |
| --- | --- |
| machine stores present | `0` |
| no store, no inclusion | `-300` |
| inclusion only, literal spaces | `0` |
| inclusion only, escaped spaces | `0` |

One HKCU entry earns trust with the certificate in **neither** machine store and
a chain that does not build. Both URL spellings work; VSTO normalises them.

The grant is the narrowest the platform offers — one manifest URL bound to one
public key. Changing the install directory or the signing certificate revokes it.

## Why the fleet needed anything at all

The MSI installs no certificate: there is no certificate custom action in the
installer sources. No `PromptingLevel` policy is set, so VSTO's default applies
and a manifest whose chain does not validate produces no trust prompt — nothing
a user could have accepted. And the fleet's own remediation output shows the
certificate was absent everywhere: of the first 11 devices to run
`Install-PublisherTrust.ps1`, 10 reported `added … to LocalMachine\TrustedPublisher`.
The only pre-existing certificates found were `59CD6867…`, a build key from a
workstation, on two machines.

So a manual install laid the files down and Office declined to load the add-in,
logging VSTO event 4096 and showing the user nothing.

## What ships

Two Intune platform scripts, both gated on the certificate inside the shipping
artifact matching the certificate inside the uploaded script.

```
Install-PublisherTrust.ps1        SYSTEM, All Devices
    writes the signer to LocalMachine\TrustedPublisher and \Root

Install-PublisherInclusion.ps1    SYSTEM, All Devices
    writes one inclusion entry into every profile hive on the machine, plus
    C:\Users\Default\NTUSER.DAT so profiles created later inherit it;
    touches no machine store
```

The second replaces the first. `just deploy::retire-deploy` publishes
`Remove-PublisherTrust.ps1`, which takes the certificate back out of both machine
stores — and refuses to run until every device carrying the certificate has a
successful grant, so the fleet is never between the two models.

**Why SYSTEM and not user context.** The grant lives in a user hive, so a
user-context script assigned to All Users is the obvious mapping. It was shipped
that way first and it could not converge: user-context scripts run only in a
signed-in session, so on a fleet where most devices have nobody signed in the
ledger stays at `run states : 0` and the retire gate never opens. SYSTEM reaches
every hive — loaded ones under `HKEY_USERS\<sid>`, the rest mounted from
`NTUSER.DAT` — on the same cycle as the script it replaces. Service SIDs
(`S-1-5-18/19/20`) are skipped; they have hives and never run Outlook.

### Four things the grant had to be shown not to do

`New-Item -Force` on an **existing** registry key recreates it and drops its
subkeys. The inclusion list is shared by every VSTO add-in for that user, so the
reflex `New-Item -Path $base -Force` would have revoked every other add-in's
trust on every cycle. The script uses `RegistryKey.CreateSubKey`, which creates
missing parents and leaves existing children alone, and `lab-inclusion-prod`
plants a decoy grant for an unrelated URL and fails if it does not survive.

The PowerShell registry **provider** holds key handles open, and `reg unload`
then fails with `Access is denied` — four of seven hives on the first run, with
`[gc]::Collect()` making no difference. A fresh SYSTEM process unloaded them
instantly, which is what identified handles rather than permissions. Every key
is a `[Microsoft.Win32.Registry]` handle disposed in its own `finally`. **A hive
left mounted blocks that user's sign-in**, so `lab-restore` unmounts any
`HKU\OFD-*` or `HKU\AUD-*` an interrupted run left behind.

`reg.exe` writes diagnostics to stderr, and under `ErrorActionPreference = Stop`
a redirected native stderr line is a *terminating* error — the script died on the
first `ERROR: Access is denied.` before it could read `$LASTEXITCODE` and name
the hive. Native calls go through `Invoke-Reg`, which returns the code and text.

`VSTOInstaller /Uninstall` deletes the inclusion entry. The probe runs one to
clean up after itself, so the two idempotence passes run back to back with no
probe between them. In production the same is true of anything that uninstalls
the customization in a user session; the script re-grants on its next cycle.

## Signing

From 1.0.14 a release is signed by Azure Artifact Signing:

```
account   cs-wc-prod (rg-wc-prod, eastus), endpoint https://eus.codesigning.azure.net/
profile   cp-public-trust, PublicTrust, identity validation c6275452-001e-4759-b696-b91f231cd27f
subject   CN=Title Solutions Agency LLC, O=Title Solutions Agency LLC, L=Plymouth, S=Michigan, C=US
chain     Microsoft ID Verified CS EOC CA 03 -> Microsoft ID Verified Code Signing PCA 2021
          -> Microsoft Identity Verification Root Certificate Authority 2020
signer    the Azure CLI login holding "Artifact Signing Certificate Profile Signer" on the profile
```

`just release-signed` signs `OutlookFileDrag.dll`, both ClickOnce manifests and both
MSIs with it, then expands each MSI and checks the payload: valid signatures of that
subject, one certificate across assembly and manifests, a timestamp on each, every
manifest hash equal to the file that ships, and the file version this commit builds.

The manifests are signed by `dotnet/sign` (`sign code artifact-signing`, pinned in
`.config/dotnet-tools.json`). It runs `mage -update` and writes the XML-DSIG
signature with the service's key, so nothing needs the certificate in a local
store. Its file list has to name the deployment manifest by extension
(`**/*.vsto`): the tool works on a copy under a temporary name and signs only what
the list matches. A list of `**/OutlookFileDrag.*` signs the application manifest
and leaves the deployment manifest carrying the build-machine signature.

The service keeps the private key and issues a new certificate every day, valid 72
hours. So each release is signed by a different certificate under one subject, and
trust that names a certificate or a public key belongs to one release.

### What the trust manager does with that signature

Measured on lab VM 303, VSTOInstaller as the oracle, run as a standard user through
a batch-logon scheduled task, signer `0E0733B4477BA6B27C5AE349C698D22496356C49`
(notAfter 2026-10-10 17:24Z). The second column is the same machine with its clock
set to 2026-10-13 and time sync off:

| arm | certificate valid | three days past expiry |
| --- | --- | --- |
| nothing deployed | `-300` | `-300` |
| leaf in `LocalMachine\TrustedPublisher` only | `0` | `0` |
| per-profile inclusion entry only | `0` | `0` |

A signer that chains publicly still needs one of the two grants. It needs no Root
deployment. The timestamp carries either grant past the certificate's expiry.

### How a release's trust reaches the fleet

The Intune app (az-skills `fleet-grade/win32/outlook-file-drag`) installs the MSI
as SYSTEM and then adds the certificate that signed the installed deployment
manifest to `LocalMachine\TrustedPublisher`. It first requires a valid Authenticode
signature of Title Solutions Agency LLC on the MSI and the same subject and issuer
on the manifest signer. Trust arrives with the files, on the same run, and covers
every profile on the machine.

`Install-PublisherTrust.ps1` and `Install-PublisherInclusion.ps1` above carry the
1.0.13 signer `20ED4E09B4D4775A571B70514442C8752EE672E4`, a key minted on a GitHub
Actions runner that no longer exists. A device needs them only while it still runs
1.0.13. Both generators take any MSI (`MSI_SOURCE`); `trust-script` writes
TrustedPublisher alone for a CA-issued signer and removes only self-signed
certificates of the same subject, so it never takes away the certificate of a
release a device still runs.

## Graph auth

Every recipe that talks to Intune depends on `graph-login`, which signs in as the
`wbp-az-skills` service principal with a certificate, into an az profile the
module owns (`AZURE_CONFIG_DIR`, default `~/.azure-outlookfiledrag`). It is
idempotent and re-authenticates from the certificate, so no recipe rides a cached
token or the interactive session.

```
GRAPH_APP_ID   ff0c2765-abf1-4df5-aded-655fccffac3a
GRAPH_CERT     ~/.wbp/wbp-az-skills.pem      cert + private key, PEM
GRAPH_TENANT   cffbf047-c1e9-4778-a916-93e4e5274641
```

The principal holds `DeviceManagementScripts.ReadWrite.All`,
`DeviceManagementConfiguration.ReadWrite.All` and
`DeviceManagementManagedDevices.ReadWrite.All` as admin-consented application
permissions. A signed-in user cannot substitute: the Azure CLI's own app is
pre-authorized on Microsoft Graph for a fixed scope set containing no
DeviceManagement scope, and Intune answers
`Forbidden … must have one of the following scopes`.

## Verifying

```
just deploy::trust-audit               the deployed script carries the shipping artifact's key
just deploy::trust-status              every Windows device resolves to one state
just deploy::trust-status 7 "OutlookFileDrag publisher trust (per-profile)"
                                       the same ledger for the per-profile grant
just deploy::verify-local              will Office load it on this machine, and why
just deploy::lab-verify 304            the same, in a lab guest's interactive session
just deploy::lab-control 304           the answer tracks the certificate and nothing else
just deploy::lab-store-matrix 304      which store earns the trust
just deploy::lab-inclusion 304         can HKCU alone earn it, with no machine store
just deploy::lab-inclusion-prod 304    the SHIPPING grant script, end to end
just deploy::lab-restore 304           put a lab guest back after an interrupted run
```

`VSTOInstaller.exe` is the oracle throughout: it runs the same trust manager
Office runs. It accepts only `/Install`, `/Uninstall` and `/Silent`. `0` is
trusted and `-300` is a security exception; `-101` is a bad argument and `-400`
is a missing ClickOnce user store (a context with no loaded profile, such as
`qm guest exec` as SYSTEM). Neither of the last two is a trust decision.
