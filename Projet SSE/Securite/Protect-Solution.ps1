#Requires -RunAsAdministrator
#Restriction sur l'accès au dossier output
[CmdletBinding()]
param([string]$OutputDir = (Join-Path (Split-Path $PSScriptRoot) 'output'))

$moi = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$dossiers = @($OutputDir, (Join-Path $env:LOCALAPPDATA 'PatchManager')) | Where-Object { Test-Path $_ }

foreach ($d in $dossiers) {
    icacls $d /inheritance:r /grant:r "${moi}:(OI)(CI)F" '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    Write-Host "Accès restreint : $d" -ForegroundColor Green
    (Get-Acl $d).Access | Format-Table IdentityReference, FileSystemRights, AccessControlType -AutoSize
}
