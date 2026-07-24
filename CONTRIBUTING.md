# Contribuer à Sillage

Merci de ton intérêt ! Sillage est un petit projet macOS open-source (licence
MIT). Bugs, idées et pull requests sont les bienvenus.

## Prérequis

Pour compiler et tester, il te faut :

- **macOS 26 (Tahoe) ou plus**, sur **Apple Silicon** (les API `SpeechAnalyzer`
  et *Liquid Glass* sont spécifiques à macOS 26).
- **Command Line Tools for Xcode 26** (SDK macOS 26).
  Vérifier : `xcrun --sdk macosx --show-sdk-version` → doit afficher `26.x`.

> ℹ️ Il n'y a pas encore d'intégration continue : les runners macOS 26 ne sont
> pas disponibles chez GitHub Actions à ce jour. La compilation et les tests se
> font donc en local.

## Compiler & lancer

```bash
./build.sh
open build/Sillage.app
```

`build.sh` compile via SwiftPM, assemble le bundle `.app` et le signe (avec la
première identité de signature valide du trousseau, sinon en ad-hoc).

## Tester une modification

Il n'y a pas de suite de tests automatisés. Teste manuellement :

1. Lance l'app, démarre un enregistrement (parle au micro + un son système).
2. Arrête → vérifie que le `transcript.md` est correct dans **Voir les
   transcripts**, et que l'audio a bien été supprimé.
3. Pour investiguer, les logs sont filtrables :
   ```bash
   log show --last 10m --predicate 'subsystem == "com.cletetour.sillage"'
   ```

## Workflow

1. **Fork** le dépôt, puis clone ton fork.
2. Crée une **branche** dédiée : `git checkout -b ma-contribution`.
3. Fais tes commits (messages clairs, français ou anglais).
4. Pousse sur ton fork et ouvre une **Pull Request** vers `main`.
5. La PR sera relue ; des changements peuvent être demandés avant le merge.

Merci de garder **un seul sujet par PR** — c'est plus facile à relire et à
merger.

## Conventions

- Respecte le **style du code existant** (nommage, structure, commentaires en
  français, `os.Logger` via `Log.swift`).
- Pas de dépendance externe sans discussion préalable (le projet est
  volontairement sans dépendances).
- Pour un changement d'ampleur, ouvre d'abord une **issue** pour en discuter
  avant de coder.

## Signaler un bug / proposer une idée

Utilise les [issues](../../issues) avec les modèles fournis (bug / fonctionnalité).

## Licence

En contribuant, tu acceptes que ta contribution soit distribuée sous la licence
[MIT](LICENSE) du projet.
