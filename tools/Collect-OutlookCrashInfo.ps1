<#
.SYNOPSIS
    Collects Outlook crash evidence and (optionally) arms WER full crash dumps for OUTLOOK.EXE.

.DESCRIPTION
    1. Pulls Application Error (1000) and Windows Error Reporting (1001) events for OUTLOOK.EXE:
       exception code, faulting module name/version/offset, timestamps.
       Event 1000's faulting-module field is the single fact that attributes the crash
       (ole32.dll / EasyHook stub / outlfltr.dll / another add-in / OUTLOOK.EXE itself).
    2. Dumps Office Resiliency state: add-ins Outlook has flagged as crashing or disabled.
    3. With -EnableDumps: writes HKLM WER LocalDumps keys so the NEXT crash produces a full
       .dmp under C:\CrashDumps (no reboot required, takes effect immediately).
    4. Lists any dumps already present.

    Run as admin for -EnableDumps; event/registry collection works as the logged-on user
    except HKLM writes. Output is a transcript-friendly text report on stdout; pass -OutFile
    to also write it next to the script.

.EXAMPLE
    .\Collect-OutlookCrashInfo.ps1                       # collect only
    .\Collect-OutlookCrashInfo.ps1 -EnableDumps          # collect + arm full dumps
    .\Collect-OutlookCrashInfo.ps1 -Rollback             # collect + roll Office back to the known-good build
    .\Collect-OutlookCrashInfo.ps1 -OutFile crash.txt

.NOTES
    Crash cause (2026-06): drag-time fastfail 0xC0000409 P9=0x23 (heap corruption) triggered by
    Office *Insider* build 16.0.20131; the same add-in/EasyHook/ntdll work on Current Channel
    16.0.20026. -Rollback moves the machine back to the known-good build. The crash kills
    OUTLOOK.EXE before the add-in logs "Drag started", so its own log shows nothing useful.
#>
[CmdletBinding()]
param(
    [switch]$EnableDumps,
    [switch]$Rollback,                                   # fire OfficeC2RClient rollback to -GoodBuild
    [string]$GoodBuild = '16.0.20026.20168',             # fleet Current-Channel build that works with the add-in
    [string]$DumpFolder = 'C:\CrashDumps',
    [int]$DumpCount = 5,
    [int]$Days = 14,
    [string]$OutFile
)

$report = New-Object System.Collections.Generic.List[string]
function Out-Line([string]$s) { $report.Add($s); Write-Host $s }

Out-Line "=== Outlook crash evidence collection $(Get-Date -Format o) on $env:COMPUTERNAME ==="

# --- 1. Application Error 1000 / WER 1001 events for OUTLOOK.EXE -------------------------
Out-Line "`n--- Event Log: Application Error (1000) + WER (1001), last $Days days ---"
$since = (Get-Date).AddDays(-$Days)
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName      = 'Application'
        ProviderName = 'Application Error', 'Windows Error Reporting'
        Id           = 1000, 1001
        StartTime    = $since
    } -ErrorAction Stop | Where-Object { $_.Message -match 'OUTLOOK\.EXE' }

    if (-not $events) {
        Out-Line "No OUTLOOK.EXE crash events in window (other apps may have crashed; none were Outlook)."
    }
    foreach ($e in $events) {
        Out-Line "`n[$($e.TimeCreated)] Provider=$($e.ProviderName) Id=$($e.Id)"
        if ($e.Id -eq 1000) {
            # Event 1000 properties (Application Error):
            # 0 app name, 1 app version, 3 faulting module, 4 module version,
            # 6 exception code, 7 fault offset
            $p = $e.Properties
            if ($p.Count -ge 8) {
                Out-Line ("  App:             {0} {1}" -f $p[0].Value, $p[1].Value)
                Out-Line ("  Faulting module: {0} {1}" -f $p[3].Value, $p[4].Value)
                Out-Line ("  Exception code:  {0}"     -f $p[6].Value)
                Out-Line ("  Fault offset:    {0}"     -f $p[7].Value)
            }
            else {
                Out-Line ($e.Message -split "`n" | Select-Object -First 12 | Out-String)
            }
        }
        else {
            Out-Line ($e.Message -split "`n" | Select-Object -First 8 | Out-String)
        }
    }
}
catch [System.Exception] {
    # Get-WinEvent throws "No events were found..." when the filter matches nothing -- that is good news, not a failure.
    if ($_.Exception.Message -match 'No events were found') {
        Out-Line "No Application Error/WER events at all in the last $Days days -- if Outlook is dying, it is being killed/hung-closed, not crashing."
    }
    else {
        Out-Line "Event query failed: $($_.Exception.Message)"
    }
}

# --- 2. Office Resiliency: add-ins Outlook blames -----------------------------------------
Out-Line "`n--- Office Resiliency (per-user add-in crash/disable state) ---"
foreach ($key in @(
        'HKCU:\Software\Microsoft\Office\16.0\Outlook\Resiliency\DisabledItems',
        'HKCU:\Software\Microsoft\Office\16.0\Outlook\Resiliency\CrashingAddinList',
        'HKCU:\Software\Microsoft\Office\16.0\Outlook\Resiliency\NotificationReminderAddinData',
        'HKCU:\Software\Microsoft\Office\16.0\Outlook\Resiliency\StartupItems'
    )) {
    if (Test-Path $key) {
        Out-Line "${key}:"
        (Get-Item $key).Property | ForEach-Object {
            $val = (Get-ItemProperty -Path $key -Name $_).$_
            if ($val -is [byte[]]) {
                # Resiliency values are REG_BINARY with embedded UTF-16 strings; surface readable parts
                $text = [System.Text.Encoding]::Unicode.GetString($val) -replace '[^ -~]+', ' | '
                Out-Line "  $_ = $text"
            }
            else { Out-Line "  $_ = $val" }
        }
    }
    else { Out-Line "$key : not present" }
}
# DoNotDisableAddinList (doc-verified): DWORD per ProgID = the reason Outlook flagged the add-in.
# This is the direct attribution: 0x3 against our ProgID == Outlook saw the add-in crash it.
$reason = @{ 1 = 'Boot load failed'; 2 = 'Load failed'; 3 = 'CRASH';
    4 = 'Slow boot'; 5 = 'Slow shutdown'; 6 = 'Slow load'; 7 = 'Failed shutdown';
    8 = 'Failed termination'; 9 = 'Crash, but kept (allow list)'; 10 = 'Crash, but kept (user said no)' }
$ddKey = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Resiliency\DoNotDisableAddinList'
Out-Line "${ddKey}:"
if (Test-Path $ddKey) {
    (Get-Item $ddKey).Property | ForEach-Object {
        $code = [int](Get-ItemProperty -Path $ddKey -Name $_).$_
        $why = if ($reason.ContainsKey($code)) { $reason[$code] } else { "unknown ($code)" }
        $flag = if ($_ -match 'OutlookFileDrag') { '  <<< OUR ADD-IN' } else { '' }
        Out-Line ("  {0} = 0x{1:X} ({2}){3}" -f $_, $code, $why, $flag)
    }
}
else { Out-Line "  not present (Outlook has not recorded a resiliency reason for any add-in)" }
# Add-in load behavior (3 = loaded, 2 = disabled by user/resiliency demotion)
$addinKey = 'HKCU:\Software\Microsoft\Office\Outlook\Addins\OutlookFileDrag'
foreach ($hive in 'HKCU:', 'HKLM:') {
    $k = "$hive\Software\Microsoft\Office\Outlook\Addins\OutlookFileDrag"
    if (Test-Path $k) {
        $lb = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).LoadBehavior
        Out-Line "$k LoadBehavior = $lb"
    }
}

# --- 3. Arm WER LocalDumps for OUTLOOK.EXE -------------------------------------------------
if ($EnableDumps) {
    Out-Line "`n--- Enabling WER LocalDumps for OUTLOOK.EXE ---"
    $werKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\OUTLOOK.EXE'
    try {
        New-Item -Path $werKey -Force | Out-Null
        New-Item -Path $DumpFolder -ItemType Directory -Force | Out-Null
        Set-ItemProperty -Path $werKey -Name DumpFolder -Value $DumpFolder -Type ExpandString
        Set-ItemProperty -Path $werKey -Name DumpType   -Value 2 -Type DWord       # 2 = full dump
        Set-ItemProperty -Path $werKey -Name DumpCount  -Value $DumpCount -Type DWord
        Out-Line "LocalDumps armed: $werKey -> $DumpFolder (full dumps, keep $DumpCount). Effective immediately, no reboot."
    }
    catch [Exception] {
        Out-Line "FAILED to arm LocalDumps (need admin): $($_.Exception.Message)"
    }
}

# --- 4. Existing dumps + WER report archives -------------------------------------------------
# WER often already saved a minidump for past crashes -- collect those before waiting for a repro.
Out-Line "`n--- Existing crash dumps and WER reports for OUTLOOK.EXE ---"
$collectTo = Join-Path $DumpFolder 'Collected'
New-Item -Path $collectTo -ItemType Directory -Force | Out-Null

foreach ($dir in @($DumpFolder, "$env:LOCALAPPDATA\CrashDumps", 'C:\ProgramData\Microsoft\Windows\WER\Temp')) {
    if (Test-Path $dir) {
        Get-ChildItem $dir -Include 'OUTLOOK*.dmp', '*.mdmp' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Out-Line ("  {0}  {1:N0} bytes  {2}" -f $_.FullName, $_.Length, $_.LastWriteTime)
            Copy-Item $_.FullName -Destination $collectTo -Force -ErrorAction SilentlyContinue
        }
    }
}
foreach ($werRoot in 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive', 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue') {
    if (Test-Path $werRoot) {
        Get-ChildItem $werRoot -Directory -Filter '*OUTLOOK.EXE*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
            Out-Line "  WER report: $($_.FullName)  $($_.LastWriteTime)"
            Copy-Item $_.FullName -Destination $collectTo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
Out-Line "Collected WER artifacts copied to: $collectTo"

# --- 5. Exploit-protection mitigations applied to OUTLOOK.EXE --------------------------------
# Intune/security-baseline mitigation policies can fastfail processes whose code gets patched.
Out-Line "`n--- Process mitigation policy for OUTLOOK.EXE ---"
try {
    $mit = Get-ProcessMitigation -Name 'OUTLOOK.EXE' -ErrorAction Stop
    Out-Line ($mit | Out-String)
}
catch [Exception] {
    Out-Line "Get-ProcessMitigation failed or no per-app policy: $($_.Exception.Message)"
}

# --- 6. What changed on this machine: update timeline + key module versions ------------------
Out-Line "`n--- Recent OS updates (correlate with crash onset date) ---"
try {
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 | ForEach-Object {
        Out-Line ("  {0}  {1}  {2}" -f $_.InstalledOn, $_.HotFixID, $_.Description)
    }
}
catch [Exception] { Out-Line "Get-HotFix failed: $($_.Exception.Message)" }

Out-Line "`n--- Key module versions ---"
foreach ($m in 'C:\Windows\System32\ntdll.dll', 'C:\Windows\System32\ole32.dll', 'C:\Windows\System32\combase.dll') {
    $v = (Get-Item $m -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    Out-Line "  $m = $v"
}

# --- 7. Office Click-to-Run channel + build (the variable that flips working <-> crashing) ----
Out-Line "`n--- Office Click-to-Run configuration ---"
$c2r = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$cfg = Get-ItemProperty -Path $c2r -ErrorAction SilentlyContinue
$c2rClient = Join-Path ${env:CommonProgramFiles} 'Microsoft Shared\ClickToRun\OfficeC2RClient.exe'
if ($cfg) {
    Out-Line "  VersionToReport : $($cfg.VersionToReport)"
    Out-Line "  AudienceData    : $($cfg.AudienceData)     (Insider audiences are the canary; CC=Current Channel)"
    Out-Line "  UpdateChannel   : $($cfg.UpdateChannel)"
    Out-Line "  CDNBaseUrl      : $($cfg.CDNBaseUrl)"
    Out-Line "  Known-good build (works with add-in): $GoodBuild"
    if ($cfg.VersionToReport -eq $GoodBuild) {
        Out-Line "  STATUS: already on the known-good build."
    }
    else {
        Out-Line "  STATUS: NOT on known-good build. To roll back, re-run with -Rollback (or run the command below):"
        Out-Line "    `"$c2rClient`" /update user updatetoversion=$GoodBuild forceappshutdown=true displaylevel=false"
    }
}
else {
    Out-Line "  ClickToRun Configuration key not found -- not a C2R install, or MSI Office."
}

# --- 8. Roll Office back to the known-good build (only with -Rollback) -------------------------
if ($Rollback) {
    Out-Line "`n--- Rolling Office back to $GoodBuild ---"
    if (-not (Test-Path $c2rClient)) {
        Out-Line "OfficeC2RClient.exe not found at $c2rClient -- cannot roll back automatically."
    }
    else {
        # Pin the build so AutoUpgrade doesn't immediately re-apply the bad Insider build after rollback.
        try {
            Set-ItemProperty -Path $c2r -Name UpdatesEnabled -Value 'False' -ErrorAction SilentlyContinue
            Out-Line "  Pinned: UpdatesEnabled=False (prevents auto re-update to the bad build; re-enable after fix)."
        }
        catch [Exception] { Out-Line "  Could not set UpdatesEnabled (need admin): $($_.Exception.Message)" }
        Out-Line "  Launching: OfficeC2RClient.exe /update user updatetoversion=$GoodBuild forceappshutdown=true displaylevel=false"
        Out-Line "  NOTE: this CLOSES Outlook and all Office apps, then downgrades. Save work first."
        try {
            Start-Process -FilePath $c2rClient `
                -ArgumentList "/update user updatetoversion=$GoodBuild forceappshutdown=true displaylevel=false" -ErrorAction Stop
            Out-Line "  Rollback started. Track progress in the Office update UI / event log; verify build afterward."
        }
        catch [Exception] { Out-Line "  Rollback launch FAILED: $($_.Exception.Message)" }
    }
}

if ($OutFile) { $report | Set-Content -Path $OutFile -Encoding UTF8; Out-Line "`nReport written to $OutFile" }
