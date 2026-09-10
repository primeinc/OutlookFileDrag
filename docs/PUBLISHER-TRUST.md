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

## Signing: what exists and what it does not solve

The tenant has Azure Trusted Signing, identity validated:

```
cs-wc-prod    3e4d24be…/rg-wc-prod    Basic  eastus
cs-x1xp-dev   e4eb7658…/rg-x1xp-dev   Basic  eastus
cp-wc-prod    Active, identityValidationId a8b984e7-08bf-4f49-8f3c-e73c845107e6
              CN=titlesolutionsllc.com, O=titlesolutionsllc.com, OU=IT
              profileType: PrivateTrust, certificates rotate ~3 days
```

Neither account removes the need to deploy something to every machine:

- The profile is **PrivateTrust**, whose root is not in the Windows root program.
  A `PublicTrust` profile chains publicly and the existing identity validation
  covers creating one.
- Even a publicly-chaining certificate still needs the TrustedPublisher
  deployment. That is exactly what the `without TrustedPublisher` arm measures.
- Trusted Signing signs what SignTool signs. ClickOnce manifests (`.vsto`,
  `.manifest`) are XML-DSIG signed by `mage.exe` /
  `System.Deployment.Internal.CodeSigning`, which is not a SignTool format, and
  the supported integrations are SignTool, GitHub Actions, Azure DevOps tasks,
  PowerShell for Authenticode, Az CI policy, the SDK and a .NET crypto provider —
  no mage. The service never releases the certificate, so mage cannot borrow it.
  - learn.microsoft.com/azure/artifact-signing/faq — "You can sign all file types
    that SignTool supports"; "The Authenticode certificate that's used for signing
    with the profile is never given to you."
  - learn.microsoft.com/azure/artifact-signing/how-to-signing-integrations

The shipping MSI is `NotSigned`. Trusted Signing can sign it with the account
that already exists, which is worth doing on its own account — it just has no
bearing on whether Office loads the add-in.

### The manifest signing key must be pinned to release

ClickOnce trust is keyed on the manifest URL **and** the public key, so the key
that signs a release decides whether the grants already on the fleet cover it.

`just build` signs with `SIGNING_PFX` (+ `SIGNING_PFX_PASSWORD`) or
`SIGNING_THUMBPRINT` when either is set. With neither it mints or reuses
`CN=OutlookFileDrag (Build)` in `CurrentUser\My` — a different publisher on every
build machine — and prints `MACHINE-LOCAL KEY -- development build` naming the
consequence. v1.0.13 was signed that way by a GitHub Actions runner, so its
private key is gone and nothing can re-sign as that publisher.

A release signed with a key other than `20ED4E09B4D4775A571B70514442C8752EE672E4`
revokes every inclusion-list grant on the fleet until the grant script, which
carries the certificate, is redeployed and every device runs it again.
`trust-audit` is the check: it compares the certificate inside the uploaded
script with the one inside the shipping MSI.

Where the durable key lives is still open. It needs to outlive any one build
machine — Key Vault in `4PP Production Core` is the obvious home.

`trust-script` decides the machine-store branch from the certificate: a signer
whose Subject equals its Issuer is self-signed and gets TrustedPublisher + Root,
anything CA-issued gets TrustedPublisher only. Both branches are controlled — the
shipping certificate renders `'TrustedPublisher','Root'`, a locally minted
CA-issued leaf renders `'TrustedPublisher'`.

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
