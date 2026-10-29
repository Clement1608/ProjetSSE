#Requires -RunAsAdministrator
<#
    À exécuter EN ADMINISTRATEUR sur CHAQUE poste supervisé (Partie 1, point 4).
    - passe le réseau en profil Privé (Enable-PSRemoting échoue sur un profil Public)
    - active PowerShell Remoting / WinRM
    - autorise le ping (ICMPv4)
    - (option) limite WinRM à l'adresse du poste d'administration        -> Partie 8
    - (option) crée un compte de service NON administrateur pour l'audit -> Partie 8

    Usage : .\Setup-Cible.ps1
            .\Setup-Cible.ps1 -AdminIP 192.168.10.10 -CreateServiceAccount
#>
[CmdletBinding()]
param(
    [string]$AdminIP,
    [switch]$CreateServiceAccount,
    [string]$ServiceAccountName = 'svc-patch'
)

Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' } |
    Set-NetConnectionProfile -NetworkCategory Private

# Déjà actif (script lancé à distance) : Enable-PSRemoting redémarrerait WinRM et couperait la session en cours
if (-not (Test-WSMan -ErrorAction SilentlyContinue)) { Enable-PSRemoting -Force }

if (-not (Get-NetFirewallRule -DisplayName 'PatchManager - ICMPv4 Echo' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'PatchManager - ICMPv4 Echo' -Direction Inbound -Protocol ICMPv4 `
        -IcmpType 8 -Action Allow -Profile Private, Domain | Out-Null
}

if ($AdminIP) {
    # WinRM n'accepte plus que le poste d'administration
    Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' | Set-NetFirewallRule -RemoteAddress $AdminIP
    Write-Host "WinRM limité à l'adresse $AdminIP" -ForegroundColor Green
}

if ($CreateServiceAccount) {
    if (-not (Get-LocalUser -Name $ServiceAccountName -ErrorAction SilentlyContinue)) {
        $pwd1 = Read-Host -AsSecureString "Mot de passe du compte $ServiceAccountName"
        New-LocalUser -Name $ServiceAccountName -Password $pwd1 -PasswordNeverExpires `
            -Description 'Compte de service Patch Management' | Out-Null
    }
    # S-1-5-32-580 = groupe "Utilisateurs de gestion à distance" (SID utilisé car le nom dépend de la langue)
    Add-LocalGroupMember -SID 'S-1-5-32-580' -Member $ServiceAccountName -ErrorAction SilentlyContinue
    Write-Host "Compte $ServiceAccountName membre du groupe de gestion à distance (non administrateur)." -ForegroundColor Green
}

Get-Service WinRM | Format-Table Name, Status, StartType -AutoSize
Test-WSMan
