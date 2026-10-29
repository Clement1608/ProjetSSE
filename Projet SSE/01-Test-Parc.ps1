#Voir les PC du parc
[CmdletBinding()]
param([string]$ComputersFile = (Join-Path $PSScriptRoot 'computers.txt'))

Import-Module (Join-Path $PSScriptRoot 'PatchManager.psm1') -Force

$computers = @(Get-PMComputerList -Path $ComputersFile)
$resultats = foreach ($c in $computers) { Test-PMComputer -Computer $c }
$resultats | Format-Table Poste, AdresseIP, Ping, WinRM, Etat, Erreur -AutoSize
