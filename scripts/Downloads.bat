@echo off
setlocal
REM ==================================================================
REM  scripts/Downloads.bat
REM  Copie par le workflow dans le dossier Demarrage de la session RDP
REM  (C:\Users\RDP\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup)
REM  et execute a CHAQUE ouverture de session.
REM ==================================================================

set "LOG=%USERPROFILE%\Downloads.log"
set "RCLONE=C:\rclone\rclone.exe"
set "RCONF=C:\rclone\rclone.conf"
echo [%date% %time%] Session RDP demarree >> "%LOG%"

REM ------------------------------------------------------------------
REM 1) Neat Download Manager : installation silencieuse (1 seule fois)
REM    Inno Setup : /VERYSILENT /NORESTART
REM ------------------------------------------------------------------
if exist "%LOCALAPPDATA%\NDM_installed.flag" goto :ndm_done
echo [%date% %time%] Installation de Neat Download Manager... >> "%LOG%"
powershell -NoProfile -Command "Invoke-WebRequest -Uri 'https://www.neatdownloadmanager.com/file/NeatDM_setup.exe' -OutFile \"$env:TEMP\NeatDM_setup.exe\""
if not exist "%TEMP%\NeatDM_setup.exe" (
    echo [%date% %time%] ERREUR : telechargement NDM echoue >> "%LOG%"
    goto :ndm_done
)
"%TEMP%\NeatDM_setup.exe" /VERYSILENT /NORESTART
del "%TEMP%\NeatDM_setup.exe" >nul 2>nul
echo ok> "%LOCALAPPDATA%\NDM_installed.flag"
echo [%date% %time%] NDM installe >> "%LOG%"
:ndm_done

REM ------------------------------------------------------------------
REM 2) MEGAsync : lance au login (installe machine-wide par le workflow)
REM    Le login du compte MEGA se fait dans l'assistant graphique.
REM ------------------------------------------------------------------
set "MEGAEXE=%ProgramFiles%\MEGAsync\MEGAsync.exe"
if not exist "%MEGAEXE%" set "MEGAEXE=%LocalAppData%\MEGAsync\MEGAsync.exe"
if exist "%MEGAEXE%" (
    tasklist /FI "IMAGENAME eq MEGAsync.exe" 2>nul | find /I "MEGAsync.exe" >nul || start "" "%MEGAEXE%"
    echo [%date% %time%] MEGAsync lance. Login MEGA a faire dans l'assistant au 1er lancement >> "%LOG%"
) else (
    echo [%date% %time%] MEGAsync.exe introuvable - verifiez l'etape du workflow >> "%LOG%"
)

REM ------------------------------------------------------------------
REM 3) rclone : monte le disque UNIQUE combine (tous les comptes MEGA)
REM    Le workflow cree dans la config rclone :
REM      - un remote par compte (mega:, mega2:, ...) verifie par 'rclone about'
REM      - un remote combine MEGA_MULTI: (backend combine) qui regroupe tout
REM    Downloads.bat ne monte plus qu'UN SEUL disque :
REM    MEGA_MULTI: -> M:  (partage reseau \\rclone\mega)
REM    Volname en UNC \\rclone\mega => --network-mode implicite : le
REM    montage devient GLOBAL et donc VISIBLE PAR LE SERVICE JELLYFIN
REM    (session 0), pas seulement dans la session RDP.
REM    Dans Jellyfin utiliser les chemins UNC : \\rclone\mega\<compte>
REM    (un sous-dossier par compte, nom derive de l'email du compte)
REM    Log du montage : %TEMP%\rclone-mount-M.log
REM ------------------------------------------------------------------
if exist "%RCLONE%" goto :rclone_ok
echo [%date% %time%] ERREUR : %RCLONE% introuvable >> "%LOG%"
goto :mount_done
:rclone_ok
if exist "%RCONF%" goto :rconf_ok
echo [%date% %time%] ERREUR : %RCONF% introuvable >> "%LOG%"
goto :mount_done
:rconf_ok
REM Ajouter/retirer un compte MEGA = editer SEULEMENT le secret MEGA_ACCOUNTS
REM (le workflow recree le remote combine a chaque execution).
REM NB : un compte dont la connexion a echoue est simplement exclu du disque
REM combine par le workflow (avertissement dans le log du run GitHub).
call :mount_one MEGA_MULTI: M: \\rclone\mega
:mount_done

REM ------------------------------------------------------------------
REM 4) Jellyfin : service installe par le workflow, interface web 8096
REM ------------------------------------------------------------------
powershell -NoProfile -Command "Get-Service | Where-Object { $_.Name -like '*Jellyfin*' -or $_.DisplayName -like '*Jellyfin*' } | Start-Service -ErrorAction SilentlyContinue"
start "" "http://localhost:8096"
echo [%date% %time%] Jellyfin web : http://localhost:8096 >> "%LOG%"

REM ------------------------------------------------------------------
REM 5) Cloudflare Tunnel : Jellyfin expose publiquement (TryCloudflare)
REM    URL aleatoire, change a chaque demarrage du tunnel.
REM    Ecrite dans : Desktop\URL-Jellyfin.txt et Downloads.log
REM    NOUVEAU : envoyee vers Google Drive (fichier URL-Jellyfin.txt)
REM    via l'application Web Apps Script, par push_url_gdrive.ps1.
REM    Log complet du tunnel : C:\cloudflared\tunnel.log
REM ------------------------------------------------------------------
set "CFEXE=C:\cloudflared\cloudflared.exe"
set "CFLOG=C:\cloudflared\tunnel.log"
if exist "%CFEXE%" goto :cf_ok
echo [%date% %time%] cloudflared.exe introuvable - verifiez l'etape du workflow >> "%LOG%"
goto :cf_done
:cf_ok
tasklist /FI "IMAGENAME eq cloudflared.exe" 2>nul | find /I "cloudflared.exe" >nul && goto :cf_up
echo [%date% %time%] Lancement du tunnel Cloudflare -^> Jellyfin... >> "%LOG%"
type nul > "%CFLOG%" 2>nul
powershell -NoProfile -Command "Start-Process -WindowStyle Hidden '%CFEXE%' -ArgumentList 'tunnel','--url','http://localhost:8096','--logfile','%CFLOG%','--loglevel','info'"
ping -n 21 127.0.0.1 >nul
powershell -NoProfile -Command "$m = Select-String -Path '%CFLOG%' -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -Last 1; if ($m) { $u = $m.Matches[0].Value; $u | Out-File -Encoding ascii '%USERPROFILE%\Desktop\URL-Jellyfin.txt'; Add-Content -Path '%LOG%' -Value \"[%date% %time%] Tunnel Cloudflare actif : $u\" } else { Add-Content -Path '%LOG%' -Value \"[%date% %time%] ERREUR : URL tunnel introuvable dans %CFLOG%\" }"

REM Push de la nouvelle URL vers Google Drive (Apps Script).
REM Script et config installes par le workflow dans C:\rclone\
REM (secrets GOOGLE_SCRIPT_URL + GDRIVE_PUSH_SECRET).
REM Sans config : le script sort silencieusement, rien a changer ici.
if exist "C:\rclone\push_url_gdrive.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "C:\rclone\push_url_gdrive.ps1" -UrlFile "%USERPROFILE%\Desktop\URL-Jellyfin.txt"
)
goto :cf_done
:cf_up
echo [%date% %time%] Tunnel Cloudflare deja actif >> "%LOG%"
:cf_done

echo Downloads.bat termine.
endlocal
exit /b 0

REM ==================================================================
REM Sous-routine : monte un remote rclone sur une lettre de lecteur
REM   %1 = remote (ex: MEGA_MULTI:)   %2 = lettre (ex: M:)   %3 = volname UNC
REM ==================================================================
:mount_one
set "DRV=%~2"
set "DRV=%DRV::=%"
set "MLOG=%TEMP%\rclone-mount-%DRV%.log"
if not exist %2\ goto :mo_go
echo [%date% %time%] %2 deja monte >> "%LOG%"
goto :mo_done
:mo_go
echo [%date% %time%] Montage %1 -^> %2 en cours... >> "%LOG%"
type nul > "%MLOG%" 2>nul
powershell -NoProfile -Command "Start-Process -WindowStyle Hidden '%RCLONE%' -ArgumentList 'mount','%~1','%~2','--volname','%~3','--config','%RCONF%','--vfs-cache-mode','full','--dir-cache-time','12h','--vfs-cache-max-size','4G','--vfs-cache-max-age','6h','--links','--log-file','%MLOG%','--log-level','INFO'"
ping -n 13 127.0.0.1 >nul
if exist %2\ goto :mo_ok
echo [%date% %time%] ERREUR : %2 absent apres 12s. Cause detaillee dans : %MLOG% >> "%LOG%"
goto :mo_done
:mo_ok
echo [%date% %time%] Disque %1 monte sur %2 OK >> "%LOG%"
:mo_done
goto :eof
