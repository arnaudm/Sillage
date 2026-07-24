# Sillage

Application macOS locale (barre de menus) de prise de notes de réunion : elle
écoute le **micro de ton choix** et le **son du système**, produit un **transcript
horodaté** entièrement **on-device** (aucune donnée ne quitte ta machine), puis
supprime automatiquement l'audio.

Développée **sans Xcode.app** : tout se compile en ligne de commande avec les
Command Line Tools.

> ⚠️ **Consentement** : enregistrer une conversation sans en informer les
> participants est illégal dans de nombreux pays (en France, art. 226-1 du Code
> pénal). Préviens toujours tes interlocuteurs.

## Fonctionnalités

- 🎙️ **Capture double piste** : ton micro (périphérique au choix : intégré,
  casque Bluetooth, interface…) sur une piste, le son système sur une autre.
- 🗣️ **Séparation des locuteurs gratuite** : « Moi » (micro) vs « Interlocuteur »
  (son système), grâce aux deux pistes distinctes.
- 📝 **Transcription on-device** via `SpeechAnalyzer` / `SpeechTranscriber`
  (macOS 26), en français, horodatée.
- 🔊 **Son système sans capture d'écran** : via les *Core Audio process taps*
  (permission « enregistrement des sons du système uniquement »), pas de
  permission d'enregistrement d'écran.
- ⏱️ **Pistes alignées** : les silences sont reconstruits pour que les deux
  pistes restent synchronisées (pas de décalage dans le transcript).
- 🗑️ **Confidentialité** : l'audio (`mic.wav` / `system.wav`) est **supprimé
  automatiquement** une fois le transcript généré.
- 🪟 **Fenêtre de gestion des transcripts** : label éditable par session,
  copier dans le presse-papiers (label inclus), supprimer, ouvrir le dossier
  dans le Finder.
- 🔴 **Panneau flottant** *Liquid Glass* avec bouton Stop, toujours visible
  pendant l'enregistrement.
- ⚠️ **Confirmation** avant de quitter l'application.

## Prérequis

- **macOS 26 (Tahoe) ou plus**, sur **Apple Silicon**.
- Pour compiler : **Command Line Tools for Xcode 26** (SDK macOS 26).
  - Vérifier : `xcrun --sdk macosx --show-sdk-version` → doit afficher `26.x`.

## Installation

### Option A — Télécharger l'app (le plus simple)

1. Va dans [**Releases**](../../releases) et télécharge `Sillage-vX.Y.Z.zip`.
2. Décompresse, puis déplace `Sillage.app` dans `/Applications`.
3. L'app n'étant pas notarisée par Apple, macOS la bloque au premier lancement.
   Lève la mise en quarantaine :
   ```bash
   xattr -dr com.apple.quarantine /Applications/Sillage.app
   ```
   (ou : clic droit sur l'app → **Ouvrir**, puis confirme ; ou *Réglages
   Système › Confidentialité et sécurité › Ouvrir quand même*.)

### Option B — Compiler depuis les sources

```bash
git clone https://github.com/fabriquetonvoyage/Sillage.git
cd Sillage
./build.sh
open build/Sillage.app
```

`build.sh` compile via SwiftPM, assemble le bundle `.app`, et le signe
(automatiquement avec la première identité de signature valide du trousseau,
sinon en ad-hoc).

## Utilisation

1. Lance l'app → une icône **●** apparaît dans la barre de menus.
2. Choisis la **source micro**, active/désactive **Capturer le son système**.
3. **Démarrer** → un panneau flottant affiche le chrono et un bouton Stop.
4. **Arrêter** → la transcription se lance, l'audio est supprimé, et le
   transcript apparaît dans **Voir les transcripts**.

Les transcripts sont dans
`~/Library/Application Support/Sillage/Recordings/<horodatage>/transcript.md`.

## Permissions demandées

- **Micro** : pour enregistrer ta voix.
- **Enregistrement des sons du système uniquement** : pour capter l'audio des
  autres apps (visio, vidéos…). Aucune capture d'écran.

## Confidentialité

Capture et transcription sont **100 % locales** (aucun réseau). Les fichiers
audio sont supprimés dès que le transcript est produit ; seul le `transcript.md`
(et un `label.txt` optionnel) est conservé.

## Architecture

| Fichier | Rôle |
|---|---|
| `SillageApp.swift` | Point d'entrée SwiftUI, icône barre de menus, fenêtre transcripts |
| `ContentView.swift` | Panneau : sélecteur micro, toggle son système, Démarrer/Arrêter, Quitter |
| `RecordingController.swift` | Orchestration start/stop, sessions, transcription, suppression audio |
| `AudioDeviceManager.swift` | Énumération Core Audio des entrées |
| `MicRecorder.swift` | Capture micro (IOProc Core Audio) → `mic.wav` |
| `SystemAudioRecorder.swift` | Capture son système (process tap + device agrégé) → `system.wav` |
| `Transcriber.swift` | Transcription `SpeechAnalyzer` + fusion des pistes en Markdown |
| `TranscriptStore.swift` | Lecture/suppression/label des transcripts sur disque |
| `TranscriptsView.swift` | Fenêtre de gestion des transcripts |
| `FloatingStopController.swift` / `FloatingStopView.swift` | Panneau flottant Liquid Glass |
| `Log.swift` | Loggers `os.Logger` (sous-système `com.cletetour.sillage`) |

## Limites connues

- Sur **haut-parleurs**, le micro capte le son système (écho) → le même passage
  peut apparaître dans les deux pistes. **Utilise un casque** pour l'éviter.
  (Une annulation d'écho logicielle est envisagée.)
- Nécessite macOS 26 (API `SpeechAnalyzer` et *Liquid Glass*).

## Licence

[MIT](LICENSE) © 2026 Clément Letetour
