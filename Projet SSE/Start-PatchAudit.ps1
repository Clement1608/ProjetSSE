#Audit complet, lancement de tout les scripts les uns a^près les autres 
[CmdletBinding()]
param(
    [string]$ComputersFile = (Join-Path $PSScriptRoot 'computers.txt'),
    [string]$RequiredFile = (Join-Path $PSScriptRoot 'required-patches.txt'),
    [pscredential]$Credential,
    [switch]$NoNotification
)
Import-Module (Join-Path $PSScriptRoot 'PatchManager.psm1') -Force
$cfg = Initialize-PM -Root $PSScriptRoot
$out = $cfg.OutputDir

Write-PMLog "Début de l'audit"
try {
    if (-not $Credential) { $Credential = Get-PMSavedCredential -Name remoting }
    $computers = @(Get-PMComputerList -Path $ComputersFile)
    $requis = @(Get-PMRequiredPatches -Path $RequiredFile)
    if ($computers.Count -eq 0) { throw 'Aucune machine dans le fichier d''inventaire.' }

    # 1. Collecte (une seule commande distante par poste)
    $data = @(Get-PMParcData -Computers $computers -Credential $Credential)

    # 2. Inventaire du parc et des correctifs
    $inventaire = @(Get-PMInventory -Data $data)
    Export-PMCsv -InputObject $inventaire -Path (Join-Path $out 'Inventory.csv')
    Export-PMCsv -InputObject @(Get-PMPatchInventory -Data $data) -Path (Join-Path $out 'PatchesInventory.csv')

    # 3. Conformité
    $conformite = @(Get-PMCompliance -Data $data -RequiredPatches $requis)
    Export-PMCsv -InputObject $conformite -Path (Join-Path $out 'ComplianceReport.csv')
    $synthese = Get-PMSummary -Compliance $conformite

    # 4. Rapport de sécurité (CSV + HTML)
    $rapport = @(New-PMSecurityReport -Inventory $inventaire -Compliance $conformite)
    $htmlPath = Join-Path $out 'SecurityReport.html'
    Export-PMCsv -InputObject $rapport -Path (Join-Path $out 'SecurityReport.csv')
    Export-PMHtmlReport -Report $rapport -Summary $synthese -Path $htmlPath
    Write-PMLog 'Rapport généré'

    # 5. Affichage console
    Write-Host "`n=== Rapport par poste ===" -ForegroundColor Cyan
    $rapport | Format-Table Poste, AdresseIP, Accessibilite, Windows, WindowsUpdate, KBRequises, KBManquantes, Conformite -AutoSize

    Write-Host '=== Synthèse globale du parc ===' -ForegroundColor Cyan
    [pscustomobject]@{
        'Nombre total de postes'               = $synthese.Total
        'Nombre de postes accessibles'         = $synthese.Accessibles
        'Nombre de postes inaccessibles'       = $synthese.Inaccessibles
        'Nombre de postes conformes'           = $synthese.Conformes
        'Nombre de postes non conformes'       = $synthese.NonConformes
        'Nombre total de correctifs manquants' = $synthese.CorrectifsManquants
        'Taux de conformité'                   = "$($synthese.TauxConformite) %"
    } | Format-List

    $aTraiter = @($rapport | Where-Object { $_.Conformite -ne 'CONFORME' })
    if ($aTraiter.Count -gt 0) {
        Write-Host '=== Postes nécessitant une intervention ===' -ForegroundColor Yellow
        $aTraiter | Format-Table Poste, AdresseIP, Conformite, ListeKBManquantes, Erreur -AutoSize -Wrap
    }
    Write-Host "Rapport HTML : $htmlPath" -ForegroundColor Green

    # 6. Notification (seulement en cas d'anomalie)
    if (-not $NoNotification) {
        Send-PMNotification -Report $rapport -Summary $synthese -Config $cfg -Attachments $htmlPath
    }
}
catch {
    Write-PMLog "ERREUR ; $($_.Exception.Message)"
    throw
}
finally {
    Write-PMLog "Fin de l'audit"
}
