#Enumération de la conformité des PC
[CmdletBinding()]
param(
    [string]$ComputersFile = (Join-Path $PSScriptRoot 'computers.txt'),
    [string]$RequiredFile = (Join-Path $PSScriptRoot 'required-patches.txt'),
    [pscredential]$Credential
)
Import-Module (Join-Path $PSScriptRoot 'PatchManager.psm1') -Force
$cfg = Initialize-PM -Root $PSScriptRoot
if (-not $Credential) { $Credential = Get-PMSavedCredential -Name remoting }

$computers = @(Get-PMComputerList -Path $ComputersFile)
$requis = @(Get-PMRequiredPatches -Path $RequiredFile)
Write-Host ("Correctifs requis : " + ($requis -join ', ')) -ForegroundColor Cyan

$data = @(Get-PMParcData -Computers $computers -Credential $Credential)
$conformite = @(Get-PMCompliance -Data $data -RequiredPatches $requis)

$conformite | Format-Table Poste, KBRequises, KBManquantes, Etat, DateControle -AutoSize

foreach ($nc in ($conformite | Where-Object { $_.Etat -eq 'NON CONFORME' })) {
    Write-Host ("{0} - correctifs manquants : {1}" -f $nc.Poste, $nc.ListeKBManquantes) -ForegroundColor Red
}

$synthese = Get-PMSummary -Compliance $conformite
Write-Host ("Taux global de conformité : {0} % ({1} conforme(s) sur {2} poste(s) accessible(s))" -f `
        $synthese.TauxConformite, $synthese.Conformes, $synthese.Accessibles) -ForegroundColor Cyan

$csv = Join-Path $cfg.OutputDir 'ComplianceReport.csv'
Export-PMCsv -InputObject $conformite -Path $csv
Write-Host "Rapport de conformité exporté : $csv" -ForegroundColor Green
