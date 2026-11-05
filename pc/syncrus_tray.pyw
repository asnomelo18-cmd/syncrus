"""
Syncrus - version barre des tâches (sans terminal)
Lancer avec :  pythonw syncrus_tray.pyw
"""
import asyncio
import os
import subprocess
import sys
import threading
from pathlib import Path

FROZEN = getattr(sys, "frozen", False)  # True quand lancé depuis Syncrus.exe
HERE = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
sys.path.insert(0, str(HERE))

DATA_DIR = Path.home() / ".syncrus"
DATA_DIR.mkdir(exist_ok=True)
LOG_FILE = DATA_DIR / "syncrus.log"
FIRST_RUN_FLAG = DATA_DIR / "first_run_done"

# pythonw n'a pas de console : tout part dans le journal
_log = open(LOG_FILE, "a", encoding="utf-8", buffering=1)
sys.stdout = sys.stderr = _log

import pystray  # noqa: E402
from PIL import Image  # noqa: E402

import syncrus_server as server  # noqa: E402

APP = "Syncrus"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
icon: pystray.Icon | None = None


# ---------- démarrage avec Windows ----------
def launch_command() -> str:
    if FROZEN:
        return f'"{sys.executable}"'
    exe = Path(sys.executable)
    pyw = exe.with_name("pythonw.exe")
    return f'"{pyw if pyw.exists() else exe}" "{Path(__file__).resolve()}"'


def autostart_enabled(_=None) -> bool:
    if sys.platform != "win32":
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            winreg.QueryValueEx(k, APP)
            return True
    except OSError:
        return False


def set_autostart(on: bool):
    if sys.platform != "win32":
        return
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
        if on:
            winreg.SetValueEx(k, APP, 0, winreg.REG_SZ, launch_command())
        else:
            try:
                winreg.DeleteValue(k, APP)
            except OSError:
                pass


def toggle_autostart(_icon, _item):
    on = not autostart_enabled()
    set_autostart(on)
    toast("Démarrage automatique " + ("activé" if on else "désactivé"))


# ---------- notifications ----------
def toast(title: str, text: str = ""):
    if icon is None:
        return
    try:
        icon.notify(text or " ", title)
    except Exception:
        pass


# ---------- serveur en arrière-plan ----------
def run_server():
    try:
        asyncio.run(server.main())
    except OSError as e:
        print(f"! Impossible de démarrer : {e}")
        toast("Syncrus ne peut pas démarrer", "Le port 8765 est occupé : Syncrus est peut-être déjà lancé.")
    except Exception as e:
        print(f"! Erreur serveur : {e}")
        toast("Erreur Syncrus", str(e)[:120])


# ---------- actions du menu ----------
def open_path(p: Path):
    if p in (server.SAVE_DIR, server.FILES_DIR):
        p.mkdir(parents=True, exist_ok=True)
    if sys.platform == "win32":
        os.startfile(p)
    else:
        subprocess.Popen(["xdg-open", str(p)])


def status_text(_):
    n = len(server.clients)
    return "● Aucun téléphone connecté" if n == 0 else f"● {n} téléphone{'s' if n > 1 else ''} connecté{'s' if n > 1 else ''}"


def refresh_loop():
    """Met à jour le statut du menu et l'info-bulle quand un téléphone se (dé)connecte."""
    import time
    last = -1
    while True:
        n = len(server.clients)
        if n != last and icon is not None:
            last = n
            icon.title = f"Syncrus — {'connecté' if n else 'en attente'} — PIN {server.PIN}"
            try:
                icon.update_menu()
            except Exception:
                pass
        time.sleep(2)


def quit_app(_icon, _item):
    _icon.visible = False
    _icon.stop()
    os._exit(0)


def build_menu():
    ips = server.local_ips()
    addr_items = [pystray.MenuItem(f"Wi-Fi : {ip}", None, enabled=False) for ip in ips]
    addr_items += [
        pystray.MenuItem("Point d'accès : 192.168.137.1", None, enabled=False),
        pystray.MenuItem("Câble USB : 127.0.0.1", None, enabled=False),
    ]
    return pystray.Menu(
        pystray.MenuItem("Syncrus", None, enabled=False),
        pystray.MenuItem(status_text, None, enabled=False),
        pystray.MenuItem(f"PIN : {server.PIN}", None, enabled=False),
        pystray.MenuItem(lambda _: f"🔒 Empreinte : {server.FINGERPRINT or '…'}", None, enabled=False),
        pystray.MenuItem("Adresses", pystray.Menu(*addr_items)),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Ouvrir les photos reçues", lambda: open_path(server.SAVE_DIR)),
        pystray.MenuItem("Ouvrir les fichiers reçus", lambda: open_path(server.FILES_DIR)),
        pystray.MenuItem("Voir le journal", lambda: open_path(LOG_FILE)),
        pystray.MenuItem("Démarrer avec Windows", toggle_autostart, checked=autostart_enabled),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quitter", quit_app),
    )


def main():
    global icon
    server.PIN = server.load_or_create_pin(None)
    server.on_event = toast

    img = Image.open(HERE / "syncrus.png")
    icon = pystray.Icon(APP, img, f"Syncrus — PIN {server.PIN}", build_menu())

    def setup(i):
        i.visible = True
        threading.Thread(target=run_server, daemon=True).start()
        threading.Thread(target=refresh_loop, daemon=True).start()
        if not FIRST_RUN_FLAG.exists():
            FIRST_RUN_FLAG.write_text("1")
            set_autostart(True)
            toast("Syncrus est actif", f"PIN : {server.PIN} — se lancera avec Windows (désactivable dans le menu).")
        else:
            toast("Syncrus est actif", f"PIN : {server.PIN}")

    icon.run(setup)


if __name__ == "__main__":
    main()
