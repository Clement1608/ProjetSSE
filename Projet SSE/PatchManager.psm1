#Requires -Version 5.1


$script:LogFile = $null
$script:SidRemoteMgmtUsers = 'S-1-5-32-580'


# Date Française

function Format-PMDate {
    param($Date, [switch]$WithTime)
    if (-not $Date) { return '' }
    $fmt = 'dd/MM/yyyy'
    if ($WithTime) { $fmt = 'dd/MM/yyyy HH:mm:ss' }
    return ([datetime]$Date).ToString($fmt, [cultureinfo]::InvariantCulture)
}

# Charge config.psd1, crée le dossier de sortie et initialise le journal.
function Initialize-PM {
    param([Parameter(Mandatory)][string]$Root)
    $cfg = Import-PowerShellDataFile -Path (Join-Path $Root 'config.psd1')
    $out = $cfg.OutputDir
    if (-not [System.IO.Path]::IsPathRooted($out)) { $out = Join-Path $Root $out }
    if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
    $cfg.OutputDir = $out
    $script:LogFile = Join-Path $out 'PatchManager.log'
    return $cfg
}

#Pour les logs
function Write-PMLog {
    param([Parameter(Mandatory)][string]$Message)
    $line = '{0} ; {1}' -f (Format-PMDate (Get-Date) -WithTime), (($Message -replace '\s*[\r\n]+\s*', ' ').Trim())
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    Write-Host $line -ForegroundColor DarkGray
}

# Fonction pour l'export CSV
function Export-PMCsv {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject, [Parameter(Mandatory)][string]$Path)
    $encoding = 'UTF8'
    if ($PSVersionTable.PSVersion.Major -ge 6) { $encoding = 'utf8BOM' }
    $InputObject | Export-Csv -Path $Path -NoTypeInformation -Delimiter ';' -Encoding $encoding
}

function Get-PMCredentialPath {
    param([ValidateSet('remoting', 'smtp')][string]$Name)
    return Join-Path (Join-Path $env:LOCALAPPDATA 'PatchManager') "$Name.cred.xml"
}

# Lit les crededntials (null si n'existe pas)
function Get-PMSavedCredential {
    param([ValidateSet('remoting', 'smtp')][string]$Name)
    $file = Get-PMCredentialPath -Name $Name
    if (Test-Path $file) { return Import-Clixml -Path $file }
    return $null
}

#Lecture des fichiers 

#Computer.txt pour récuperer les adresses et noms des machines 
function Get-PMComputerList {

    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Fichier d'inventaire introuvable : $Path" }
    foreach ($line in Get-Content -Path $Path) {
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $parts = $l.Split(';')
        if ($parts.Count -lt 2 -or -not $parts[0].Trim() -or -not $parts[1].Trim()) {
            Write-Warning "Ligne ignorée dans $Path (format attendu NOM;IP) : $l"
            continue
        }
        [pscustomobject]@{ Nom = $parts[0].Trim(); IP = $parts[1].Trim() }
    }
}

# Pareil que pour computer, mais pour les patchs
function Get-PMRequiredPatches {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Liste des correctifs requis introuvable : $Path" }
    $list = foreach ($line in Get-Content -Path $Path) {
        $l = $line.Trim().ToUpper()
        if (-not $l -or $l.StartsWith('#')) { continue }
        if ($l -notmatch '^KB\d+$') { Write-Warning "KB invalide ignorée : $l"; continue }
        $l
    }
    return @($list | Select-Object -Unique)
}


# Test ping + WinRM.
function Test-PMComputer {
    param([Parameter(Mandatory)]$Computer)
    $ping = [bool](Test-Connection -ComputerName $Computer.IP -Count 1 -Quiet -ErrorAction SilentlyContinue)
    $winrm = $false
    $erreur = $null
    try {
        Test-WSMan -ComputerName $Computer.IP -ErrorAction Stop | Out-Null
        $winrm = $true
    }
    catch {
        if ($ping) { $erreur = 'WinRM inaccessible' } else { $erreur = 'Hôte injoignable' }
    }
    $etat = 'Inaccessible'
    if ($winrm) { $etat = 'Accessible' }
    [pscustomobject]@{
        Poste     = $Computer.Nom
        AdresseIP = $Computer.IP
        Ping      = $ping
        WinRM     = $winrm
        Etat      = $etat
        Erreur    = $erreur
    }
}

#Block qui s'éxéécute sur chaque poste, on récu^ère ainsi la listes des information et correctif
$script:CollectScript = {
    $os   = Get-CimInstance -ClassName Win32_OperatingSystem
    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $os.SystemDrive)
    $svc  = Get-Service -Name wuauserv -ErrorAction SilentlyContinue

    $wu = 'Introuvable'
    if ($svc) { $wu = [string]$svc.Status }

    [pscustomobject]@{
        PMType           = 'Systeme'
        NomPoste         = $cs.Name
        Modele           = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        VersionBios      = $bios.SMBIOSBIOSVersion
        Windows          = $os.Caption
        VersionWindows   = $os.Version
        Architecture     = $os.OSArchitecture
        DernierDemarrage = $os.LastBootUpTime
        RAMGo            = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        DisqueLibreGo    = [math]::Round($disk.FreeSpace / 1GB, 1)
        WindowsUpdate    = $wu
    }

    foreach ($h in Get-HotFix) {
        $date = $null
        try { if ($h.InstalledOn) { $date = [datetime]$h.InstalledOn } } catch { }
        [pscustomobject]@{
            PMType           = 'Correctif'
            KB               = $h.HotFixID
            Description      = $h.Description
            DateInstallation = $date
            InstallePar      = $h.InstalledBy
        }
    }
}

#On vérfie les infos et les correctifs de chaques postes
function Get-PMParcData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Computers,
        [pscredential]$Credential
    )
    foreach ($c in $Computers) {
        $t = Test-PMComputer -Computer $c
        $entry = [pscustomobject]@{
            Poste        = $c.Nom
            AdresseIP    = $c.IP
            Ping         = $t.Ping
            WinRM        = $t.WinRM
            Etat         = $t.Etat
            Erreur       = $t.Erreur
            Systeme      = $null
            Correctifs   = @()
            DateControle = Get-Date
        }
        if (-not $t.WinRM) {
            Write-PMLog "$($c.Nom) ; $($t.Erreur)"
            $entry
            continue
        }
        try {
            $p = @{ ComputerName = $c.IP; ScriptBlock = $script:CollectScript; ErrorAction = 'Stop' }
            if ($Credential) { $p.Credential = $Credential }
            $raw = @(Invoke-Command @p)
            $entry.Systeme = $raw | Where-Object { $_.PMType -eq 'Systeme' } | Select-Object -First 1
            $entry.Correctifs = @($raw | Where-Object { $_.PMType -eq 'Correctif' })
            if (-not $entry.Systeme) { throw 'Aucune donnée système renvoyée par le poste.' }
            Write-PMLog "$($c.Nom) ; Accessible"
        }
        catch {
            $msg = ($_.Exception.Message -replace '\s*[\r\n]+\s*', ' ').Trim()
            $entry.Etat = 'Inaccessible'
            $entry.Erreur = "Commande distante en échec : $msg"
            $entry.Systeme = $null
            $entry.Correctifs = @()
            Write-PMLog "$($c.Nom) ; ERREUR ; Commande distante en échec ; $msg"
        }
        $entry
    }
}

#Oncree l'inventory du parc
function Get-PMInventory {
    param([Parameter(Mandatory)][object[]]$Data)
    foreach ($d in $Data) {
        $s = $d.Systeme
        if (-not $s) {
            [pscustomobject]@{
                Poste = $d.Poste; AdresseIP = $d.AdresseIP; Etat = $d.Etat
                NomPoste = ''; Modele = ''; VersionBios = ''; Windows = ''; VersionWindows = ''
                Architecture = ''; DernierDemarrage = ''; RAMGo = ''; DisqueLibreGo = ''
                DerniereMaj = ''; NbMaj = ''; WindowsUpdate = ''; Erreur = $d.Erreur
            }
            continue
        }
        $dernier = $d.Correctifs | Where-Object { $_.DateInstallation } |
            Sort-Object DateInstallation -Descending | Select-Object -First 1
        $derniereMaj = $null
        if ($dernier) { $derniereMaj = $dernier.DateInstallation }
        [pscustomobject]@{
            Poste            = $d.Poste
            AdresseIP        = $d.AdresseIP
            Etat             = $d.Etat
            NomPoste         = $s.NomPoste
            Modele           = $s.Modele
            VersionBios      = $s.VersionBios
            Windows          = $s.Windows
            VersionWindows   = $s.VersionWindows
            Architecture     = $s.Architecture
            DernierDemarrage = Format-PMDate $s.DernierDemarrage
            RAMGo            = $s.RAMGo
            DisqueLibreGo    = $s.DisqueLibreGo
            DerniereMaj      = Format-PMDate $derniereMaj
            NbMaj            = @($d.Correctifs).Count
            WindowsUpdate    = $s.WindowsUpdate
            Erreur           = $d.Erreur
        }
    }
}

#pariel que pour l'inventory, mais pour les correctifs (trié par ordre croissant)
function Get-PMPatchInventory {
    param([Parameter(Mandatory)][object[]]$Data)
    $rows = foreach ($d in $Data) {
        foreach ($h in $d.Correctifs) {
            [pscustomobject]@{
                Poste = $d.Poste; AdresseIP = $d.AdresseIP; KB = $h.KB; Description = $h.Description
                DateTri = $h.DateInstallation; InstallePar = $h.InstallePar
            }
        }
    }
    @($rows) | Where-Object { $_ } |
        Sort-Object @{ Expression = 'Poste'; Descending = $false }, @{ Expression = 'DateTri'; Descending = $true } |
        Select-Object Poste, AdresseIP, KB, Description,
            @{ Name = 'DateInstallation'; Expression = { Format-PMDate $_.DateTri } }, InstallePar
}

# On récupère le nombre de correctifs, la date ainsi que les dernier KB.
function Get-PMPatchSummary {
    param([Parameter(Mandatory)][object[]]$Data)
    foreach ($d in $Data) {
        if ($d.Etat -ne 'Accessible') { continue }
        $dernier = $d.Correctifs | Where-Object { $_.DateInstallation } |
            Sort-Object DateInstallation -Descending | Select-Object -First 1
        $date = $null; $kb = ''
        if ($dernier) { $date = $dernier.DateInstallation; $kb = $dernier.KB }
        [pscustomobject]@{
            Poste              = $d.Poste
            NbCorrectifs       = @($d.Correctifs).Count
            DateDernierCorrectif = Format-PMDate $date
            DernierKB          = $kb
        }
    }
}


# On Compare les KB installées aux KB requises. CONFORME seulement si toutes les KB requises sont présentes.
function Get-PMCompliance {
    param(
        [Parameter(Mandatory)][object[]]$Data,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RequiredPatches
    )
    foreach ($d in $Data) {
        $date = Format-PMDate $d.DateControle -WithTime
        if ($d.Etat -ne 'Accessible') {
            [pscustomobject]@{
                Poste = $d.Poste; AdresseIP = $d.AdresseIP; KBRequises = $RequiredPatches.Count
                KBManquantes = ''; ListeKBManquantes = ''; Etat = 'INACCESSIBLE'; DateControle = $date
            }
            continue
        }
        $installed = @($d.Correctifs | ForEach-Object { ([string]$_.KB).ToUpper() })
        $missing = @($RequiredPatches | Where-Object { $installed -notcontains $_ })
        if ($missing.Count -eq 0) {
            $etat = 'CONFORME'
            Write-PMLog "$($d.Poste) ; Conforme"
        }
        else {
            $etat = 'NON CONFORME'
            Write-PMLog "$($d.Poste) ; Non conforme ; $($missing -join ', ')"
        }
        [pscustomobject]@{
            Poste             = $d.Poste
            AdresseIP         = $d.AdresseIP
            KBRequises        = $RequiredPatches.Count
            KBManquantes      = $missing.Count
            ListeKBManquantes = ($missing -join ', ')
            Etat              = $etat
            DateControle      = $date
        }
    }
}

# Synthèse globale, avec les états de conformités (si machine innaccessible, alors on ne la prend pas en compte).
function Get-PMSummary {
    param([Parameter(Mandatory)][object[]]$Compliance)
    $conformes = @($Compliance | Where-Object { $_.Etat -eq 'CONFORME' }).Count
    $nonConformes = @($Compliance | Where-Object { $_.Etat -eq 'NON CONFORME' })
    $inaccessibles = @($Compliance | Where-Object { $_.Etat -eq 'INACCESSIBLE' }).Count
    $accessibles = $conformes + $nonConformes.Count
    $manquants = 0
    foreach ($n in $nonConformes) { $manquants += [int]$n.KBManquantes }
    $taux = 0
    if ($accessibles -gt 0) { $taux = [math]::Round(100 * $conformes / $accessibles, 1) }
    [pscustomobject]@{
        Total               = @($Compliance).Count
        Accessibles         = $accessibles
        Inaccessibles       = $inaccessibles
        Conformes           = $conformes
        NonConformes        = $nonConformes.Count
        CorrectifsManquants = $manquants
        TauxConformite      = $taux
    }
}


# On fusionne inventaire et conformité : une ligne par poste
function New-PMSecurityReport {
    param([Parameter(Mandatory)][object[]]$Inventory, [Parameter(Mandatory)][object[]]$Compliance)
    foreach ($c in $Compliance) {
        $i = $Inventory | Where-Object { $_.Poste -eq $c.Poste -and $_.AdresseIP -eq $c.AdresseIP } | Select-Object -First 1
        [pscustomobject]@{
            Poste             = $c.Poste
            AdresseIP         = $c.AdresseIP
            Accessibilite     = $i.Etat
            Windows           = $i.Windows
            DernierDemarrage  = $i.DernierDemarrage
            WindowsUpdate     = $i.WindowsUpdate
            KBRequises        = $c.KBRequises
            KBManquantes      = $c.KBManquantes
            ListeKBManquantes = $c.ListeKBManquantes
            Conformite        = $c.Etat
            DateControle      = $c.DateControle
            Erreur            = $i.Erreur
        }
    }
}

# Encode le texte pour le HTML
function ConvertTo-PMHtmlText {
    param($Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-PMBadge {
    param([string]$Etat)
    $class = 'na'
    if ($Etat -eq 'CONFORME') { $class = 'ok' } elseif ($Etat -eq 'NON CONFORME') { $class = 'ko' }
    return '<span class="badge {0}">{1}</span>' -f $class, (ConvertTo-PMHtmlText $Etat)
}

# On génére le rapport en html
function Export-PMHtmlReport {
    param(
        [Parameter(Mandatory)][object[]]$Report,
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)][string]$Path
    )
    $cards = @(
        @('Postes', $Summary.Total), @('Accessibles', $Summary.Accessibles), @('Inaccessibles', $Summary.Inaccessibles),
        @('Conformes', $Summary.Conformes), @('Non conformes', $Summary.NonConformes),
        @('Correctifs manquants', $Summary.CorrectifsManquants), @('Taux de conformité', "$($Summary.TauxConformite) %")
    ) | ForEach-Object { '<div class="card"><div class="num">{0}</div><div class="lbl">{1}</div></div>' -f (ConvertTo-PMHtmlText $_[1]), (ConvertTo-PMHtmlText $_[0]) }

    $todo = @($Report | Where-Object { $_.Conformite -ne 'CONFORME' })
    if ($todo.Count -eq 0) {
        $todoHtml = '<p class="allgood">Aucun poste ne nécessite d''intervention.</p>'
    }
    else {
        $rows = foreach ($r in $todo) {
            if ($r.Conformite -eq 'INACCESSIBLE') {
                $action = "Vérifier l'alimentation, le réseau et WinRM. " + $r.Erreur
            }
            else {
                $action = 'Installer : ' + $r.ListeKBManquantes
            }
            '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f (ConvertTo-PMHtmlText $r.Poste),
                (ConvertTo-PMHtmlText $r.AdresseIP), (Get-PMBadge $r.Conformite), (ConvertTo-PMHtmlText $action)
        }
        $todoHtml = '<div class="scroll"><table><thead><tr><th>Poste</th><th>Adresse IP</th><th>État</th><th>Action attendue</th></tr></thead><tbody>' +
            ($rows -join "`n") + '</tbody></table></div>'
    }

    $detail = foreach ($r in $Report) {
        $cells = @($r.Poste, $r.AdresseIP, $r.Accessibilite, $r.Windows, $r.DernierDemarrage, $r.WindowsUpdate,
            $r.KBRequises, $r.KBManquantes, $r.ListeKBManquantes) | ForEach-Object { '<td>{0}</td>' -f (ConvertTo-PMHtmlText $_) }
        '<tr>{0}<td>{1}</td><td>{2}</td></tr>' -f ($cells -join ''), (Get-PMBadge $r.Conformite), (ConvertTo-PMHtmlText $r.DateControle)
    }

    $html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rapport de sécurité Patch Management</title>
<style>
  body { font-family: "Segoe UI", Arial, sans-serif; margin: 0; padding: 2rem; background: #f4f5f7; color: #1d2330; }
  h1 { margin: 0 0 .25rem; font-size: 1.6rem; }
  h2 { margin: 2rem 0 .75rem; font-size: 1.15rem; border-bottom: 2px solid #1d2330; padding-bottom: .3rem; }
  .meta { color: #5b6475; margin: 0; }
  .cards { display: flex; flex-wrap: wrap; gap: .75rem; }
  .card { background: #fff; border: 1px solid #d9dde5; border-radius: 6px; padding: .8rem 1.1rem; min-width: 8.5rem; }
  .num { font-size: 1.6rem; font-weight: 700; }
  .lbl { color: #5b6475; font-size: .85rem; }
  .scroll { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; background: #fff; font-size: .9rem; }
  th, td { border: 1px solid #d9dde5; padding: .45rem .6rem; text-align: left; vertical-align: top; }
  th { background: #1d2330; color: #fff; white-space: nowrap; }
  .badge { display: inline-block; padding: .1rem .5rem; border-radius: 3px; font-weight: 700; font-size: .8rem; white-space: nowrap; }
  .ok { background: #d9f2e1; color: #17602f; }
  .ko { background: #fbdcdc; color: #8f1d1d; }
  .na { background: #e3e6ec; color: #3f4756; }
  .allgood { background: #d9f2e1; color: #17602f; padding: .8rem 1rem; border-radius: 6px; }
</style>
</head>
<body>
<h1>Rapport de sécurité Patch Management</h1>
<p class="meta">Généré le $(Format-PMDate (Get-Date) -WithTime) depuis $(ConvertTo-PMHtmlText $env:COMPUTERNAME)</p>

<h2>Synthèse globale du parc</h2>
<div class="cards">
$($cards -join "`n")
</div>

<h2>Postes nécessitant une intervention</h2>
$todoHtml

<h2>Détail par poste</h2>
<div class="scroll"><table>
<thead><tr><th>Poste</th><th>Adresse IP</th><th>Accessibilité</th><th>Windows</th><th>Dernier démarrage</th><th>Windows Update</th><th>KB requises</th><th>KB manquantes</th><th>Liste des KB manquantes</th><th>Conformité</th><th>Date du contrôle</th></tr></thead>
<tbody>
$($detail -join "`n")
</tbody>
</table></div>
</body>
</html>
"@
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $html, $utf8)
}


#Notification
function Get-PMNotificationText {
    param([Parameter(Mandatory)][object[]]$Report, [Parameter(Mandatory)]$Summary)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Date du contrôle : $(Format-PMDate (Get-Date))")
    $lines.Add('')
    $lines.Add("Postes contrôlés      : $($Summary.Total)")
    $lines.Add("Postes non conformes  : $($Summary.NonConformes)")
    $lines.Add("Postes inaccessibles  : $($Summary.Inaccessibles)")
    foreach ($r in ($Report | Where-Object { $_.Conformite -ne 'CONFORME' })) {
        $lines.Add('')
        $lines.Add("$($r.Poste) : $($r.Conformite)")
        if ($r.Conformite -eq 'NON CONFORME') {
            foreach ($kb in ($r.ListeKBManquantes -split ',\s*')) { $lines.Add("       $kb manquante") }
        }
    }
    return ($lines -join "`r`n")
}


#On envoit un mail, si un poste est non conforme (SMTP de gmail, paramétré dans les configs)
function Send-PMNotification {
    
    param(
        [Parameter(Mandatory)][object[]]$Report,
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)]$Config,
        [string[]]$Attachments
    )
    $anomalies = @($Report | Where-Object { $_.Conformite -eq 'NON CONFORME' -or $_.Conformite -eq 'INACCESSIBLE' })
    if ($anomalies.Count -eq 0) {
        Write-PMLog 'Aucune anomalie ; Pas de notification'
        return
    }
    $subject = '[PATCH MANAGEMENT] Anomalies détectées'
    $body = Get-PMNotificationText -Report $Report -Summary $Summary
    $n = $Config.Notification
    Set-Content -LiteralPath (Join-Path $Config.OutputDir 'Notification.txt') -Value ("Objet : $subject`r`n`r`n$body") -Encoding UTF8

    if (-not $n.Enabled) {
        Write-PMLog 'Anomalies détectées ; Notification désactivée dans config.psd1 (message dans Notification.txt)'
        return
    }
    try {
        $mail = @{
            SmtpServer  = $n.SmtpServer
            Port        = $n.Port
            From        = $n.From
            To          = $n.To
            Subject     = $subject
            Body        = $body
            Encoding    = [System.Text.Encoding]::UTF8
            ErrorAction = 'Stop'
        }
        if ($n.UseSsl) { $mail.UseSsl = $true }
        if ($Attachments) { $mail.Attachments = @($Attachments | Where-Object { Test-Path $_ }) }
        if ($n.UseCredential) {
            $cred = Get-PMSavedCredential -Name smtp
            if (-not $cred) { throw 'Identifiant SMTP absent : lancez .\Save-Credentials.ps1 -Type smtp' }
            $mail.Credential = $cred
        }
        Send-MailMessage @mail -WarningAction SilentlyContinue
        Write-PMLog "Notification envoyée à $($n.To)"
    }
    catch {
        Write-PMLog "ERREUR ; Notification non envoyée ; $($_.Exception.Message)"
    }
}
