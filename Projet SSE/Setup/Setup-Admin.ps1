#Requires -RunAsAdministrator
#Permet de déclarer les hôtes de cobfiance et récupérer le statut WinrRM pour vérifier la connexion à distance
[CmdletBinding()]
param([string]$ComputersFile = (Join-Path (Split-Path $PSScriptRoot) 'computers.txt'))

Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PatchManager.psm1') -Force

if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }

$ips = @(Get-PMComputerList -Path $ComputersFile | ForEach-Object { $_.IP })
Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($ips -join ',') -Force
Write-Host 'TrustedHosts :' (Get-Item WSMan:\localhost\Client\TrustedHosts).Value -ForegroundColor Green
