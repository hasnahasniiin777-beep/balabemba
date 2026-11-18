# ================================================================
#  scripts/push_url_gdrive.ps1
#  Envoie la derniere URL Cloudflare Tunnel (Jellyfin) vers votre
#  Google Drive, via l'application Web Apps Script (Code.gs).
#
#  - Appele par Downloads.bat juste apres l'extraction d'une
#    NOUVELLE URL tunnel (a chaque generation => un push).
#  - Config lue dans C:\rclone\gdrive-push.json, ecrite par le
#    workflow depuis les secrets GOOGLE_SCRIPT_URL et
#    GDRIVE_PUSH_SECRET.
#  - Sans config : sortie silencieuse (code 0), jamais bloquant.
#  - Journal : %TEMP%\gdrive-push.log
# ================================================================
param(
    [string]$UrlFile    = "$env:USERPROFILE\Desktop\URL-Jellyfin.txt",
    [string]$ConfigFile = "C:\rclone\gdrive-push.json",
    [string]$LogFile    = "$env:TEMP\gdrive-push.log"
)

function Log($msg) {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# ---------- Config (absente = fonctionnalite desactivee) ----------
if (-not (Test-Path $ConfigFile)) {
    Log "Config absente ($ConfigFile) : envoi Google Drive desactive."
    exit 0
}
try {
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} catch {
    Log "Config illisible ($($_.Exception.Message)) : envoi desactive."
    exit 0
}
if (-not $cfg.scriptUrl -or -not $cfg.secret) {
    Log "Config incomplete : envoi Google Drive desactive."
    exit 0
}

# ---------- URL locale (generee par Downloads.bat) ----------
if (-not (Test-Path $UrlFile)) {
    Log "Fichier URL absent ($UrlFile) : rien a envoyer."
    exit 0
}
$m = Select-String -Path $UrlFile -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' |
     Select-Object -Last 1
if (-not $m) {
    Log "Aucune URL trycloudflare dans $UrlFile."
    exit 0
}
$url = $m.Matches[0].Value

# ---------- Envoi vers l'application Web Apps Script ----------
# Le corps hashtable est encode en form-urlencoded => chaque champ
# arrive dans e.parameter cote Apps Script.
$ok = $false
foreach ($t in 1..3) {
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $cfg.scriptUrl -TimeoutSec 20 -Body @{
            secret = $cfg.secret
            url    = $url
            host   = $env:COMPUTERNAME
        }
        if ($resp.status -eq 'ok') { $ok = $true; break }
        Log "Reponse Apps Script : $($resp.status) - $($resp.message) (essai $t/3)"
    } catch {
        Log "Envoi echoue (essai $t/3) : $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 5
}

if ($ok) {
    Log "URL envoyee vers Google Drive : $url"
    exit 0
}
Log "ENVOI IMPOSSIBLE apres 3 essais. URL locale : $url"
exit 1
