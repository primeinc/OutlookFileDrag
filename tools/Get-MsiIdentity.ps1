# Reads ProductVersion / ProductCode / UpgradeCode from an MSI's Property table.
param([Parameter(Mandatory)][string]$Path)
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @((Resolve-Path $Path).Path, 0))
function Prop($name) {
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$name'"))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if ($rec) { $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1)) } else { '<none>' }
}
Write-Output ("{0,-16} {1}" -f 'File:', [IO.Path]::GetFileName($Path))
Write-Output ("{0,-16} {1}" -f 'ProductVersion:', (Prop 'ProductVersion'))
Write-Output ("{0,-16} {1}" -f 'ProductCode:', (Prop 'ProductCode'))
Write-Output ("{0,-16} {1}" -f 'UpgradeCode:', (Prop 'UpgradeCode'))
