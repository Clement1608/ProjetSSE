# Enregistrer les ids
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('remoting', 'smtp')][string]$Type,
    [switch]$Remove
)
Import-Module (Join-Path $PSScriptRoot 'PatchManager.psm1') -Force
$file = Get-PMCredentialPath -Name $Type

if ($Remove) {
    if (Test-Path $file) { Remove-Item $file; Write-Host "Identifiant supprimé : $file" }
    return
}
$dir = Split-Path $file
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$cred = Get-Credential -Message "Identifiant '$Type' pour PatchManager"
if ($cred) {
    $cred | Export-Clixml -Path $file
    Write-Host "Identifiant enregistré (chiffré) : $file" -ForegroundColor Green
}
