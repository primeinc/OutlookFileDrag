# Publisher trust for the VSTO manifests

## What Office requires

Office runs every `vstolocal` add-in through the ClickOnce trust manager. Two
conditions, measured on lab VM 304 with `just deploy::lab-store-matrix`, one
store changed per arm, VSTOInstaller as the oracle:

| arm | chain builds | in TrustedPublisher | VSTOInstaller |
| --- | --- | --- | --- |
| both stores present | yes | yes | `0` |
| without Root | no, `UntrustedRoot` | yes | `-300` |
| without TrustedPublisher | yes | no | `-300` |
| neither | no | no | `-300` |

Both are necessary; neither is sufficient. A validating chain does not earn
silent trust, and TrustedPublisher membership does not survive a chain that does
not validate.

The third path is the per-user inclusion list
(`HKCU\Software\Microsoft\VSTO\Security\Inclusion`), written when a user accepts
the trust prompt. It is keyed on the manifest URL **and** the public key
together, so changing the install directory or the signing certificate revokes
every decision already stored. A silent MDM install never shows a prompt and can
never create one.

## Why the current model deploys two certificates' worth of trust

The manifests are signed by a self-signed certificate, which is its own chain
root. That is the only reason `Install-PublisherTrust.ps1` writes to
LocalMachine\Root: without it, condition 2 fails. The Root entry is not what
grants publisher trust — the matrix above separates them.

A self-signed root in the machine Root store is standing authority to mint trust
for anything signed by that key, on every device that holds it.

## What would remove the Root deployment

A certificate whose issuer is already in the Windows root program. Condition 2
is then satisfied by the platform, and only the TrustedPublisher entry has to be
deployed — the same Intune script, minus the Root half.

The TrustedPublisher deployment does **not** go away. That is what the
`without TrustedPublisher` arm measures: a publicly-chaining certificate that is
not a trusted publisher still returns `-300` under a silent install.

## Azure Artifact Signing (formerly Trusted Signing) does not fit

It signs what SignTool signs. ClickOnce application and deployment manifests
(`.vsto`, `.manifest`) are XML-DSIG signed by `mage.exe` /
`System.Deployment.Internal.CodeSigning`, which is not a SignTool format, and the
supported integrations are SignTool, GitHub Actions, Azure DevOps tasks,
PowerShell for Authenticode, Az CI policy, the SDK and a .NET crypto provider —
no mage. The service never releases the certificate, so mage cannot borrow it
either.

- learn.microsoft.com/azure/artifact-signing/faq — "You can sign all file types
  that SignTool supports"; "The Authenticode certificate that's used for signing
  with the profile is never given to you."
- learn.microsoft.com/azure/artifact-signing/how-to-signing-integrations

It can sign the MSI. The MSI signature is not what the trust manager reads.

## The decision, and what it costs

Buying an OV code-signing certificate from a public CA is the only option that
removes the Root deployment. It needs organisation validation, annual renewal,
and — per CA/Browser Forum requirements since 2023 — a FIPS 140-2 Level 2 token
or cloud HSM, which the build has to reach at signing time. A signing service
that exposes a CSP/KSP (for example DigiCert KeyLocker) can back `mage`; one that
exposes only a SignTool dlib cannot.

`trust-script` already decides this from the certificate: a signer whose Subject
equals its Issuer is self-signed and gets TrustedPublisher + Root, and anything
CA-issued gets TrustedPublisher only. Both branches are controlled — the shipping
certificate renders `'TrustedPublisher','Root'`, a locally minted CA-issued leaf
renders `'TrustedPublisher'`. So the migration is: buy the certificate, sign with
it, re-run `trust-deploy`. The Root deployment stops on its own.

Until that is bought and wired in, the self-signed model is what ships, and
`deploy::trust-deploy` is how it reaches devices.

## Verifying

```
just deploy::trust-audit          the deployed script carries the shipping artifact's key
just deploy::trust-status         every Windows device resolves to one state
just deploy::verify-local         will Office load it on this machine, and why
just deploy::lab-verify 304       the same, in a lab guest's interactive session
just deploy::lab-control 304      the answer tracks the certificate and nothing else
just deploy::lab-store-matrix 304 which store earns the trust
```

`VSTOInstaller.exe` is the oracle throughout: it runs the same trust manager
Office runs. It accepts only `/Install`, `/Uninstall` and `/Silent`. `0` is
trusted and `-300` is a security exception; `-101` is a bad argument and `-400`
is a missing ClickOnce user store (a context with no loaded profile, such as
`qm guest exec` as SYSTEM). Neither of the last two is a trust decision.
