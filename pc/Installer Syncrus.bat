@echo off
cd /d "%~dp0"
echo Installation des dependances de Syncrus...
python -m pip install -r requirements.txt
if errorlevel 1 (
  echo Echec de l installation. Verifie que Python est installe.
  pause
  exit /b 1
)
echo Lancement de Syncrus dans la barre des taches...
start "" pythonw "%~dp0syncrus_tray.pyw"
echo C est fait. Cherche l icone Syncrus pres de l horloge.
timeout /t 4 >nul
