#!/usr/bin/env python3
"""
Syncrus - serveur PC
Surveille le presse-papier et le diffuse aux téléphones connectés
(Wi-Fi local, point d'accès du PC, ou câble USB via adb reverse).
"""
import argparse
import asyncio
import base64
import hashlib
import io
import json
import sys
import random
import shutil
import socket
import ssl
import subprocess
import time
import uuid
from pathlib import Path

import pyperclip
import websockets

try:
    from PIL import Image, ImageGrab
except ImportError:  # images désactivées si Pillow absent
    Image = ImageGrab = None

WS_PORT = 8765
DISCOVERY_PORT = 8766
MAX_HISTORY = 200
MAX_IMAGES = 15          # images gardées dans l'historique
MAX_SIDE = 2560          # côté max d'une image envoyée (px)
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp"}
PIN_FILE = Path.home() / ".syncrus_pin"
OLD_PIN_FILE = Path.home() / ".clipsync_pin"

history: list[dict] = []
on_event = None            # rappel optionnel (icône de la barre des tâches)
clients: set = set()
last_text: str | None = None
last_img_hash: str | None = None
ignore_seq = None          # n° de copie faite par Syncrus lui-même (anti-boucle)
receiving = False          # pause de la surveillance pendant qu'on écrit le presse-papier
SAVE_DIR = Path.home() / "Pictures" / "Syncrus"
FILES_DIR = Path.home() / "Downloads" / "Syncrus"
DATA_DIR = Path.home() / ".syncrus"
CERT_FILE = DATA_DIR / "cert.pem"
KEY_FILE = DATA_DIR / "key.pem"
FINGERPRINT = ""            # empreinte du certificat, affichée pour l'appairage
failed_auth: dict[str, list] = {}   # ip -> [nb échecs, bloqué jusqu'à]
CHUNK = 256 * 1024           # taille d'un morceau de fichier (octets)
file_paths: dict[str, Path] = {}   # id -> chemin sur le PC (jamais envoyé au téléphone)
uploads: dict[str, dict] = {}      # fichiers en cours de réception
PIN = ""


# ---------- utilitaires ----------
def notify(title: str, text: str = ""):
    if on_event:
        try:
            on_event(title, text)
        except Exception:
            pass


def load_or_create_pin(forced: str | None) -> str:
    if forced:
        PIN_FILE.write_text(forced)
        return forced
    if not PIN_FILE.exists() and OLD_PIN_FILE.exists():
        PIN_FILE.write_text(OLD_PIN_FILE.read_text())
    if PIN_FILE.exists():
        pin = PIN_FILE.read_text().strip()
        if pin:
            return pin
    pin = f"{random.randint(0, 9999):04d}"
    PIN_FILE.write_text(pin)
    return pin


# ---------- chiffrement (TLS) ----------
def ensure_certificate() -> ssl.SSLContext:
    """Crée (une seule fois) un certificat propre à ce PC et prépare le chiffrement TLS."""
    global FINGERPRINT
    DATA_DIR.mkdir(exist_ok=True)
    if not (CERT_FILE.exists() and KEY_FILE.exists()):
        import datetime
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID

        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"Syncrus {socket.gethostname()}")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(name).issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=3650))
            .sign(key, hashes.SHA256())
        )
        KEY_FILE.write_bytes(key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        CERT_FILE.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        print("Nouveau certificat créé : les téléphones devront être ré-appairés.")

    der = ssl.PEM_cert_to_DER_cert(CERT_FILE.read_text())
    digest = hashlib.sha256(der).hexdigest().upper()
    FINGERPRINT = "-".join(digest[i:i + 4] for i in range(0, 16, 4))  # ex. 3FA2-91C0-77D4-0B1E

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)
    return ctx


def auth_blocked(ip: str) -> bool:
    info = failed_auth.get(ip)
    return bool(info and info[1] > time.time())


def auth_failed(ip: str):
    info = failed_auth.setdefault(ip, [0, 0.0])
    info[0] += 1
    if info[0] >= 5:  # 5 mauvais PIN -> 60 s de blocage
        info[1] = time.time() + 60
        info[0] = 0
        print(f"! Trop de PIN incorrects depuis {ip} : bloqué 60 s")
        notify("Tentatives de connexion suspectes", f"{ip} bloqué 60 secondes")


def local_ips() -> list[str]:
    ips = set()
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if not ip.startswith("127."):
                ips.add(ip)
    except OSError:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(ips)


def broadcast(msg: dict):
    if clients:
        websockets.broadcast(clients, json.dumps(msg))


def _store(item: dict):
    global history
    history.append(item)
    # garde au plus MAX_IMAGES images (les plus récentes)
    imgs = [h for h in history if h.get("kind") == "image"]
    if len(imgs) > MAX_IMAGES:
        drop = {h["id"] for h in imgs[: len(imgs) - MAX_IMAGES]}
        history = [h for h in history if h["id"] not in drop]
    history = history[-MAX_HISTORY:]
    broadcast({"type": "clip", "item": item})


def human_size(n: int) -> str:
    for unit in ("o", "Ko", "Mo", "Go"):
        if n < 1024 or unit == "Go":
            return f"{n:.0f} {unit}" if unit == "o" else f"{n:.1f} {unit}"
        n /= 1024


def add_file(path: Path, source: str):
    """Ajoute un fichier à l'historique. Le contenu n'est envoyé que si le téléphone le demande."""
    global history
    path = Path(path)
    for fid, p in file_paths.items():  # même fichier recopié : on le remonte en tête
        if p == path:
            history = [h for h in history if h["id"] != fid]
    fid = uuid.uuid4().hex[:12]
    file_paths[fid] = path
    size = path.stat().st_size
    _store({"id": fid, "kind": "file", "name": path.name, "size": size,
            "ts": time.time(), "source": source})
    print(f"[{'PC' if source == 'pc' else 'TEL'}] Fichier {path.name} ({human_size(size)})")


async def send_file(ws, fid: str):
    """Envoie un fichier au téléphone qui l'a demandé, par morceaux."""
    path = file_paths.get(fid)
    if not path or not path.exists():
        await ws.send(json.dumps({"type": "file_error", "id": fid, "error": "Fichier introuvable sur le PC"}))
        return
    size = path.stat().st_size
    await ws.send(json.dumps({"type": "file_begin", "id": fid, "name": path.name, "size": size}))
    with open(path, "rb") as f:
        while True:
            chunk = await asyncio.to_thread(f.read, CHUNK)
            if not chunk:
                break
            await ws.send(json.dumps({"type": "file_chunk", "id": fid,
                                      "data": base64.b64encode(chunk).decode()}))
    await ws.send(json.dumps({"type": "file_end", "id": fid}))
    print(f"   -> {path.name} envoyé au téléphone")


def unique_path(folder: Path, name: str) -> Path:
    name = Path(name).name or "fichier"  # pas de chemin venant du téléphone
    p = folder / name
    i = 1
    while p.exists():
        p = folder / f"{Path(name).stem} ({i}){Path(name).suffix}"
        i += 1
    return p


def upload_begin(msg: dict):
    FILES_DIR.mkdir(parents=True, exist_ok=True)
    path = unique_path(FILES_DIR, str(msg.get("name", "fichier")))
    uploads[msg["id"]] = {"path": path, "fh": open(path, "wb"), "got": 0}


def upload_chunk(msg: dict):
    up = uploads.get(msg.get("id"))
    if up:
        data = base64.b64decode(msg["data"])
        up["fh"].write(data)
        up["got"] += len(data)


def upload_end(msg: dict):
    up = uploads.pop(msg.get("id"), None)
    if not up:
        return
    up["fh"].close()
    add_file(up["path"], "phone")
    print(f"   -> enregistré : {up['path']}")
    notify("Fichier reçu du téléphone", up["path"].name)


def upload_abort_all():
    for up in uploads.values():
        try:
            up["fh"].close()
            up["path"].unlink(missing_ok=True)
        except Exception:
            pass
    uploads.clear()


async def add_clip(text: str, source: str):
    global history
    history = [h for h in history if h.get("text") != text]  # pas de doublons
    _store({"id": uuid.uuid4().hex[:12], "kind": "text", "text": text,
            "ts": time.time(), "source": source})
    preview = text.replace("\n", " ")[:60]
    print(f"[{'PC' if source == 'pc' else 'TEL'}] {preview}")


async def add_image(img, h: str, source: str):
    global history
    history = [x for x in history if x.get("hash") != h]

    def encode():
        im = img.convert("RGBA") if img.mode not in ("RGB", "RGBA") else img
        if max(im.size) > MAX_SIDE:
            im = im.copy()
            im.thumbnail((MAX_SIDE, MAX_SIDE))
        buf = io.BytesIO()
        im.save(buf, "PNG", optimize=True)
        mime = "image/png"
        if buf.tell() > 3 * 2**20:  # photo lourde -> JPEG
            buf = io.BytesIO()
            im.convert("RGB").save(buf, "JPEG", quality=85)
            mime = "image/jpeg"
        return base64.b64encode(buf.getvalue()).decode(), mime, im.size, buf.tell()

    data, mime, (w, hgt), size = await asyncio.to_thread(encode)
    _store({"id": uuid.uuid4().hex[:12], "kind": "image", "data": data, "mime": mime,
            "w": w, "h": hgt, "hash": h, "ts": time.time(), "source": source})
    print(f"[{'PC' if source == 'pc' else 'TEL'}] Image {w}x{hgt} ({size // 1024} Ko)")


# ---------- presse-papier ----------
def clipboard_seq():
    """Compteur Windows qui change à chaque copie (évite de relire l'image en boucle)."""
    if sys.platform == "win32":
        import ctypes
        return ctypes.windll.user32.GetClipboardSequenceNumber()
    return None


def grab_clipboard_media():
    """Retourne ("image", img), ("files", [chemins]) ou None.
    Gère captures, images copiées d'un site et fichiers copiés dans l'Explorateur."""
    if ImageGrab is None:
        return None
    try:
        data = ImageGrab.grabclipboard()
    except Exception:
        return None
    if isinstance(data, list):
        paths = [Path(f) for f in data if Path(f).is_file()]
        if len(paths) == 1 and paths[0].suffix.lower() in IMAGE_EXT:
            try:
                im = Image.open(paths[0])
                im.load()
                return ("image", im)
            except Exception:
                pass
        return ("files", paths) if paths else None
    if data is not None:
        return ("image", data)
    return None


def set_clipboard_image(img) -> bool:
    """Met une image dans le presse-papier Windows (format DIB), sans dépendance externe."""
    if sys.platform != "win32":
        return False
    import ctypes
    from ctypes import wintypes

    buf = io.BytesIO()
    img.convert("RGB").save(buf, "BMP")
    data = buf.getvalue()[14:]  # on retire l'en-tête fichier BMP -> DIB

    k32, u32 = ctypes.windll.kernel32, ctypes.windll.user32
    k32.GlobalAlloc.restype = wintypes.HGLOBAL
    k32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    k32.GlobalLock.restype = wintypes.LPVOID
    k32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    k32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    u32.SetClipboardData.restype = wintypes.HANDLE
    u32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]

    for _ in range(10):  # le presse-papier peut être occupé un instant
        if u32.OpenClipboard(None):
            break
        time.sleep(0.05)
    else:
        return False
    try:
        u32.EmptyClipboard()
        h = k32.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
        ptr = k32.GlobalLock(h)
        ctypes.memmove(ptr, data, len(data))
        k32.GlobalUnlock(h)
        u32.SetClipboardData(8, h)  # CF_DIB
        return True
    finally:
        u32.CloseClipboard()


async def receive_phone_image(b64: str, mime: str):
    global ignore_seq, last_img_hash, last_text, receiving
    if Image is None:
        print("! Image reçue mais Pillow absent (pip install pillow)")
        return
    from PIL import ImageOps

    raw = base64.b64decode(b64)

    def work():
        img = ImageOps.exif_transpose(Image.open(io.BytesIO(raw)))
        img.load()
        SAVE_DIR.mkdir(parents=True, exist_ok=True)
        ext = "jpg" if mime == "image/jpeg" else "png"
        path = SAVE_DIR / f"syncrus_{time.strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:4]}.{ext}"
        path.write_bytes(raw)
        ok = set_clipboard_image(img)
        return img, path, ok

    receiving = True
    try:
        img, path, ok = await asyncio.to_thread(work)
        ignore_seq = clipboard_seq()
    finally:
        receiving = False
    last_text = None
    h = hashlib.sha1(img.tobytes()).hexdigest()
    last_img_hash = h
    await add_image(img, h, "phone")
    print(f"   -> {'copiée dans le presse-papier, ' if ok else ''}enregistrée : {path}")
    notify("Photo reçue du téléphone", "Prête à coller (Ctrl+V)" if ok else str(path))


async def watch_clipboard():
    global last_text, last_img_hash
    last_seq = object()
    while True:
        if receiving:
            await asyncio.sleep(0.1)
            continue
        seq = clipboard_seq()
        if seq is not None and seq == ignore_seq:
            last_seq = seq  # copie faite par Syncrus : on ne la renvoie pas
        if seq is None or seq != last_seq:
            last_seq = seq
            try:
                text = await asyncio.to_thread(pyperclip.paste)
            except Exception:
                text = None
            if text:
                if text != last_text:
                    last_text = text
                    await add_clip(text, "pc")
            elif seq is not None:  # pas de texte : image ou fichiers ?
                media = await asyncio.to_thread(grab_clipboard_media)
                if media and media[0] == "image":
                    img = media[1]
                    h = hashlib.sha1(img.tobytes()).hexdigest()
                    if h != last_img_hash:
                        last_img_hash = h
                        await add_image(img, h, "pc")
                elif media and media[0] == "files":
                    for f in media[1]:
                        add_file(f, "pc")
        await asyncio.sleep(0.4)


# ---------- WebSocket ----------
async def handler(ws):
    global last_text, history
    try:
        msg = json.loads(await asyncio.wait_for(ws.recv(), 10))
    except Exception:
        return
    ip = ws.remote_address[0]
    if auth_blocked(ip):
        await ws.send(json.dumps({"type": "auth_error", "reason": "blocked"}))
        return
    if msg.get("type") != "auth" or str(msg.get("pin")) != PIN:
        auth_failed(ip)
        await ws.send(json.dumps({"type": "auth_error"}))
        return
    failed_auth.pop(ip, None)

    await ws.send(json.dumps({"type": "hello", "name": socket.gethostname(), "history": history}))
    clients.add(ws)
    print(f"+ Téléphone connecté ({ws.remote_address[0]})")
    notify("Téléphone connecté", ws.remote_address[0])
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            t = msg.get("type")
            if t == "push" and isinstance(msg.get("text"), str) and msg["text"]:
                text = msg["text"]
                last_text = text  # évite la boucle PC -> tel -> PC
                try:
                    pyperclip.copy(text)
                except Exception:
                    pass
                await add_clip(text, "phone")
            elif t == "push_image" and isinstance(msg.get("data"), str):
                try:
                    await receive_phone_image(msg["data"], msg.get("mime", "image/jpeg"))
                except Exception as e:
                    print(f"! Image du téléphone illisible : {e}")
            elif t == "get_file":
                asyncio.create_task(send_file(ws, str(msg.get("id"))))
            elif t == "upload_begin":
                upload_begin(msg)
            elif t == "upload_chunk":
                upload_chunk(msg)
            elif t == "upload_end":
                upload_end(msg)
            elif t == "delete":
                history = [h for h in history if h["id"] != msg.get("id")]
                broadcast({"type": "deleted", "id": msg.get("id")})
            elif t == "clear":
                history.clear()
                broadcast({"type": "cleared"})
    except websockets.ConnectionClosed:
        pass
    finally:
        clients.discard(ws)
        if not clients:
            upload_abort_all()  # envoi interrompu : on supprime le fichier incomplet
        print(f"- Téléphone déconnecté (code {ws.close_code}, {ws.close_reason or 'sans raison'})")


# ---------- découverte automatique (UDP) ----------
class Discovery(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        if data.strip() == b"SYNCRUS_DISCOVER":
            reply = {"app": "syncrus", "port": WS_PORT, "name": socket.gethostname()}
            self.transport.sendto(json.dumps(reply).encode(), addr)


# ---------- câble USB (Android) ----------
NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0  # CREATE_NO_WINDOW


async def adb_reverse_loop():
    adb = shutil.which("adb")
    default = Path.home() / "AppData/Local/Android/sdk/platform-tools/adb.exe"
    if not adb and default.exists():
        adb = str(default)
    if not adb:
        return
    print("adb détecté : mode câble USB actif (adresse 127.0.0.1 dans l'app)")
    while True:
        try:
            await asyncio.to_thread(
                subprocess.run,
                [adb, "reverse", f"tcp:{WS_PORT}", f"tcp:{WS_PORT}"],
                capture_output=True, timeout=5,
                creationflags=NO_WINDOW,  # pas de fenêtre de console qui clignote
            )
        except Exception:
            pass
        await asyncio.sleep(5)


async def main():
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(Discovery, local_addr=("0.0.0.0", DISCOVERY_PORT))
    tls = ensure_certificate()
    async with websockets.serve(
        handler, "0.0.0.0", WS_PORT, max_size=32 * 2**20, ssl=tls,
        ping_interval=30, ping_timeout=120,  # tolère la mise en veille Wi-Fi du téléphone
    ):
        print("=" * 46)
        print("  Syncrus - serveur PC démarré")
        if ImageGrab is None:
            print("  (images désactivées : pip install pillow)")
        print(f"  PIN : {PIN}")
        print(f"  Empreinte : {FINGERPRINT}  (connexion chiffrée)")
        for ip in local_ips():
            print(f"  Adresse : {ip}")
        print("  Point d'accès Windows : 192.168.137.1")
        print("  Câble USB (adb)       : 127.0.0.1")
        print("=" * 46)
        await asyncio.gather(watch_clipboard(), adb_reverse_loop())


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Syncrus - serveur PC")
    ap.add_argument("--pin", help="Définir un PIN fixe (4 chiffres)")
    args = ap.parse_args()
    PIN = load_or_create_pin(args.pin)
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nArrêt.")
