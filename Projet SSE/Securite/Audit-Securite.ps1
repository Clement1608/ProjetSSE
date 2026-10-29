#Requires -RunAsAdministrator
#Audit de la configuration de sécurité


[CmdletBinding()]
param([string]$OutputDir = (Join-Path (Split-Path $PSScriptRoot) 'output'))

function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

Section '8.2 - Qui peut ouvrir une session distante ? (points de terminaison et permissions)'
Get-PSSessionConfiguration | Format-Table Name, Permission -AutoSize -Wrap

Section '8.2 - Membres du groupe Administrateurs (S-1-5-32-544)'
Get-LocalGroupMember -SID 'S-1-5-32-544' | Format-Table Name, ObjectClass, PrincipalSource -AutoSize

Section '8.2 / 8.3 - Membres du groupe Utilisateurs de gestion à distance (S-1-5-32-580)'
Get-LocalGroupMember -SID 'S-1-5-32-580' -ErrorAction SilentlyContinue | Format-Table Name, ObjectClass, PrincipalSource -AutoSize

Section '8.5 - Règles de pare-feu WinRM (adresses distantes autorisées)'
Get-NetFirewallRule -Name 'WINRM*' -ErrorAction SilentlyContinue | ForEach-Object {
    $addr = $_ | Get-NetFirewallAddressFilter
    $port = $_ | Get-NetFirewallPortFilter
    [pscustomobject]@{
        Regle = $_.Name; Active = $_.Enabled; Profil = $_.Profile; Action = $_.Action
        Port = $port.LocalPort; AdressesDistantes = ($addr.RemoteAddress -join ', ')
    }
} | Format-Table -AutoSize -Wrap

Section '8.6 - Écouteurs WinRM (HTTP 5985 / HTTPS 5986)'
Get-ChildItem WSMan:\localhost\Listener | ForEach-Object {
    $l = $_
    [pscustomobject]@{
        Ecouteur  = $l.Name
        Transport = (Get-ChildItem $l.PSPath | Where-Object Name -eq 'Transport').Value
        Port      = (Get-ChildItem $l.PSPath | Where-Object Name -eq 'Port').Value
    }
} | Format-Table -AutoSize

Section "8.6 - Modes d'authentification acceptés par le service WinRM"
Get-ChildItem WSMan:\localhost\Service\Auth | Format-Table Name, Value -AutoSize
Write-Host 'AllowUnencrypted (service) :' (Get-Item WSMan:\localhost\Service\AllowUnencrypted).Value

Section '8.6 - Côté client : TrustedHosts et authentification'
Write-Host 'TrustedHosts :' (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
Get-ChildItem WSMan:\localhost\Client\Auth | Format-Table Name, Value -AutoSize

Section "8.4 - Droits d'accès sur le dossier des rapports ($OutputDir)"
if (Test-Path $OutputDir) {
    (Get-Acl $OutputDir).Access | Format-Table IdentityReference, FileSystemRights, AccessControlType, IsInherited -AutoSize
}
else { Write-Host 'Dossier absent sur ce poste (normal sur un poste supervisé).' }
