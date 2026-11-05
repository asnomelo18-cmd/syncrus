<p align="center">
  <img src="docs/logo.png" width="120" alt="Syncrus">
</p>

<h1 align="center">Syncrus</h1>
<p align="center">Copie sur ton PC, retrouve sur ton téléphone. Et l'inverse.</p>

---

## Fonctionnalités

- **Presse-papier synchronisé** : le texte copié sur le PC arrive instantanément sur le téléphone
- **Images** : captures d'écran et images copiées, PC → téléphone
- **Photos** : de la galerie du téléphone vers le presse-papier du PC
- **Fichiers** dans les deux sens (PDF, Word, ZIP, vidéos…)
- **3 modes de connexion** : même Wi-Fi, point d'accès du PC, câble USB (Android)
- **Sécurité** : connexion chiffrée TLS, appairage par empreinte, PIN, anti-force brute
- **Discret** : icône dans la barre des tâches, démarrage avec Windows

## Architecture

```
┌──────────────┐   WebSocket chiffré (TLS)   ┌──────────────────┐
│  App mobile  │ ◄─────────────────────────► │   Serveur PC     │
│  Flutter     │    port 8765 (TCP)          │   Python         │
│              │ ── découverte UDP 8766 ──►  │   (barre tâches) │
└──────────────┘                             └──────────────────┘
```

## Structure du dépôt

```
syncrus/
├── app/      Application mobile Flutter (Android)
├── pc/       Serveur Windows en Python
└── docs/     Logo, captures d'écran
```

## Installation (utilisateurs)

Télécharge la dernière version dans **[Releases](../../releases)** :

1. **PC** : lance `Syncrus.exe`, autorise-le dans le pare-feu. Le PIN s'affiche près de l'horloge.
2. **Téléphone** : installe `Syncrus.apk`, choisis un mode de connexion et saisis le PIN.

## Développement

**Serveur PC** (Python 3.13)
```bash
cd pc
pip install -r requirements.txt
python syncrus_server.py          # avec terminal
pythonw syncrus_tray.pyw          # version barre des tâches
```

**Créer l'exécutable** : `pc/Construire Syncrus.exe.bat` → `pc/dist/Syncrus.exe`

**App mobile** (Flutter 3.47+)
```bash
cd app
flutter pub get
flutter run                       # téléphone branché en débogage USB
flutter build apk --release       # APK de distribution
```

## Technologies

Flutter · Dart · Python · WebSocket · TLS · asyncio · Pillow · pystray

## Auteur

Christ-Roland — étudiant en Informatique et Développement d'Applications, Abidjan
