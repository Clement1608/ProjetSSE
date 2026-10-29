#Inventaire des Correctif/Maj
[CmdletBinding()]
param(
    [string]$ComputersFile = (Join-Path $PSScriptRoot 'computers.txt'),
    [pscredential]$Credential,
    [switch]$Local
)
Import-Module (Join-Path $PSScriptRoot 'PatchManager.psm1') -Force

if ($Local) {
    Get-HotFix | Sort-Object InstalledOn -Descending |
        Format-Table HotFixID, Description, InstalledOn, InstalledBy -AutoSize
    return
}

$cfg = Initialize-PM -Root $PSScriptRoot
if (-not $Credential) { $Credential = Get-PMSavedCredential -Name remoting }

$computers = @(Get-PMComputerList -Path $ComputersFile)
$data = @(Get-PMParcData -Computers $computers -Credential $Credential)

$correctifs = @(Get-PMPatchInventory -Data $data)
$correctifs | Format-Table Poste, AdresseIP, KB, Description, DateInstallation -AutoSize

Write-Host 'Résumé par poste :' -ForegroundColor Cyan
Get-PMPatchSummary -Data $data | Format-Table -AutoSize

$ignores = @($data | Where-Object { $_.Etat -ne 'Accessible' })
if ($ignores) { Write-Warning ("Postes ignorés (inaccessibles) : " + (($ignores | ForEach-Object { $_.Poste }) -join ', ')) }

$csv = Join-Path $cfg.OutputDir 'PatchesInventory.csv'
Export-PMCsv -InputObject $correctifs -Path $csv
Write-Host "Inventaire des correctifs exporté : $csv" -ForegroundColor Green
