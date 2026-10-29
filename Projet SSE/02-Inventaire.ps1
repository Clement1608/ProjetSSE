#Inventaire du parc
[CmdletBinding()]
param(
    [string]$ComputersFile = (Join-Path $PSScriptRoot 'computers.txt'),
    [pscredential]$Credential
)
Import-Module (Join-Path $PSScriptRoot 'PatchManager.psm1') -Force
$cfg = Initialize-PM -Root $PSScriptRoot
if (-not $Credential) { $Credential = Get-PMSavedCredential -Name remoting }

$computers = @(Get-PMComputerList -Path $ComputersFile)
$data = @(Get-PMParcData -Computers $computers -Credential $Credential)
$inventaire = @(Get-PMInventory -Data $data)

$inventaire | Format-Table Poste, AdresseIP, Windows, Architecture, DernierDemarrage, WindowsUpdate, Etat -AutoSize
$inventaire | Format-List Poste, NomPoste, Modele, VersionBios, VersionWindows, RAMGo, DisqueLibreGo, DerniereMaj, NbMaj, Erreur

$csv = Join-Path $cfg.OutputDir 'Inventory.csv'
Export-PMCsv -InputObject $inventaire -Path $csv
Write-Host "Inventaire exporté : $csv" -ForegroundColor Green
