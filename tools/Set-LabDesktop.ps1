# Gives a lab VM an interactive desktop: Windows signs a local standard user in at boot.
# Runs as SYSTEM in the guest (deploy.just: lab-desktop, lab-desktop-end). Lab machines only.
#
#   Start    make the account, store its password, set Winlogon to sign it in. Restart after.
#   Restore  put Winlogon back as Start found it and delete the stored password. Restart after.
#   Remove   delete the account and its profile. Refuses while the account is signed in.
#   State    print who is at the console.
#
# The password is made here, set on the account and stored as the LSA secret Winlogon reads
# (DefaultPassword). It reaches no file, no registry value and no output.
param(
    [Parameter(Mandatory)] [ValidateSet('Start', 'Restore', 'Remove', 'State')] [string] $Mode,
    [string] $User = 'ofdflow'
)
$ErrorActionPreference = 'Stop'
$state = 'C:\ProgramData\ofd-probe\desktop.before.json'
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$oobe = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class OfdLsa {
    [StructLayout(LayoutKind.Sequential)]
    struct LsaString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct ObjectAttributes { public int Length; public IntPtr Root; public IntPtr Name; public uint Attributes; public IntPtr Security; public IntPtr Qos; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref ObjectAttributes attributes, uint access, out IntPtr policy);
    [DllImport("advapi32.dll", EntryPoint = "LsaStorePrivateData")] static extern uint Store(IntPtr policy, ref LsaString key, ref LsaString data);
    [DllImport("advapi32.dll", EntryPoint = "LsaStorePrivateData")] static extern uint Clear(IntPtr policy, ref LsaString key, IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    static LsaString Make(string s) {
        LsaString u = new LsaString();
        u.Buffer = Marshal.StringToHGlobalUni(s);
        u.Length = (ushort)(s.Length * 2);
        u.MaximumLength = (ushort)(s.Length * 2 + 2);
        return u;
    }
    // value null deletes the secret; a secret that is not there is not an error.
    public static void Set(string key, string value) {
        ObjectAttributes oa = new ObjectAttributes();
        oa.Length = Marshal.SizeOf(typeof(ObjectAttributes));
        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref oa, 0x20, out policy);
        if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        LsaString k = Make(key);
        try {
            if (value == null) {
                status = Clear(policy, ref k, IntPtr.Zero);
                if (status != 0 && LsaNtStatusToWinError(status) != 2) throw new Win32Exception(LsaNtStatusToWinError(status));
            } else {
                LsaString v = Make(value);
                try { status = Store(policy, ref k, ref v); } finally { Marshal.ZeroFreeGlobalAllocUnicode(v.Buffer); }
                if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
            }
        } finally { Marshal.FreeHGlobal(k.Buffer); LsaClose(policy); }
    }
}
'@

function Set-OrRemove([string] $Key, [string] $Name, $Value, [string] $Type) {
    if ($null -eq $Value) { Remove-ItemProperty -Path $Key -Name $Name -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $Key -Name $Name -Value $Value -Type $Type }
}

function Read-Value([string] $Key, [string] $Name) {
    if (Test-Path $Key) { (Get-ItemProperty $Key).$Name }
}

function Write-State {
    $console = (Get-CimInstance Win32_ComputerSystem).UserName
    $w = Get-ItemProperty $winlogon
    "DESKTOP console='$console' AutoAdminLogon=$($w.AutoAdminLogon) DefaultUserName=$($w.DefaultUserName) DefaultDomainName=$($w.DefaultDomainName)"
}

switch ($Mode) {
    'State' { Write-State }

    'Start' {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $state) | Out-Null
        # What Start found, kept once per setting: a second Start records only what the first did not.
        $before = [ordered]@{}
        if (Test-Path -LiteralPath $state) {
            foreach ($p in (Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).PSObject.Properties) { $before[$p.Name] = $p.Value }
        }
        $w = Get-ItemProperty $winlogon
        $found = [ordered]@{
            AutoAdminLogon           = $w.AutoAdminLogon
            DefaultUserName          = $w.DefaultUserName
            DefaultDomainName        = $w.DefaultDomainName
            DisablePrivacyExperience = (Read-Value $oobe 'DisablePrivacyExperience')
            OobeKeyPresent           = (Test-Path $oobe)
        }
        foreach ($name in $found.Keys) { if (-not $before.Contains($name)) { $before[$name] = $found[$name] } }
        $before | ConvertTo-Json | Set-Content -LiteralPath $state -Encoding UTF8

        $raw = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($raw)
        $plain = 'Aa1!' + [Convert]::ToBase64String($raw)
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
        if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
            Set-LocalUser -Name $User -Password $secure
        } else {
            New-LocalUser -Name $User -Password $secure -PasswordNeverExpires -UserMayNotChangePassword `
                -Description 'Outlook File Drag flow test (lab)' | Out-Null
        }
        Enable-LocalUser -Name $User
        try { Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $User }
        catch [Microsoft.PowerShell.Commands.MemberExistsException] { }

        [OfdLsa]::Set('DefaultPassword', $plain)
        Set-ItemProperty $winlogon AutoAdminLogon '1' -Type String
        Set-ItemProperty $winlogon DefaultUserName $User -Type String
        Set-ItemProperty $winlogon DefaultDomainName $env:COMPUTERNAME -Type String
        Remove-ItemProperty $winlogon DefaultPassword -ErrorAction SilentlyContinue
        Remove-ItemProperty $winlogon AutoLogonCount -ErrorAction SilentlyContinue
        # A first sign-in otherwise stops on the privacy-settings pages, which nobody is there to answer.
        New-Item $oobe -Force | Out-Null
        Set-ItemProperty $oobe DisablePrivacyExperience 1 -Type DWord

        $legal = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
        "legal notice: caption='$($legal.legalnoticecaption)' text length=$("$($legal.legalnoticetext)".Length)"
        Write-State
    }

    'Restore' {
        if (Test-Path -LiteralPath $state) {
            $before = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
            Set-OrRemove $winlogon 'AutoAdminLogon' $before.AutoAdminLogon 'String'
            Set-OrRemove $winlogon 'DefaultUserName' $before.DefaultUserName 'String'
            Set-OrRemove $winlogon 'DefaultDomainName' $before.DefaultDomainName 'String'
            if ($before.OobeKeyPresent) { Set-OrRemove $oobe 'DisablePrivacyExperience' $before.DisablePrivacyExperience 'DWord' }
            elseif (Test-Path $oobe) { Remove-Item $oobe -Recurse -Force }
            Remove-Item -LiteralPath $state -Force
        } else {
            Set-ItemProperty $winlogon AutoAdminLogon '0' -Type String
        }
        [OfdLsa]::Set('DefaultPassword', $null)
        Write-State
    }

    'Remove' {
        $account = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
        if (-not $account) { "no account $User"; Write-State; exit 0 }
        $sid = $account.SID.Value
        if (Test-Path "Registry::HKEY_USERS\$sid") {
            "$User is signed in or its profile is still loaded; restart the machine after Restore, then run Remove"
            exit 1
        }
        $userProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'"
        if ($userProfile) { Remove-CimInstance -InputObject $userProfile; "removed profile $($userProfile.LocalPath)" }
        Remove-LocalUser -Name $User
        "removed account $User"
        Write-State
    }
}
