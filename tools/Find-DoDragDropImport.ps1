<#
.SYNOPSIS  Scan the normal AND delay import tables of every module currently loaded in the running
           Outlook process for a target function (default ole32!DoDragDrop). Tells us which module's
           IAT an IAT-hook must patch, and whether the call is reachable via a static/delay thunk at
           all (vs GetProcAddress, which leaves no thunk to patch). Dump-free, read-only.
#>
[CmdletBinding()]
param([string]$Func = 'DoDragDrop')
$ErrorActionPreference = 'SilentlyContinue'

function Test-PeImportsFunc {
    param([string]$Path, [string]$Func)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $b = [System.IO.File]::ReadAllBytes($Path)
    } catch { return $null }
    if ($b.Length -lt 0x40) { return $null }
    function U16($o) { if ($o -lt 0 -or $o + 2 -gt $b.Length) { return 0 } [BitConverter]::ToUInt16($b, $o) }
    function U32($o) { if ($o -lt 0 -or $o + 4 -gt $b.Length) { return 0 } [BitConverter]::ToUInt32($b, $o) }
    function U64($o) { if ($o -lt 0 -or $o + 8 -gt $b.Length) { return 0 } [BitConverter]::ToUInt64($b, $o) }
    $elf = U32 0x3C
    if ($elf -le 0 -or $elf + 0x100 -ge $b.Length) { return $null }
    if ([System.Text.Encoding]::ASCII.GetString($b, $elf, 4) -ne "PE`0`0") { return $null }
    $coff = $elf + 4
    $nSec = U16 ($coff + 6); $optSize = U16 ($coff + 16); $opt = $coff + 20
    if ((U16 $opt) -ne 0x20B) { return $null }   # PE32+ only
    $secStart = $opt + $optSize
    $secs = for ($i = 0; $i -lt $nSec; $i++) {
        $s = $secStart + $i * 40
        [pscustomobject]@{ VA = U32 ($s + 12); VSize = U32 ($s + 8); Raw = U32 ($s + 20); RawSize = U32 ($s + 16) }
    }
    function RvaToOff($rva) {
        if ($rva -eq 0) { return -1 }
        foreach ($s in $secs) {
            $span = [Math]::Max($s.VSize, $s.RawSize)
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $span)) { return ($rva - $s.VA + $s.Raw) }
        }
        return -1
    }
    function AsciiZ($off) {
        if ($off -lt 0 -or $off -ge $b.Length) { return '' }
        $sb = New-Object System.Text.StringBuilder
        while ($off -lt $b.Length -and $b[$off] -ne 0) { [void]$sb.Append([char]$b[$off]); $off++ }
        $sb.ToString()
    }
    function ScanThunks($intRva, $kind, $dll) {
        $t = RvaToOff $intRva
        if ($t -lt 0) { return }
        while ($t + 8 -le $b.Length) {
            $entry = U64 $t
            if ($entry -eq 0) { break }
            if (($entry -band 0x8000000000000000) -eq 0) {
                # Ordinal flag (bit 63) already excluded -> remaining low bits are the
                # IMAGE_IMPORT_BY_NAME RVA. Treat as a 32-bit RVA rather than masking 0x7FFFFFFF,
                # which would also clear RVA bit 31.
                $o = RvaToOff ([uint32]($entry -band 0xFFFFFFFF))
                if ($o -ge 0) { $fn = AsciiZ ($o + 2); if ($fn -ieq $Func) { $script:hits += "$dll ($kind)" } }
            }
            $t += 8
        }
    }
    $script:hits = @()
    # Normal imports: data directory[1]
    $impRva = U32 ($opt + 120)
    $d = RvaToOff $impRva
    if ($d -ge 0) {
        while ($d + 20 -le $b.Length) {
            $oft = U32 $d; $nameRva = U32 ($d + 12); $ft = U32 ($d + 16)
            if ($oft -eq 0 -and $nameRva -eq 0 -and $ft -eq 0) { break }
            $dll = AsciiZ (RvaToOff $nameRva)
            ScanThunks ($(if ($oft -ne 0) { $oft } else { $ft })) 'import' $dll
            $d += 20
        }
    }
    # Delay imports: data directory[13]
    $delRva = U32 ($opt + 120 + 12 * 8)
    $dd = RvaToOff $delRva
    if ($dd -ge 0) {
        while ($dd + 32 -le $b.Length) {
            $nameRva = U32 ($dd + 4); $intRva = U32 ($dd + 16)
            if ($nameRva -eq 0 -and $intRva -eq 0) { break }
            $dll = AsciiZ (RvaToOff $nameRva)
            ScanThunks $intRva 'delay' $dll
            $dd += 32
        }
    }
    if ($script:hits.Count) { return ($script:hits -join ', ') } else { return '' }
}

$ol = Get-Process OUTLOOK -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ol) { Write-Output 'OUTLOOK not running'; return }
$mods = $ol.Modules | Select-Object -ExpandProperty FileName -Unique
Write-Output "Scanning $($mods.Count) loaded modules for an import of '$Func'..."
$any = $false
foreach ($m in $mods) {
    try { $r = Test-PeImportsFunc -Path $m -Func $Func } catch { $r = $null }
    if ($r) { Write-Output ("  {0}  ->  {1}" -f [IO.Path]::GetFileName($m), $r); $any = $true }
}
if (-not $any) { Write-Output "  NO module has a static/delay import thunk for $Func (likely resolved via GetProcAddress)." }
