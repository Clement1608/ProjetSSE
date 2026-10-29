#Requires -RunAsAdministrator
<#
    À exécuter EN ADMINISTRATEUR sur le poste d'administration (Partie 1, point 4).
    Hors domaine (groupe de travail), le client WinRM refuse de s'authentifier auprès d'une machine
    inconnue : on déclare donc les IP de computers.txt comme hôtes de confiance (TrustedHosts),
    et uniquement celles-là (jamais "*").

    Usage : .\Setup-Admin.ps1
#>
[CmdletBinding()]
param([string]$ComputersFile = (Join-Path (Split-Path $PSScriptRoot) 'computers.txt'))

Import-Module (Join-Path (Split-Path $PSScriptRoot) 'PatchManager.psm1') -Force

if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }

$ips = @(Get-PMComputerList -Path $ComputersFile | ForEach-Object { $_.IP })
Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($ips -join ',') -Force
Write-Host 'TrustedHosts :' (Get-Item WSMan:\localhost\Client\TrustedHosts).Value -ForegroundColor Green
