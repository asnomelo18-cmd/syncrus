@echo off
cd /d "%~dp0"
echo === Construction de Syncrus.exe ===
python -m pip install -r requirements.txt pyinstaller
python -m PyInstaller --noconfirm --onefile --noconsole --name Syncrus --icon syncrus.ico --add-data "syncrus.png;." --hidden-import pystray._win32 syncrus_tray.pyw
if errorlevel 1 (
  echo Echec de la construction.
  pause
  exit /b 1
)
echo.
echo Termine : dist\Syncrus.exe
explorer dist
pause
